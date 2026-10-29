# -*- coding: utf-8 -*-
"""定时任务 —— 三件事，都是「数据库不适合自己干」的：

    1. 生成就诊提醒（前一天 / 当天）
    2. 处理候补保留期过期，顺延给下一位
    3. 把发件箱里的通知真正发出去（交给 mailer.flush）

为什么这三件事不在触发器里做：
    发邮件要连网络、过期判断要「到点了才做」—— 触发器只在写入那一刻执行，
    没有「时间流逝」这个事件。所以用一个小 worker 定时扫。

怎么跑：
    python server/app.py --worker            常驻，每 60 秒扫一次
    python server/app.py --remind            只扫一次提醒（带时间窗判断）
    python server/app.py --remind --force    只扫一次提醒，忽略时间窗（演示用）
    python server/app.py --flush-mail        只把发件箱里的发出去

★ 幂等：所有写入都用 dedupe_key + ON CONFLICT DO NOTHING。
  同一条挂号单，前一天提醒只会有一封 —— worker 一分钟扫一次也不会刷屏。
"""

import time
from datetime import datetime

from db import query

# 提醒规则：(模板, 就诊日相对今天的偏移, 从几点开始允许发)
#   偏移 +1 = 明天要来的号（今天提醒他「明天来」），0 = 今天的号
#
#   ★ 偏移是「就诊日 = 今天 + N」，不是「提前几天」。
#     一开始写成了 -1，结果扫的是昨天的单子，一条提醒都发不出去 ——
#     语义一定要在变量名和注释里写死，否则加减号错了没人看得出来。
#   18 点之后才发「明天」的提醒，是因为太早发（比如上午发明天下午的号）
#   患者容易看一眼就忘；当天 7 点发，正好卡在出门前。
RULES = [
    ("reminder_t1", 1, 18),
    ("reminder_t0", 0, 7),
]

# 候补保留时长（与 schema_v3.sql 里 fn_offer_next_waitlist 的 INTERVAL 保持一致）
OFFER_HOLD_HOURS = 2


def _build_sql(template, offset, channel):
    """一条 INSERT ... SELECT，把「该提醒谁」直接写成 SQL。

    放在数据库里做的好处：一次扫完全部符合条件的人，不用把数据捞到 Python 里再筛。

    ★ 正文用 || 拼，不用 format()：
      format() 的占位符也是 %s，psycopg 会把它当成自己的参数占位符，
      一条语句里就会冒出「11 个占位符只给了 1 个参数」这种错。
      SQL 里除了真正的 %s，一个裸 % 都不要留，是最省心的写法。
    """
    if channel == "email":
        recipient = "p.email"
        key = "'%s:email:' || a.id" % template
        where_mail = "AND p.email IS NOT NULL"
        channel_val = "email"
    else:
        recipient = "p.id"
        key = "'%s:inapp:' || a.id" % template
        where_mail = ""
        channel_val = "inapp"

    when_word = "明天" if offset > 0 else "今天"
    return """
        INSERT INTO notification_outbox
              (channel, template, dedupe_key, recipient, subject, body, appointment_id)
        SELECT '%s', '%s', %s, %s,
               '就诊提醒：' || d.name || ' ' || to_char(s.work_date, 'MM-DD')
                             || ' ' || s.time_slot,
               '您好 ' || p.name || '：您预约的 ' || d.name || ' ' || doc.name
                       || '（' || to_char(s.work_date, 'YYYY-MM-DD') || ' ' || s.weekday
                       || '，' || to_char(s.start_time, 'HH24:MI') || '-'
                       || to_char(s.end_time, 'HH24:MI') || '）在%s，'
                       || '请提前 15 分钟到院取号。如需取消，请回到系统「我的挂号」操作。',
               a.id
          FROM appointments a
          JOIN patients    p   ON p.id   = a.patient_id
          JOIN schedules   s   ON s.id   = a.schedule_id
          JOIN doctors     doc ON doc.id = a.doctor_id
          JOIN departments d   ON d.id   = doc.dept_id
         WHERE a.status = 'booked'
           AND s.closed = FALSE
           AND s.work_date = CURRENT_DATE + %%s::int
           %s
        ON CONFLICT (dedupe_key) DO NOTHING
    """ % (channel_val, template, key, recipient, when_word, where_mail)


def scan_reminders(now=None, ignore_window=False):
    """扫一遍「明天 / 今天」的待就诊单，生成提醒。

    返回 {(模板, 渠道): 新增条数}。新增 0 说明之前已经排过了（幂等生效）。
    """
    now = now or datetime.now()
    out = {}

    for template, offset, start_hour in RULES:
        if not ignore_window and now.hour < start_hour:
            continue
        for channel in ("inapp", "email"):
            sql = _build_sql(template, offset, channel)
            r = query(sql, [offset])
            out[(template, channel)] = r.rowcount
    return out


def expire_offers():
    """把过了保留期的候补标成 expired，并把号让给下一位。

    为什么不在触发器里做：没有人写入的时候，触发器不会醒过来。
    只能靠定时任务发现「这个 offer 已经超时了」。
    """
    expired = query(
        """UPDATE waitlist
              SET status = 'expired'
            WHERE status = 'offered'
              AND offer_expires_at <= NOW()
        RETURNING id, schedule_id, patient_id"""
    ).rows

    if not expired:
        return {"expired": 0, "reoffered": 0}

    # 同一个排班可能一次过期好几个（都超时了），逐个补位即可 ——
    # fn_offer_next_waitlist 每次都取队首，所以顺序自然是对的。
    schedules = []
    for row in expired:
        if row["schedule_id"] not in schedules:
            schedules.append(row["schedule_id"])

    reoffered = 0
    for sid in schedules:
        r = query("SELECT fn_offer_next_waitlist(%s) AS wl", [sid])
        if r.rows and r.rows[0]["wl"]:
            reoffered += 1

    return {"expired": len(expired), "reoffered": reoffered}


def tick(ignore_window=False):
    """跑一轮完整流程。"""
    from mailer import flush

    remind = scan_reminders(ignore_window=ignore_window)
    expire = expire_offers()
    mail = flush()
    return {"remind": remind, "expire": expire, "mail": mail}


def run_forever(interval=60):
    """常驻循环。Ctrl+C 退出。"""
    from mailer import CONFIG

    print("定时任务已启动（每 %d 秒一轮）：提醒 / 候补过期 / 发信" % interval)
    print("  发信配置：%s" % CONFIG.describe())
    print("  Ctrl+C 停止\n")
    try:
        while True:
            r = tick()
            newly = sum(v for v in r["remind"].values())
            if newly or r["expire"]["expired"] or r["mail"]["sent"] or r["mail"]["failed"]:
                print("[%s] 新提醒 %d 条 / 候补过期 %d 条（补位 %d）/ 发出 %d 封（失败 %d）"
                      % (datetime.now().strftime("%H:%M:%S"), newly,
                         r["expire"]["expired"], r["expire"]["reoffered"],
                         r["mail"]["sent"], r["mail"]["failed"]))
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n已停止")


if __name__ == "__main__":
    r = tick(ignore_window=True)
    print("提醒：%s" % r["remind"])
    print("候补过期：%s" % r["expire"])
    print("发信：%s" % r["mail"])
