# -*- coding: utf-8 -*-
"""口令散列与就诊人信息校验。

分两块：
  一、后台账号口令 —— 存散列不存明文
  二、就诊人信息（姓名 / 证件 / 手机号）—— 服务端必须独立校验；支持护照、港澳台证件与国际手机号

★ 为什么服务端还要再校验一遍：前端也会校验，但前端的东西在浏览器里，
  改一下 JS、或者直接用 curl 发请求就绕过去了。绝不能信前端传什么就存什么。
  数据库那边还有 ck_appt_idcard / ck_appt_phone 两条 CHECK 兜底。
"""

import hashlib
import hmac
import re
import secrets
from datetime import date
from business_time import today

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
_RE_PHONE_INTL = re.compile(r"^\d{4,11}$")
_RE_PHONE_CC = re.compile(r"^[1-9]\d{0,3}$")
_RE_NAME_ZH = re.compile(r"^[\u4e00-\u9fa5·]{2,20}$")
# 外文姓名按证件上的拉丁字母写法：字母（含 é、ñ 等带变音符号的字母）、空格、点、连字符、撇号
_RE_NAME_LATIN = re.compile(r"^[A-Za-z\u00C0-\u024F][A-Za-z\u00C0-\u024F .'\-]{0,48}[A-Za-z\u00C0-\u024F.]$")
_RE_NATIONALITY = re.compile(r"^[A-Z]{2}$")
_RE_EMAIL = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")

# 证件类型（与 schema_intl.sql 的 ck_patients_id_type 一致）
ID_TYPES = ("CN_ID", "HMT_RES", "FRP", "HK_MO", "TW", "PASSPORT")


def _gb11643_ok(v):
    """18 位证件号的 GB 11643 校验位。"""
    if not _RE_ID_CARD.match(v):
        return False
    total = sum(int(v[i]) * ID_WEIGHTS[i] for i in range(17))
    return ID_CODES[total % 11] == v[17]


def check_id_card(raw):
    """身份证：18 位 + 校验位 + 出生日期合法性。"""
    v = str(raw or "").strip().upper()
    if not _RE_ID_CARD.match(v):
        return False, "身份证号格式不正确（需 18 位）", None

    if not _gb11643_ok(v):
        return False, "身份证号校验位错误，请核对", None

    # 出生日期必须是日历上真实存在的一天（2000-02-31 这种校验位碰巧对的也要拦），且不晚于今天
    try:
        born = date(int(v[6:10]), int(v[10:12]), int(v[12:14]))
    except ValueError:
        return False, "身份证中的出生日期不存在，请核对", None
    if born.year < 1900 or born > today():
        return False, "身份证中的出生日期不合法", None

    return True, None, v


def doc_key(id_type, nationality, number):
    """证件键（与数据库 fn_doc_key 一致）：护照带上国籍，其余就是证件号。"""
    if id_type == "PASSPORT":
        return "P:%s:%s" % ((nationality or "").upper(), number.upper())
    return number.upper()


def check_document(id_type, nationality, raw):
    """按证件类型校验证件号。返回 (ok, msg, {idType, nationality, idCard, docKey})。

    规则与数据库 fn_doc_valid 一致；服务端先查一遍是为了给出具体的中文提示。
    """
    t = str(id_type or "CN_ID").strip().upper()
    if t not in ID_TYPES:
        return False, "不支持的证件类型", None
    v = re.sub(r"[\s-]", "", str(raw or "")).upper()
    nat = str(nationality or "").strip().upper() or None
    if nat is not None and not _RE_NATIONALITY.match(nat):
        return False, "国籍 / 地区代码不正确", None

    if t == "CN_ID":
        ok, msg, v2 = check_id_card(v)
        if not ok:
            return False, msg, None
        if v2.startswith(("81", "82", "83", "9")):
            return False, "这是港澳台居民居住证或外国人永居证号码，请选择对应的证件类型", None
        v, nat = v2, None
    elif t == "HMT_RES":
        if not (_gb11643_ok(v) and v[:6] in ("810000", "820000", "830000")):
            return False, "港澳台居民居住证号码应为 18 位，以 810000 / 820000 / 830000 开头，且校验位正确", None
        nat = None
    elif t == "FRP":
        if not ((_gb11643_ok(v) and v.startswith("9")) or re.match(r"^[A-Z]{3}\d{12}$", v)):
            return False, "外国人永久居留身份证号码不正确（新版 18 位以 9 开头，旧版 3 位字母 + 12 位数字）", None
        if not nat:
            return False, "请选择国籍", None
    elif t == "HK_MO":
        if not re.match(r"^[HM]\d{8}(\d{2})?$", v):
            return False, "港澳居民来往内地通行证号码应为 H 或 M 开头加 8 或 10 位数字", None
        nat = None
    elif t == "TW":
        if not re.match(r"^\d{8}(\d{2})?$", v):
            return False, "台湾居民来往大陆通行证号码应为 8 或 10 位数字", None
        nat = None
    else:  # PASSPORT
        if not re.match(r"^[A-Z0-9]{5,14}$", v):
            return False, "护照号码应为 5–14 位字母或数字", None
        if not nat:
            return False, "请选择护照签发国家 / 地区", None

    return True, None, {"idType": t, "nationality": nat, "idCard": v, "docKey": doc_key(t, nat, v)}


