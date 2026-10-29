# -*- coding: utf-8 -*-
"""口令散列与就诊人信息校验。

分两块：
  一、后台账号口令 —— 存散列不存明文
  二、就诊人三要素（姓名 / 身份证 / 手机号）—— 服务端必须独立校验

★ 为什么服务端还要再校验一遍：前端也会校验，但前端的东西在浏览器里，
  改一下 JS、或者直接用 curl 发请求就绕过去了。绝不能信前端传什么就存什么。
  数据库那边还有 ck_appt_idcard / ck_appt_phone 两条 CHECK 兜底。
"""

import hashlib
import hmac
import re
import secrets
from datetime import date

# ============================================================
# 一、口令散列
#
# 存进数据库的格式：  scrypt$<盐>$<散列>
# 每条口令的盐都不一样，所以两个人密码相同，存进去也不一样。
#
# ★ 参数必须和旧版 Node 完全一致，否则库里已有的口令就登不上了：
#   Node 的 crypto.scryptSync(password, salt, 64) 默认 N=16384, r=8, p=1，
#   并且把「盐的十六进制字符串」直接当成 UTF-8 字节用（不是把它解码成字节）。
# ============================================================

SCRYPT_N = 16384
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 64
# 128 * N * r = 16 MiB，留足余量，否则 OpenSSL 会报 memory limit exceeded
SCRYPT_MAXMEM = 64 * 1024 * 1024


def hash_password(plain):
    """生成 scrypt$<盐>$<散列>，用于首次灌库。"""
    salt = secrets.token_hex(16)          # 32 个十六进制字符，和 Node 的 16 字节一致
    digest = hashlib.scrypt(
        str(plain).encode("utf-8"),
        salt=salt.encode("ascii"),        # ★ 盐按「字符串本身」参与运算，和 Node 一致
        n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P,
        dklen=SCRYPT_DKLEN, maxmem=SCRYPT_MAXMEM,
    )
    return "scrypt$%s$%s" % (salt, digest.hex())


def verify_password(plain, stored):
    """校验口令。格式不对、算不出来、对不上，一律返回 False。"""
    parts = str(stored or "").split("$")
    if len(parts) != 3 or parts[0] != "scrypt":
        return False

    salt, want_hex = parts[1], parts[2]
    try:
        want = bytes.fromhex(want_hex)
    except ValueError:
        return False

    calc = hashlib.scrypt(
        str(plain).encode("utf-8"),
        salt=salt.encode("ascii"),
        n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P,
        dklen=SCRYPT_DKLEN, maxmem=SCRYPT_MAXMEM,
    )
    # 定长比较，避免按字节短路带来的时间差（等价于 Node 的 timingSafeEqual）
    return hmac.compare_digest(calc, want)


# ============================================================
# 二、就诊人信息校验
# ============================================================

# 身份证前 17 位的加权因子，以及加权和模 11 之后对应的校验位
ID_WEIGHTS = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
ID_CODES = ("1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2")

_RE_ID_CARD = re.compile(r"^\d{17}[\dX]$")
_RE_PHONE = re.compile(r"^1[3-9]\d{9}$")
_RE_NAME = re.compile(r"^[\u4e00-\u9fa5·]{2,20}$")
_RE_EMAIL = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")


def check_id_card(raw):
    """身份证：18 位 + 校验位 + 出生日期合法性。"""
    v = str(raw or "").strip().upper()
    if not _RE_ID_CARD.match(v):
        return False, "身份证号格式不正确（需 18 位）", None

    total = 0
    for i in range(17):
        total += int(v[i]) * ID_WEIGHTS[i]
    if ID_CODES[total % 11] != v[17]:
        return False, "身份证号校验位错误，请核对", None

    year = int(v[6:10])
    month = int(v[10:12])
    day = int(v[12:14])
    if year < 1900 or year > date.today().year:
        return False, "身份证中的出生年份不合法", None
    if month < 1 or month > 12:
        return False, "身份证中的出生月份不合法", None
    if day < 1 or day > 31:
        return False, "身份证中的出生日期不合法", None

    return True, None, v


def check_phone(raw):
    v = str(raw or "").strip()
    if not _RE_PHONE.match(v):
        return False, "手机号格式不正确", None
    return True, None, v


def check_name(raw):
    v = str(raw or "").strip()
    if not _RE_NAME.match(v):
        return False, "姓名需为 2-20 个中文字符", None
    return True, None, v


def check_email(raw):
    """邮箱：可以不填（不填就收不到提醒），填了就必须像个邮箱。

    ★ 不用第三方校验库：一个正则 + 长度上限，对「收提醒」这个用途足够了。
      真要去重、判可达性，那是发信那一刻的事（退信会进 last_error）。
    """
    v = str(raw or "").strip()
    if not v:
        return True, None, None
    if len(v) > 120:
        return False, "邮箱地址过长（最多 120 个字符）", None
    if not _RE_EMAIL.match(v):
        return False, "邮箱格式不正确", None
    return True, None, v.lower()


def check_patient(patient):
    """一次把三个都校验了，第一个不通过就返回那一条。"""
    patient = patient if isinstance(patient, dict) else {}

    ok, msg, name = check_name(patient.get("name"))
    if not ok:
        return False, msg, None

    ok, msg, id_card = check_id_card(patient.get("idCard"))
    if not ok:
        return False, msg, None

    ok, msg, phone = check_phone(patient.get("phone"))
    if not ok:
        return False, msg, None

    return True, None, {"name": name, "idCard": id_card, "phone": phone}
