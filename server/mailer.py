# -*- coding: utf-8 -*-
"""发信模块 —— 把 notification_outbox 里待发的通知真正发出去。

设计上分两层，这一层只做「投递」，不做「决定发什么」：
    数据库（触发器 / reminder.py）决定「该发什么、发给谁、什么内容」，
    这里只负责把已经排好队的行发出去，并把结果写回状态。

为什么要经过 outbox 而不是在业务代码里直接 smtplib.sendmail：
    · SMTP 是网络操作，可能超时。放在挂号事务里，网络一抖挂号就失败，
      用户看到的是「挂号失败」而不是「邮件没发出去」—— 主次颠倒。
    · 发信失败要能重试，重试要有次数上限，这些都需要一个持久化的队列。

配置从 server/mail.env 读（KEY=VALUE，一行一条，# 开头是注释），
读不到就用同名环境变量。两者都没有 → 进入 dry-run：
邮件内容照样写进 outbox 和 .mail-outbox.log，只是不真的连 SMTP。
这样在没配邮箱的教学机上也能把整套流程演示完。

    SMTP_HOST=smtp.example.com
    SMTP_PORT=465            # 465 = SSL，587 = STARTTLS
    SMTP_USER=robot@sp1rit.com
    SMTP_PASS=授权码
    MAIL_FROM=robot@sp1rit.com
    MAIL_FROM_NAME=智慧医院挂号系统
    MAIL_DRY_RUN=0
"""

import os
import smtplib
import ssl
import sys
from datetime import datetime
from email.header import Header
from email.mime.text import MIMEText
from email.utils import formataddr, formatdate
from pathlib import Path

from db import query

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ENV_FILE = HERE / "mail.env"
DRY_RUN_LOG = ROOT / ".mail-outbox.log"

# 发信失败最多重试几次，之后标记 failed 等人工处理
MAX_ATTEMPTS = 3


# ------------------------------------------------------------
# 一、配置
# ------------------------------------------------------------
def _read_env_file():
    """读 server/mail.env。格式简单到不需要任何依赖：KEY=VALUE。"""
    if not ENV_FILE.exists():
        return {}
    out = {}
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.split("#")[0].strip()
    return out


_FILE = _read_env_file()


def conf(key, default=""):
    """先查 mail.env，再查环境变量，最后用默认值。"""
    return (_FILE.get(key) or os.environ.get(key) or default).strip()


class MailConfig:
    def __init__(self):
        self.host = conf("SMTP_HOST")
        self.port = int(conf("SMTP_PORT", "465") or 465)
        self.user = conf("SMTP_USER")
        self.password = conf("SMTP_PASS")
        self.sender = conf("MAIL_FROM") or self.user or "noreply@sp1rit.com"
        self.sender_name = conf("MAIL_FROM_NAME", "智慧医院挂号系统")
        self.dry_run = conf("MAIL_DRY_RUN", "0") in ("1", "true", "yes")

    @property
    def ready(self):
        """能不能真的发信。缺任何一项都退回 dry-run，而不是启动就报错。"""
        return bool(self.host and self.user and self.password) and not self.dry_run

    def describe(self):
        if not self.host:
            return "未配置 SMTP_HOST → dry-run（只写日志，不连服务器）"
        if not self.user or not self.password:
            return "缺少 SMTP_USER / SMTP_PASS → dry-run"
        if self.dry_run:
            return "MAIL_DRY_RUN=1 → dry-run（配置齐全但不真的发）"
        return "SMTP %s:%d  发件人 %s" % (self.host, self.port, self.sender)


CONFIG = MailConfig()


# ------------------------------------------------------------
# 二、真正发一封
# ------------------------------------------------------------
def build_message(to, subject, body):
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = Header(subject, "utf-8")
    msg["From"] = formataddr((str(Header(CONFIG.sender_name, "utf-8")), CONFIG.sender))
    msg["To"] = to
    msg["Date"] = formatdate(localtime=True)
    return msg