def doc_sex(id_type, number):
    """身份证、港澳台居住证从第 17 位读出性别（奇数男、偶数女）；其他证件读不出，返回 None。"""
    if id_type in ("CN_ID", "HMT_RES") and _RE_ID_CARD.match(number or ""):
        return "M" if int(number[16]) % 2 == 1 else "F"
    return None


def resolve_sex(id_type, number, raw_sex):
    """(ok, msg, sex)：证件能读出性别就以证件为准；读不出就必须由患者选择 M / F。"""
    sex = doc_sex(id_type, number)
    if sex:
        return True, None, sex
    v = str(raw_sex or "").strip().upper()
    if v not in ("M", "F"):
        return False, "请选择性别", None
    return True, None, v


def check_doc_key(raw):
    """只拿证件键查询时（我的预约、候补、站内信……）的宽松校验：大写、长度合理、字符集合法。"""
    v = str(raw or "").strip().upper()
    if not re.match(r"^(P:[A-Z]{2}:)?[A-Z0-9]{5,18}$", v):
        return False, "证件号格式不正确", None
    return True, None, v


# 各国 / 地区手机号（不含区号、不含国内长途前缀 0）的格式，和前端 app.js 的 PHONE_RULES 是同一张表。
# 表里没有的区号退回到「4–11 位数字」。
PHONE_RULES = {
    "1": r"[2-9]\d{2}[2-9]\d{6}",
    "7": r"[79]\d{9}",
    "20": r"1[0125]\d{8}",
    "27": r"[6-8]\d{8}",
    "30": r"69\d{8}",
    "31": r"6\d{8}",
    "32": r"4\d{8}",
    "33": r"[67]\d{8}",
    "34": r"[67]\d{8}",
    "39": r"3\d{8,9}",
    "41": r"7[5-9]\d{7}",
    "43": r"6\d{8,10}",
    "44": r"7\d{9}",
    "45": r"[2-9]\d{7}",
    "46": r"7\d{8}",
    "47": r"[49]\d{7}",
    "48": r"[4-8]\d{8}",
    "49": r"1[5-7]\d{8,9}",
    "51": r"9\d{8}",
    "52": r"\d{10}",
    "53": r"5\d{7}",
    "54": r"9?\d{10}",
    "55": r"[1-9]{2}9\d{8}",
    "56": r"9\d{8}",
    "57": r"3\d{9}",
    "58": r"4\d{9}",
    "60": r"1\d{8,9}",
    "61": r"4\d{8}",
    "62": r"8\d{8,10}",
    "63": r"9\d{9}",
    "64": r"2\d{7,9}",
    "65": r"[89]\d{7}",
    "66": r"[689]\d{8}",
    "81": r"[789]0\d{8}",
    "82": r"1[016-9]\d{7,8}",
    "84": r"[35789]\d{8}",
    "86": r"1[3-9]\d{9}",
    "90": r"5\d{9}",
    "91": r"[6-9]\d{9}",
    "92": r"3\d{9}",
    "93": r"7\d{8}",
    "94": r"7\d{8}",
    "95": r"9\d{7,9}",
    "98": r"9\d{9}",
    "212": r"[67]\d{8}",
    "213": r"[567]\d{8}",
    "216": r"[2-9]\d{7}",
    "233": r"[235]\d{8}",
    "234": r"[789][01]\d{8}",
    "237": r"6\d{8}",
    "243": r"[89]\d{8}",
    "244": r"9\d{8}",
    "249": r"9\d{8}",
    "250": r"7\d{8}",
    "251": r"[79]\d{8}",
    "254": r"[17]\d{8}",
    "255": r"[67]\d{8}",
    "256": r"7\d{8}",
    "258": r"8\d{8}",
    "260": r"[79]\d{8}",
    "263": r"7\d{8}",
    "351": r"9\d{8}",
    "353": r"8\d{8}",
    "358": r"[45]\d{6,9}",
    "375": r"[234]\d{8}",
    "380": r"[3-9]\d{8}",
    "420": r"[67]\d{8}",
    "852": r"[4-9]\d{7}",
    "853": r"6\d{7}",
    "855": r"[1-9]\d{7,8}",
    "856": r"20\d{8}",
    "880": r"1\d{9}",
    "886": r"9\d{8}",
    "964": r"7\d{9}",
    "966": r"5\d{8}",
    "971": r"5\d{8}",
    "976": r"[5-9]\d{7}",
    "977": r"9\d{9}",
    "992": r"\d{9}",
    "993": r"6\d{7}",
    "996": r"[2-9]\d{8}",
    "998": r"\d{9}",
}
PHONE_RULES = {k: re.compile("^(?:" + v + ")$") for k, v in PHONE_RULES.items()}


