# -*- coding: utf-8 -*-
"""接口限流 + 放号验证码 —— 防黄牛里「只能在接口层做」的那两件事。

为什么这两件事不能写进数据库：
    取消次数、黑名单是「这个人还能不能挂号」的业务规则，任何写入路径都该受约束，
    所以它们在触发器里（见 schema_v3.sql 的 fn_appt_guard_before_insert）。
    而限流和验证码本质是「挡住机器请求」—— 它们关心的是请求频率、
    是不是人，跟数据长什么样无关，数据库管不了，只能放在门口。

两个实现都刻意做成内存版：
    单进程的教学演示不需要 Redis。真上生产要换成 Redis 或 nginx 限流，
    这一点在报告里如实写，比假装能扛住更可信。

    RATE_LIMIT_DISABLED=1        关掉限流（跑测试时用）
    CAPTCHA_DISABLED=1           关掉验证码
    CAPTCHA_REMAIN_THRESHOLD=3   余号 ≤ 3 时才要求验证码
"""

import os
import random
import secrets
import threading
import time
from collections import defaultdict, deque

# ------------------------------------------------------------
# 一、限流：滑动窗口
# ------------------------------------------------------------
# 每个 key 存一串「这次请求发生在什么时候」，超过窗口的从左边丢掉，
# 剩下的条数就是窗口内的请求数。比固定窗口（每分钟清零）更平滑，
# 不会出现「59 秒打满 20 次、01 秒再打 20 次」的漏洞。
WINDOW_SECONDS = 60

# (方法, 路径前缀) → 每分钟允许的次数。'*' 表示任意方法。
LIMITS = [
    ("POST", "/api/appointments", 20),
    ("POST", "/api/waitlist", 20),
    ("POST", "/api/auth/login", 10),
    ("POST", "/api/patient-auth", 10),     # 发码 / 校验码：防刷短信、防暴力猜码
    ("*", "/api/captcha", 30),
    ("*", "/api/", 300),
]

_hits = defaultdict(deque)
_lock = threading.Lock()


def _limit_for(method, path):
    """取最具体的那条规则：先找「方法 + 路径」完全匹配，再退到通配。"""
    for m, prefix, n in LIMITS:
        if m == method and path.startswith(prefix):
            return n, prefix
    for m, prefix, n in LIMITS:
        if m == "*" and path.startswith(prefix):
            return n, prefix
    return None, None


def check_rate(method, path, client_ip):
    """返回 (是否放行, 需要等多少秒)。

    放行时把这次请求记进窗口 —— 所以这个函数有副作用，只能调用一次。
    """
    if os.environ.get("RATE_LIMIT_DISABLED") == "1":
        return True, 0

    limit, scope = _limit_for(method, path)
    if limit is None:
        return True, 0

    key = "%s|%s|%s" % (client_ip, method, scope)
    now = time.monotonic()

    with _lock:
        q = _hits[key]
        while q and now - q[0] > WINDOW_SECONDS:
            q.popleft()

        if len(q) >= limit:
            retry = int(WINDOW_SECONDS - (now - q[0])) + 1
            return False, max(1, retry)

        q.append(now)

    # 顺手清理长期不用的 key，避免字典无限涨（每 500 次请求扫一遍）
    if random.random() < 0.002:
        with _lock:
            for k in [k for k, v in _hits.items() if not v or now - v[-1] > 600]:
                _hits.pop(k, None)

    return True, 0


def snapshot():
    """给管理端看的限流现状（哪个 IP 被打得最狠）。"""
    now = time.monotonic()
    with _lock:
        out = []
        for k, v in _hits.items():
            live = [t for t in v if now - t <= WINDOW_SECONDS]
            if live:
                ip, method, scope = k.split("|", 2)
                out.append({"ip": ip, "method": method, "scope": scope,
                            "count": len(live)})
    out.sort(key=lambda x: -x["count"])
    return out[:20]


# ------------------------------------------------------------
# 二、放号验证码
# ------------------------------------------------------------
# 用算术题而不是图形码：图形码要装 Pillow、要存图片，教学机上不划算；
# 算术题同样能挡住「一个脚本连开 20 个连接」这种最朴素的抢号方式，
# 而且答案在服务端校验、一次性、5 分钟过期，够用了。
CAPTCHA_TTL = 300
_challenges = {}
_captcha_lock = threading.Lock()


def captcha_threshold():
    try:
        return int(os.environ.get("CAPTCHA_REMAIN_THRESHOLD") or 3)
    except ValueError:
        return 3


def captcha_required(remain):
    """余号少到一定程度才要求验证码。

    为什么不每次都要求：正常挂号也弹验证码，患者体验很差；
    只有「抢手号源」（余号 ≤ 3）才是黄牛的目标。
    """
    if os.environ.get("CAPTCHA_DISABLED") == "1":
        return False
    return remain is not None and remain <= captcha_threshold()


def issue_captcha():
    """出一道题，返回 token 与题面。答案只留在服务端。"""
    a = random.randint(3, 19)
    b = random.randint(2, 9)
    op = random.choice(["+", "-", "×"])
    if op == "+":
        ans = a + b
    elif op == "-":
        if a < b:
            a, b = b, a
        ans = a - b
    else:
        ans = a * b

    token = secrets.token_urlsafe(16)
    now = time.time()
    with _captcha_lock:
        # 顺手清掉过期的
        for k in [k for k, v in _challenges.items() if v[1] < now]:
            _challenges.pop(k, None)
        _challenges[token] = (str(ans), now + CAPTCHA_TTL)

    return {"token": token, "question": "%d %s %d = ?" % (a, op, b), "ttl": CAPTCHA_TTL}


def verify_captcha(token, answer):
    """校验并作废。一次一用 —— 否则同一道题可以被脚本复用。"""
    if os.environ.get("CAPTCHA_DISABLED") == "1":
        return True
    if not token or answer is None:
        return False

    with _captcha_lock:
        item = _challenges.pop(str(token), None)

    if not item:
        return False
    want, expire_at = item
    if time.time() > expire_at:
        return False
    return str(answer).strip() == want