def send_mail(to, subject, body):
    """发一封邮件。成功返回 None，失败抛异常（由调用方决定重试还是放弃）。"""
    msg = build_message(to, subject, body)

    if not CONFIG.ready:
        # dry-run：把整封信写进日志文件，答辩时可以直接打开给老师看
        with DRY_RUN_LOG.open("a", encoding="utf-8") as f:
            f.write("\n" + "=" * 64 + "\n")
            f.write("时间：%s\n" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
            f.write("收件人：%s\n主题：%s\n\n%s\n" % (to, subject, body))
        return

    if CONFIG.port == 465:
        ctx = ssl.create_default_context()
        with smtplib.SMTP_SSL(CONFIG.host, CONFIG.port, timeout=15, context=ctx) as s:
            s.login(CONFIG.user, CONFIG.password)
            s.sendmail(CONFIG.sender, [to], msg.as_string())
    else:
        with smtplib.SMTP(CONFIG.host, CONFIG.port, timeout=15) as s:
            s.ehlo()
            s.starttls(context=ssl.create_default_context())
            s.login(CONFIG.user, CONFIG.password)
            s.sendmail(CONFIG.sender, [to], msg.as_string())


# ------------------------------------------------------------
# 三、把队列里的发出去
# ------------------------------------------------------------
def flush(limit=50):
    """发最多 limit 条待发通知，返回统计。

    站内信（channel='inapp'）不需要投递 —— 它躺在表里就是「已送达」，
    前端查未读消息时直接读这张表。所以这里只把它的状态改成 sent。
    """
    stats = {"sent": 0, "skipped": 0, "failed": 0, "dry_run": not CONFIG.ready}

    rows = query(
        """SELECT id, channel, recipient, subject, body, attempts
             FROM notification_outbox
            WHERE status = 'pending' AND scheduled_at <= NOW()
            ORDER BY id
            LIMIT %s""",
        [limit],
    ).rows

    for row in rows:
        if row["channel"] == "inapp":
            query("""UPDATE notification_outbox
                        SET status = 'sent', sent_at = NOW()
                      WHERE id = %s""", [row["id"]])
            stats["skipped"] += 1
            continue

        try:
            send_mail(row["recipient"], row["subject"], row["body"])
            query("""UPDATE notification_outbox
                        SET status = 'sent', sent_at = NOW(), attempts = attempts + 1
                      WHERE id = %s""", [row["id"]])
            stats["sent"] += 1
        except Exception as err:                              # noqa: BLE001
            attempts = int(row["attempts"]) + 1
            if attempts >= MAX_ATTEMPTS:
                query("""UPDATE notification_outbox
                            SET status = 'failed', attempts = %s, last_error = %s
                          WHERE id = %s""",
                      [attempts, str(err)[:280], row["id"]])
                stats["failed"] += 1
            else:
                # 退避重试：第 n 次失败后等 n*2 分钟再发
                query("""UPDATE notification_outbox
                            SET attempts = %s, last_error = %s,
                                scheduled_at = NOW() + (%s || ' minutes')::interval
                          WHERE id = %s""",
                      [attempts, str(err)[:280], attempts * 2, row["id"]])
    return stats


def send_test(to):
    """手工验配置：python server/app.py --test-mail you@example.com"""
    if not CONFIG.ready:
        print("当前是 dry-run：%s" % CONFIG.describe())
        print("仍然会写一封到 %s，可以先看看格式对不对。" % DRY_RUN_LOG.name)
    send_mail(to, "【智慧医院挂号系统】测试邮件",
              "这是一封测试邮件。\n\n如果你收到了它，说明 SMTP 配置可用，"
              "挂号提醒与候补通知都会走同一条通道。\n")
    print("已投递到 %s（%s）" % (to, CONFIG.describe()))


if __name__ == "__main__":
    # 直接跑这个文件 = 发一封测试信
    target = sys.argv[1] if len(sys.argv) > 1 else CONFIG.sender
    print("配置：%s" % CONFIG.describe())
    send_test(target)