def normalize_phone(raw, cc):
    """去掉空格、横线、点、括号；去掉顺手输入的 +区号 / 00区号；不合格式但去掉开头一个 0 就合格的（国内拨号习惯，如英国 07…、日本 090…）去掉 0。"""
    v = re.sub(r"[\s\-.()（）]", "", str(raw or ""))
    for pre in ("+" + cc, "00" + cc):
        if v.startswith(pre) and len(v) > len(pre) + 3:
            v = v[len(pre):]
            break
    rule = PHONE_RULES.get(cc, _RE_PHONE_INTL)
    if not rule.match(v) and v.startswith("0") and rule.match(v[1:]):
        v = v[1:]
    return v


def check_phone(raw, cc="86"):
    """手机号：按区号查 PHONE_RULES 校验本地号码，区号单独传。格式不对统一提示「手机号格式不正确」。"""
    cc = str(cc or "86").strip().lstrip("+")
    if not _RE_PHONE_CC.match(cc):
        return False, "手机号格式不正确", None
    v = normalize_phone(raw, cc)
    if not PHONE_RULES.get(cc, _RE_PHONE_INTL).match(v):
        return False, "手机号格式不正确", None
    return True, None, v


def check_name(raw):
    """姓名：中文 2–20 字，或证件上的拉丁字母写法（如 John Smith），多余空格合并成一个。"""
    v = re.sub(r"\s+", " ", str(raw or "").strip())
    if not (_RE_NAME_ZH.match(v) or _RE_NAME_LATIN.match(v)):
        return False, "姓名需为 2-20 个中文字符，或与证件一致的英文字母", None
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
    """一次把姓名、证件、手机号都校验了，第一个不通过就返回那一条。

    证件类型 idType 不传按居民身份证处理；护照、外国人永居证还要传国籍 nationality；
    手机区号 phoneCc 不传按 86（中国大陆）。
    """
    patient = patient if isinstance(patient, dict) else {}

    ok, msg, name = check_name(patient.get("name"))
    if not ok:
        return False, msg, None

    ok, msg, doc = check_document(patient.get("idType"), patient.get("nationality"), patient.get("idCard"))
    if not ok:
        return False, msg, None
    ok, msg, sex = resolve_sex(doc["idType"], doc["idCard"], patient.get("sex"))
    if not ok:
        return False, msg, None

    cc = str(patient.get("phoneCc") or "86").strip().lstrip("+")
    ok, msg, phone = check_phone(patient.get("phone"), cc)
    if not ok:
        return False, msg, None

    return True, None, dict(doc, name=name, phone=phone, phoneCc=cc, sex=sex)
