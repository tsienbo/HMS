# -*- coding: utf-8 -*-
"""智慧医院预约挂号系统 —— 后端（Python + Flask + PostgreSQL）

怎么用：
    python server/app.py            启动服务，打开 http://127.0.0.1:3000/
    python server/app.py --init     初始化数据库（幂等：缺什么补什么，不动已有数据）
    python server/app.py --force    删表重建（★ 会清空所有挂号记录）

本文件从上往下依次是：
    一、应用与静态文件
    二、判断「这次请求是谁在操作」
    三、接口：登录 / 注销 / 当前用户
    四、接口：科室 / 医生 / 排班（只读）
    五、接口：挂号 / 退号 / 挂号记录
    六、接口：管理端调号源 / 停诊
    七、健康检查
    八、404 与兜底错误处理
    九、启动

其余几个文件各管一件事：
    db.py         连接池、query()、错误翻译、行 → JSON
    seed_data.py  科室 / 医生 / 账号等基础数据，以及排班生成规则
    init_db.py    建库建表灌数据 + 一致性自检
    validators.py 口令散列 + 就诊人信息校验
    schema.sql    建表语句 + 约束 + 索引 + 视图 + 触发器
                  （本文件不解析它，由 init_db.py 整份发过去）
    migrate_v2.py v1 库 → v2 库的一次性迁移（保留既有数据）

★ 号源的增减不在这份代码里：挂号 +1、退号 -1 都由 schema.sql 里的
  触发器完成，应用层只管 INSERT / UPDATE 状态。详见 create_appointment()。
"""

import hashlib
import os
import re
import secrets
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory
from werkzeug.exceptions import HTTPException

import guard
from db import (
    as_date_str, as_float, as_iso, db_error, health_check, map_appointment,
    map_department, map_doctor, map_schedule, mask_id_card_str, mask_phone_str,
    pool, query,
)
from seed_data import SESSION_TTL_HOURS
from validators import (check_email, check_id_card, check_name, check_phone,
                         check_patient, verify_password)

# 生成随机预约单号（10 位大写字母+数字，查重后返回）
_APPT_NO_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


def generate_appointment_no():
    while True:
        no = "".join(secrets.choice(_APPT_NO_CHARS) for _ in range(10))
        if query("SELECT 1 FROM appointments WHERE appointment_no = %s", [no]).rowcount == 0:
            return no


# 项目根目录 = server/ 的上一层。前端页面也由这个服务一起发出去，
# 所以不用再开第二个端口。
ROOT = Path(__file__).resolve().parent.parent
# 前端文件全部放在 web/ 里，对外只公开这一个目录
WEB = ROOT / "web"

# 后端监听的端口。平时就是 3000。
PORT = int(os.environ.get("PORT") or 3000)
# 监听地址。默认只听本机；想让同一局域网内的手机访问就设 HOST=0.0.0.0
HOST = os.environ.get("HOST") or "127.0.0.1"


# ============================================================
# 一、应用与静态文件
# ============================================================

# ★ 静态目录只能是 web/，不能是项目根目录：那样 /server/mail.env（SMTP 密码）、
#   /server/db.py（数据库密码）、/.git/、/.mail-outbox.log（验证码）都能被直接下载。
#   web/ 里只放浏览器需要的文件，别的东西一律不要放进去。
app = Flask(__name__, static_folder=str(WEB), static_url_path="")

# 前端一次最多能发多大的请求体。挂号表单很小，256KB 足够。
app.config["MAX_CONTENT_LENGTH"] = 256 * 1024

# 两个容易被忽略的细节：
#   sort_keys=False —— 保持字段顺序，和以前 Node 版的 JSON 输出一模一样
#                     （截图里 {"id":..., "seqNo":..., "fee":...} 的顺序不变）
#   ensure_ascii=False —— 中文直接输出成「内科」而不是 "\u5185\u79d1"，
#                     抓包和截图里都能直接看懂
app.json.sort_keys = False
app.json.ensure_ascii = False


@app.get("/")
def index():
    """首页。Express 的 express.static 会自动把 / 指到 index.html，这里显式写一行。"""
    return send_from_directory(WEB, "index.html")


# ------------------------------------------------------------
# 限流：进门前先数人头
#
# 放在 before_request 而不是每个接口里，是因为「漏掉一个接口」就是漏洞。
# 规则表在 guard.py：挂号 / 候补 20 次每分钟、登录 10 次、其它接口合计 300 次。
# ------------------------------------------------------------
@app.before_request
def throttle():
    if not request.path.startswith("/api/"):
        return None

    allowed, retry = guard.check_rate(request.method, request.path, client_ip())
    if allowed:
        return None

    resp = jsonify(
        error="请求过于频繁，请 %d 秒后再试" % retry,
        code="RATE_LIMITED",
        retryAfter=retry,
    )
    resp.status_code = 429
    resp.headers["Retry-After"] = str(retry)
    return resp


def client_ip():
    """取客户端 IP。反向代理后面取 X-Forwarded-For 的第一段。"""
    fwd = (request.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
    return fwd or request.remote_addr or "-"


# ============================================================
# 二、判断「这次请求是谁在操作」
#
# 登录成功后服务端发一个随机令牌存进 user_sessions 表，
# 前端每次请求把它放在 Authorization: Bearer xxx 里。
# 这里负责把令牌换成用户；没登录就返回 None。
# ============================================================

_RE_BEARER = re.compile(r"^Bearer\s+(.+)$", re.I)


def get_login_user():
    m = _RE_BEARER.match((request.headers.get("Authorization") or "").strip())
    if not m:
        return None

    r = query(
        """SELECT s.token, s.expires_at, u.id, u.username, u.display_name, u.role
             FROM user_sessions s
             JOIN users u ON u.id = s.user_id
            WHERE s.token = %s AND s.expires_at > NOW() AND u.status = 'active'""",
        [m.group(1).strip()],
    )
    if r.rowcount == 0:
        return None

    row = r.rows[0]
    return {
        "token": row["token"],
        "id": row["id"],
        "username": row["username"],
        "displayName": row["display_name"],
        "role": row["role"],
        "expiresAt": as_iso(row["expires_at"]),
    }


# ------------------------------------------------------------
# 角色：谁能做什么
#
#   admin   全部
#   auditor 只读：报表 + 审计日志，不能改号源、不能代约
#   desk    窗口人员：代约、看挂号记录（脱敏），不能看审计日志
#
# ★ 判断的是「角色」不是「用户名」：加人减人只改 users.role 一行数据。
# ------------------------------------------------------------
def require_login():
    user = get_login_user()
    if not user:
        return None, (jsonify(error="未登录或登录已过期，请重新登录",
                              code="UNAUTHORIZED"), 401)
    return user, None


def require_role(*roles):
    """返回 (user, 错误响应)。roles 为空表示只要登录即可。"""
    user, err = require_login()
    if err:
        return None, err
    if roles and user["role"] not in roles:
        return None, (jsonify(error="当前账号无权执行该操作（需要 %s 角色）"
                                    % " / ".join(roles),
                              code="FORBIDDEN"), 403)
    return user, None


def write_access_log(user, action, target_type, target_id,
                     patient_id=None, reason=None):
    """记一条「谁看了谁的隐私」。

    故意做成「写失败也不影响主流程」—— 审计是旁路，
    不能因为它自己出错就让医生看不到病人信息（那样人就会绕过系统）。
    真出问题由日志里的告警发现。
    """
    try:
        query(
            """INSERT INTO access_log
                 (user_id, username, action, target_type, target_id,
                  patient_id, reason, client_ip)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
            [user["id"], user["username"], action, target_type, target_id,
             patient_id, reason, client_ip()],
        )
    except Exception as err:                                  # noqa: BLE001
        app.logger.warning("[访问日志写入失败] %s", err)


def body_json():
    """读请求体里的 JSON。不是 JSON、或者没有请求体，都当空字典处理。"""
    return request.get_json(silent=True) or {}


# ------------------------------------------------------------
# 患者凭证
#
# 患者端没有账号。以前只凭身份证号就能查 / 退 / 改别人的东西，
# 现在要带 X-Patient-Token：首次建档时发一个，或者向档案登记的
# 手机 / 邮箱发验证码换一个（见「患者身份验证」一节）。
# 一台手机可能替全家挂号，所以请求头里可以放多个，用逗号隔开。
# ------------------------------------------------------------
PATIENT_TOKEN_DAYS = 30


def _hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def issue_patient_token(patient_id):
    token = secrets.token_urlsafe(32)
    query(
        """INSERT INTO patient_sessions (token_hash, patient_id, expires_at)
           VALUES (%s, %s, NOW() + make_interval(days => %s))""",
        [_hash_token(token), patient_id, PATIENT_TOKEN_DAYS],
    )
    return token


def request_patient_ids():
    """请求头里所有有效凭证对应的 patient_id 集合。"""
    raw = request.headers.get("X-Patient-Token") or ""
    hashes = [_hash_token(t.strip()) for t in raw.split(",") if t.strip()][:10]
    if not hashes:
        return set()
    r = query(
        """SELECT patient_id FROM patient_sessions
            WHERE token_hash = ANY(%s) AND expires_at > NOW()""",
        [hashes],
    )
    return {x["patient_id"] for x in r.rows}


def patient_auth_error():
    return jsonify(error="为保护隐私，请先验证就诊人身份",
                   code="PATIENT_AUTH_REQUIRED"), 401


def require_patient_by_id_card(id_card):
    """(patient_id, 错误响应)。身份证号对应的档案必须在本次请求的凭证里。"""
    id_card = str(id_card or "").strip().upper()
    if not id_card:
        return None, (jsonify(error="请提供就诊人身份证号"), 400)
    r = query("SELECT id FROM patients WHERE id_card = %s", [id_card])
    # 档案不存在也回 401：不让「有没有这个人」从这里被试探出来
    if r.rowcount == 0 or r.rows[0]["id"] not in request_patient_ids():
        return None, patient_auth_error()
    return r.rows[0]["id"], None


# ============================================================
# 三、登录 / 注销 / 当前用户
# ============================================================

@app.post("/api/auth/login")
def auth_login():
    """查用户表 → 比对口令散列 → 发一个随机令牌存进 user_sessions。"""
    try:
        body = body_json()
        username = str(body.get("username") or "").strip().lower()
        password = str(body.get("password") or "")

        if not username or not password:
            return jsonify(error="请输入用户名与密码"), 400

        r = query(
            "SELECT id, username, password_hash, display_name, status, role "
            "FROM users WHERE username = %s",
            [username],
        )

        # 「账号不存在」和「密码错误」回同一句话，别让人试出哪些账号存在
        fail = {"error": "用户名或密码错误", "code": "BAD_CREDENTIALS"}
        if r.rowcount == 0:
            return jsonify(fail), 401

        u = r.rows[0]
        if not verify_password(password, u["password_hash"]):
            return jsonify(fail), 401
        if u["status"] != "active":
            return jsonify(error="该账号已被停用，请联系管理员",
                           code="ACCOUNT_DISABLED"), 403

        token = secrets.token_hex(32)
        expires_at = datetime.now(timezone.utc) + timedelta(hours=SESSION_TTL_HOURS)

        # 顺手清掉过期会话，省得单独写个定时任务
        query("DELETE FROM user_sessions WHERE expires_at <= NOW()")
        query(
            "INSERT INTO user_sessions (token, user_id, expires_at) VALUES (%s, %s, %s)",
            [token, u["id"], expires_at],
        )
        query("UPDATE users SET last_login_at = NOW() WHERE id = %s", [u["id"]])

        return jsonify(
            token=token,
            expiresAt=as_iso(expires_at),
            ttlHours=SESSION_TTL_HOURS,
            user={"id": u["id"], "username": u["username"],
                  "displayName": u["display_name"], "role": u["role"]},
        )
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[登录] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.post("/api/auth/logout")
def auth_logout():
    """注销：把会话那一行删掉。"""
    try:
        user = get_login_user()
        if not user:
            return jsonify(error="未登录或登录已过期，请重新登录"), 401

        query("DELETE FROM user_sessions WHERE token = %s", [user["token"]])
        return jsonify(ok=True)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[注销] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/auth/me")
def auth_me():
    """当前登录用户：前端刷新页面时用它确认本地令牌还有效。"""
    try:
        user = get_login_user()
        if not user:
            return jsonify(error="未登录或登录已过期，请重新登录"), 401

        r = query(
            "SELECT id, username, display_name, role FROM users WHERE id = %s",
            [user["id"]],
        )
        if r.rowcount == 0:
            return jsonify(error="账号不存在", code="UNAUTHORIZED"), 401

        u = r.rows[0]
        return jsonify(
            user={"id": u["id"], "username": u["username"],
                  "displayName": u["display_name"], "role": u["role"]},
            expiresAt=user["expiresAt"],
        )
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[当前用户] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 四、科室 / 医生 / 排班（都是只读查询）
# ============================================================

@app.get("/api/departments")
def departments():
    try:
        r = query("SELECT id, name, description, location FROM departments ORDER BY id")
        return jsonify([map_department(x) for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[科室列表] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/departments/<dept_id>/doctors")
def department_doctors(dept_id):
    """某科室的医生，带上「还剩多少号」。

    remain 只统计今天及以后、没停诊的排班。
    """
    try:
        # remain 直接读视图 v_available_schedules：
        # 那个视图已经把「今天及以后 / 没停诊 / 还有余号」三件事过滤好了，
        # 这里只按医生汇总，不用再重复一遍条件。
        r = query(
            """SELECT d.*,
                      COALESCE((
                        SELECT SUM(v.remain)
                          FROM v_available_schedules v
                         WHERE v.doctor_id = d.id
                      ), 0)::int AS remain
                 FROM doctors d
                WHERE d.dept_id = %s AND d.is_active
                ORDER BY CASE d.title
                           WHEN '主任医师'   THEN 1
                           WHEN '副主任医师' THEN 2
                           ELSE 3 END, d.id""",
            [dept_id],
        )
        return jsonify([map_doctor(x) for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[科室医生] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 四之二、患者个人资料（② 编辑病人个人资料）
#
# 患者端没有「账号登录」这种东西 —— 身份靠身份证号识别，
# 和「我的挂号」「我的候补」完全一致。所以这里也用 idCard 当查询键，
# 不要求后端登录。身份证号本身不可改（它是档案主键的等价物），
# 能改的只有姓名、手机号、邮箱三项。
# ============================================================

@app.get("/api/patients/mine")
def patient_mine_get():
    """按身份证查自己的档案。身份证号脱敏返回，避免页面上暴露完整证件号。"""
    try:
        pid, err = require_patient_by_id_card(request.args.get("idCard"))
        if err:
            return err

        r = query(
            "SELECT id, name, id_card, phone, email FROM patients WHERE id = %s",
            [pid],
        )
        if r.rowcount == 0:
            return jsonify(error="未找到该就诊人的档案，请先挂一次号", code="NO_RECORD"), 404

        p = r.rows[0]
        return jsonify({
            "id": p["id"],
            "name": p["name"],
            "idCard": mask_id_card_str(p["id_card"]),
            "phone": mask_phone_str(p["phone"]),
            "email": p["email"] or "",
        })
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[患者档案] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.patch("/api/patients/mine")
def patient_mine_patch():
    """修改自己的档案：姓名 / 手机号 / 邮箱。身份证号作为身份标识不可改。"""
    try:
        # 以前只凭身份证号就能改别人的手机号 —— 现在必须带本人凭证
        pid, err = require_patient_by_id_card(request.args.get("idCard"))
        if err:
            return err

        body = body_json()
        name = str(body.get("name") or "").strip()
        phone = str(body.get("phone") or "").strip()
        email = body.get("email")
        if email is not None:
            email = str(email).strip()

        ok, msg, name = check_name(name)
        if not ok:
            return jsonify(error=msg), 400
        ok, msg, phone = check_phone(phone)
        if not ok:
            return jsonify(error=msg), 400
        ok, msg, email = check_email(email)
        if not ok:
            return jsonify(error=msg), 400

        upd = query(
            """UPDATE patients
                  SET name = %s, phone = %s, email = NULLIF(%s, ''), updated_at = NOW()
                WHERE id = %s
            RETURNING id""",
            [name, phone, email, pid],
        )
        if upd.rowcount == 0:
            return jsonify(error="未找到该就诊人的档案，请先挂一次号"), 404

        return jsonify(ok=True, name=name,
                       phone=mask_phone_str(phone), email=email or "")
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[患者档案更新] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/doctors")
def doctors():
    """全部医生（前端启动时一次性拉走缓存起来）。

    is_active = FALSE 的是已离职医生：档案留着（历史挂号单要能显示接诊医生），
    但不再出现在挂号页和下拉框里。
    """
    try:
        r = query("SELECT * FROM doctors WHERE is_active ORDER BY dept_id, id")
        return jsonify([map_doctor(x) for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[医生列表] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/doctors/<doctor_id>/schedules")
def doctor_schedules(doctor_id):
    """某位医生未来 N 天的排班（默认 7 天，最多 30 天）。"""
    try:
        try:
            days = int(float(request.args.get("days") or 0))
        except (TypeError, ValueError):
            days = 0
        days = max(1, min(days or 7, 30))

        r = query(
            """SELECT * FROM schedules
                WHERE doctor_id = %s
                  AND work_date >= CURRENT_DATE
                  AND work_date < CURRENT_DATE + %s::int
                ORDER BY work_date, time_slot""",
            [doctor_id, days],
        )
        return jsonify([map_schedule(x) for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[医生排班] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/schedules")
def schedules():
    """排班列表（管理端用）。可以按日期、科室筛。"""
    try:
        cond = []
        params = []

        if request.args.get("date"):
            params.append(request.args["date"])
            cond.append("work_date = %s::date")
        else:
            cond.append("work_date >= CURRENT_DATE")
        if request.args.get("deptId"):
            params.append(request.args["deptId"])
            cond.append("dept_id = %s")

        r = query(
            """SELECT * FROM schedules
                WHERE %s
                ORDER BY work_date, doctor_id, time_slot
                LIMIT 400""" % " AND ".join(cond),
            params,
        )
        return jsonify([map_schedule(x) for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[排班列表] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 五、挂号
# ============================================================

@app.post("/api/appointments")
def create_appointment():
    """挂号。

    号源怎么扣、号序怎么排，全部交给数据库的触发器（见 schema.sql 第 10 节）：
      · BEFORE INSERT 的 fn_appt_before_insert 先 SELECT ... FOR UPDATE 锁住排班行，
        检查「停诊 / 日期已过 / 号源已满 / 重复预约」，再分配 seq_no；
      · AFTER INSERT 的 fn_appt_after_insert 把 booked_count 加 1，并写一条审计日志。
    所以这里的 INSERT 里既没有 seq_no，也没有任何 UPDATE schedules ——
    应用层不再参与号源计数，否则会和触发器重复加一遍。

    ★ 防超卖靠的就是触发器里那把行锁：两个请求同时抢最后一个号，
      第二个会卡在 FOR UPDATE 上等第一个提交，拿到锁时读到的 booked_count
      已经是加过 1 的，于是「还有没有号」的判断永远基于最新数据。
      应用层不需要再写带条件的 UPDATE，也不需要重试。

    挂号费不由这段代码决定：INSERT 的 fee 那一列是一个子查询，
    就地取自 doctors 价目表。请求体里带什么价格都不参与运算；
    就算有人绕过接口手写 SQL，数据库还有 fk_appt_doctor_fee 这条外键兜底。
    """
    try:
        body = body_json()
        schedule_id = body.get("scheduleId")
        if not schedule_id:
            return jsonify(error="缺少排班参数"), 400

        ok, msg, patient = check_patient(body.get("patient"))
        if not ok:
            return jsonify(error=msg), 400

        # 邮箱是可选的：不填也能挂号，只是收不到提醒
        ok, msg, email = check_email((body.get("patient") or {}).get("email"))
        if not ok:
            return jsonify(error=msg), 400

        # ---- 验证码：只有「余号 ≤ 3」的抢手号源才要求 ----
        # 放在写库之前，避免「验证码没过却已经建了一条患者档案」。
        sc = query("SELECT max_quota - booked_count AS remain FROM schedules WHERE id = %s",
                   [schedule_id])
        if sc.rowcount == 0:
            return jsonify(error="排班不存在，请刷新后重试"), 404
        remain = int(sc.rows[0]["remain"])

        if guard.captcha_required(remain):
            if not guard.verify_captcha(body.get("captchaToken"), body.get("captchaAnswer")):
                return jsonify(
                    error="该时段仅剩 %d 个号，请先完成验证码" % remain,
                    code="CAPTCHA_REQUIRED",
                    remain=remain,
                ), 428

        patient_id, patient_token, notice, err = resolve_patient(patient, email)
        if err:
            return err

        # 医生和价格都从排班行上就地取：请求体里传的 doctorId / fee 一律不认。
        # 排班不存在时这条语句影响 0 行（触发器不会触发），直接回 404。
        appt_no = generate_appointment_no()
        ins = query(
            """INSERT INTO appointments
                     (id, appointment_no, seq_no, schedule_id, doctor_id, patient_id, fee, status)
               SELECT 'A' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS'),
                      %s, 0, s.id, s.doctor_id, %s, d.fee, 'booked'
                 FROM schedules s
                 JOIN doctors d ON d.id = s.doctor_id
                WHERE s.id = %s
               RETURNING id""",
            [appt_no, patient_id, schedule_id],
            operator=patient["name"],
        )
        if ins.rowcount == 0:
            return jsonify(error="排班不存在，请刷新后重试"), 404

        # 回显走视图，拿到的是「预约 + 患者 + 医生 + 科室 + 就诊时间」的完整一行
        detail = query(
            "SELECT * FROM v_appointment_detail WHERE id = %s",
            [ins.rows[0]["id"]],
        )
        result = map_appointment(detail.rows[0], False)
        if patient_token:
            result["patientToken"] = patient_token
        if notice:
            result["notice"] = notice
        return jsonify(result), 201
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[挂号] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ------------------------------------------------------------
# 患者身份验证：身份证号 → 向档案登记的手机/邮箱发码 → 换凭证
# ------------------------------------------------------------

@app.post("/api/patient-auth/request")
def patient_auth_request():
    try:
        id_card = str(body_json().get("idCard") or "").strip().upper()
        ok, msg, id_card = check_id_card(id_card)
        if not ok:
            return jsonify(error=msg), 400

        r = query("SELECT id, phone, email FROM patients WHERE id_card = %s", [id_card])
        if r.rowcount == 0:
            return jsonify(error="未找到该就诊人的档案，挂一次号即可自动建档"), 404
        p = r.rows[0]

        code = "".join(secrets.choice("0123456789") for _ in range(6))
        query(
            """INSERT INTO verification_codes (target, code_hash, purpose, expire_at)
               VALUES (%s, %s, 'patient', NOW() + INTERVAL '10 minutes')""",
            [p["id"], hashlib.sha256(code.encode()).hexdigest()],
        )
        # 码只发到档案里登记的联系方式，请求方自己填的一概不认
        if p["email"]:
            delivered = _send_verification_email(p["email"], code, "身份验证")
            sent_to = mask_email(p["email"])
        else:
            delivered = _mock_sms(p["phone"], code, "身份验证")
            sent_to = mask_phone_str(p["phone"])
        return code_response(sent_to, code, delivered)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[患者验证-发码] %s", err)
        return jsonify(error="发送失败，请稍后重试"), 500


@app.post("/api/patient-auth/verify")
def patient_auth_verify():
    try:
        body = body_json()
        id_card = str(body.get("idCard") or "").strip().upper()
        code = str(body.get("code") or "").strip()
        if not id_card or not code:
            return jsonify(error="请填写身份证号和验证码"), 400

        r = query("SELECT id FROM patients WHERE id_card = %s", [id_card])
        if r.rowcount == 0:
            return jsonify(error="验证码错误"), 400
        pid = r.rows[0]["id"]

        vc = query(
            """SELECT id, code_hash, expire_at, used, attempts
                 FROM verification_codes
                WHERE target = %s AND purpose = 'patient'
                ORDER BY created_at DESC LIMIT 1""",
            [pid],
        )
        if vc.rowcount == 0:
            return jsonify(error="请先获取验证码"), 400
        v = vc.rows[0]
        if v["used"] or v["expire_at"] <= datetime.now(timezone.utc):
            return jsonify(error="验证码已失效，请重新获取"), 400
        if v["attempts"] >= 5:
            return jsonify(error="验证次数过多，请重新获取"), 400

        query("UPDATE verification_codes SET attempts = attempts + 1 WHERE id = %s", [v["id"]])
        if v["code_hash"] != hashlib.sha256(code.encode()).hexdigest():
            return jsonify(error="验证码错误"), 400
        query("UPDATE verification_codes SET used = TRUE WHERE id = %s", [v["id"]])

        return jsonify(patientToken=issue_patient_token(pid), expireDays=PATIENT_TOKEN_DAYS)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[患者验证-校验] %s", err)
        return jsonify(error="验证失败，请稍后重试"), 500


# ------------------------------------------------------------
# 查询挂号（预约单号 + 验证码）
# ------------------------------------------------------------

@app.post("/api/appointments/lookup/request")
def lookup_request_code():
    """输入预约单号 + 姓名，系统向登记的手机/邮箱发验证码。"""
    try:
        body = body_json()
        appt_no = str(body.get("appointmentNo") or "").strip()
        patient_name = str(body.get("patientName") or "").strip()
        if not appt_no or not patient_name:
            return jsonify(error="请填写预约单号和姓名"), 400

        # 查找预约单
        apt = query(
            """SELECT a.id, a.status, a.appointment_no, p.name AS patient_name,
                      p.phone, p.email
                 FROM appointments a
                 JOIN patients p ON p.id = a.patient_id
                WHERE a.appointment_no = %s""",
            [appt_no],
        )
        if apt.rowcount == 0:
            return jsonify(error="未找到该预约单号"), 404
        row = apt.rows[0]
        if row["patient_name"] != patient_name:
            return jsonify(error="姓名与预约单不匹配"), 400
        if row["status"] != "booked":
            return jsonify(error="该预约已取消或已完成，无法查询"), 400

        # 生成 6 位数字验证码
        code = "".join(secrets.choice("0123456789") for _ in range(6))
        code_hash = hashlib.sha256(code.encode()).hexdigest()

        # 存验证码（10 分钟有效）
        query(
            """INSERT INTO verification_codes (target, code_hash, purpose, expire_at)
               VALUES (%s, %s, 'lookup', NOW() + INTERVAL '10 minutes')""",
            [row["phone"] or row["email"] or "", code_hash],
        )

        # 发送通知
        sent_to = ""
        delivered = False
        if row["email"]:
            delivered = _send_verification_email(row["email"], code, "查询预约单 " + row["appointment_no"])
            sent_to = mask_email(row["email"])
        elif row["phone"]:
            delivered = _mock_sms(row["phone"], code, "查询预约单 " + row["appointment_no"])
            sent_to = mask_phone_str(row["phone"])

        return code_response(sent_to, code, delivered)
    except Exception as err:
        app.logger.error("[查询挂号-请求验证码] %s", err)
        return jsonify(error="请求失败，请稍后重试"), 500


@app.post("/api/appointments/lookup/verify")
def lookup_verify_code():
    """验证验证码，返回预约详情。"""
    try:
        body = body_json()
        appt_no = str(body.get("appointmentNo") or "").strip()
        code = str(body.get("code") or "").strip()
        if not appt_no or not code:
            return jsonify(error="请填写预约单号和验证码"), 400

        # 查找预约单
        apt = query(
            """SELECT a.id, a.status, p.phone, p.email
                 FROM appointments a
                 JOIN patients p ON p.id = a.patient_id
                WHERE a.appointment_no = %s""",
            [appt_no],
        )
        if apt.rowcount == 0:
            return jsonify(error="未找到该预约单号"), 404
        row = apt.rows[0]
        if row["status"] != "booked":
            return jsonify(error="该预约已取消或已完成"), 400

        target = row["phone"] or row["email"] or ""
        code_hash = hashlib.sha256(code.encode()).hexdigest()

        # 查找最新未使用的验证码
        vc = query(
            """SELECT id, code_hash, expire_at, used, attempts
                 FROM verification_codes
                WHERE target = %s AND purpose = 'lookup'
                ORDER BY created_at DESC
                LIMIT 1""",
            [target],
        )
        if vc.rowcount == 0:
            return jsonify(error="验证码不存在，请重新请求"), 400

        v = vc.rows[0]
        if v["used"]:
            return jsonify(error="验证码已使用，请重新请求"), 400
        if v["expire_at"] <= datetime.now(timezone.utc):
            return jsonify(error="验证码已过期，请重新请求"), 400
        if v["attempts"] >= 5:
            return jsonify(error="验证次数过多，请重新请求"), 400

        # 增加尝试次数
        query(
            "UPDATE verification_codes SET attempts = attempts + 1 WHERE id = %s",
            [v["id"]],
        )

        if v["code_hash"] != code_hash:
            return jsonify(error="验证码错误"), 400

        # 标记已使用
        query("UPDATE verification_codes SET used = TRUE WHERE id = %s", [v["id"]])

        # 返回预约详情
        detail = query(
            "SELECT * FROM v_appointment_detail WHERE id = %s",
            [row["id"]],
        )
        return jsonify(map_appointment(detail.rows[0], False)), 200
    except Exception as err:
        app.logger.error("[查询挂号-验证] %s", err)
        return jsonify(error="验证失败，请稍后重试"), 500


@app.post("/api/appointments/lookup/cancel")
def lookup_cancel():
    """通过验证码取消预约。"""
    try:
        body = body_json()
        appt_no = str(body.get("appointmentNo") or "").strip()
        code = str(body.get("code") or "").strip()
        if not appt_no or not code:
            return jsonify(error="请填写预约单号和验证码"), 400

        apt = query(
            """SELECT a.id, a.status, p.phone, p.email
                 FROM appointments a
                 JOIN patients p ON p.id = a.patient_id
                WHERE a.appointment_no = %s""",
            [appt_no],
        )
        if apt.rowcount == 0:
            return jsonify(error="未找到该预约单号"), 404
        row = apt.rows[0]
        if row["status"] != "booked":
            return jsonify(error="该预约已取消或已完成"), 400

        target = row["phone"] or row["email"] or ""
        code_hash = hashlib.sha256(code.encode()).hexdigest()

        vc = query(
            """SELECT id, code_hash, expire_at, used, attempts
                 FROM verification_codes
                WHERE target = %s AND purpose = 'lookup'
                ORDER BY created_at DESC
                LIMIT 1""",
            [target],
        )
        if vc.rowcount == 0:
            return jsonify(error="验证码不存在"), 400
        v = vc.rows[0]
        if v["used"]:
            return jsonify(error="验证码已使用"), 400
        if v["expire_at"] <= datetime.now(timezone.utc):
            return jsonify(error="验证码已过期"), 400
        if v["attempts"] >= 5:
            return jsonify(error="验证次数过多"), 400

        query(
            "UPDATE verification_codes SET attempts = attempts + 1 WHERE id = %s",
            [v["id"]],
        )
        if v["code_hash"] != code_hash:
            return jsonify(error="验证码错误"), 400

        query("UPDATE verification_codes SET used = TRUE WHERE id = %s", [v["id"]])

        # 执行取消（和现有 cancel 逻辑一致）
        query(
            "UPDATE appointments SET status = 'cancelled', cancel_reason = 'patient' WHERE id = %s",
            [row["id"]],
            operator="患者自助查询取消",
        )
        return jsonify(ok=True), 200
    except Exception as err:
        app.logger.error("[查询挂号-取消] %s", err)
        return jsonify(error="取消失败，请稍后重试"), 500


def _send_verification_email(email, code, purpose):
    """验证码要立刻送达，不走 outbox 队列（那张表的模板约束里也没有验证码）。
    mailer 没配 SMTP 时自动 dry-run，写进 .mail-outbox.log。

    返回 True = 真的发出去了；False = 只是模拟（dry-run），用户收不到。"""
    import mailer
    try:
        mailer.send_mail(
            email, "【智慧医院】验证码",
            "您正在进行「%s」，验证码为 %s，10 分钟内有效。如非本人操作请忽略。" % (purpose, code),
        )
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[验证码邮件] %s", err)
    return mailer.CONFIG.ready


def _mock_sms(phone, code, purpose):
    """没有短信网关：模拟发送，写进 .mail-outbox.log，演示时打开即可看到。
    接入真实短信平台前永远返回 False（用户收不到）。"""
    import mailer
    try:
        with mailer.DRY_RUN_LOG.open("a", encoding="utf-8") as f:
            f.write("\n" + "=" * 64 + "\n")
            f.write("时间：%s\n【模拟短信】收件人：%s\n\n" % (
                datetime.now().strftime("%Y-%m-%d %H:%M:%S"), phone))
            f.write("【智慧医院】您正在进行「%s」，验证码 %s，10 分钟内有效。\n" % (purpose, code))
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[模拟短信] %s", err)
    return False


def code_response(sent_to, code, delivered):
    """发码接口的统一返回。

    ★ 演示模式：还没接短信平台 / 邮箱是 dry-run 时，验证码根本到不了用户手里，
      这时把验证码直接放在响应里（demoCode），前端显示并自动填好，
      否则谁都过不了验证。接上真实通道后 delivered 为 True，demoCode 自动消失。
      想在没接通道时也强制关掉，设环境变量 DEMO_CODE=0。"""
    body = {"sentTo": sent_to, "expireIn": 600}
    if not delivered and os.environ.get("DEMO_CODE", "1") != "0":
        body["demoCode"] = code
    return jsonify(body)


def mask_email(email):
    if "@" not in email:
        return email
    local, domain = email.split("@", 1)
    if len(local) <= 2:
        return "*@" + domain
    return local[0] + "***" + local[-1] + "@" + domain


@app.post("/api/appointments/<apt_id>/cancel")
def cancel_appointment(apt_id):
    """退号。

    应用层只做一件事：把单据改成 cancelled。
    号源 -1、取消时间、审计日志都由触发器完成
    （fn_appt_before_update 校验流转并写 cancelled_at，fn_appt_after_update 减号源）。

    ★ 不再重排后面人的号序：v2 有 uq_appt_schedule_seq（同一排班号序唯一），
      「3 号改成 2 号」会撞上还存在的 2 号。退掉的号就留成空号 ——
      真实医院本来也是这样，而且历史单据上的「第几号」不会再变。
    """
    try:
        # 带令牌就是管理端在退号，不带就是患者自己退。
        # 审计员是只读角色，不能退号；患者必须持有这张单子主人的凭证 ——
        # 以前不校验，任何人拿到单号就能把别人的号退掉。
        user = get_login_user()
        if user and user["role"] not in ("admin", "desk"):
            return jsonify(error="当前账号无权退号", code="FORBIDDEN"), 403

        apt_res = query(
            """SELECT a.id, a.status, a.seq_no, a.patient_id, s.work_date
                 FROM appointments a
                 JOIN schedules s ON s.id = a.schedule_id
                WHERE a.id = %s""",
            [apt_id],
        )
        if apt_res.rowcount == 0:
            return jsonify(error="挂号记录不存在"), 404

        apt = apt_res.rows[0]
        if not user and apt["patient_id"] not in request_patient_ids():
            return patient_auth_error()
        if apt["status"] != "booked":
            return jsonify(error="该挂号已取消，无需重复操作"), 409

        work_date = apt["work_date"]
        if isinstance(work_date, datetime):
            work_date = work_date.date()
        if work_date < date.today():
            return jsonify(error="就诊日期已过，无法取消"), 409

        # WHERE 里再带一次 status = 'booked'：万一这中间有别人先退了，
        # 这里会得到 rowcount = 0，不会重复触发号源归还。
        operator = user["username"] if user else None
        upd = query(
            """UPDATE appointments
                  SET status = 'cancelled',
                      cancel_reason = %s,
                      close_note = COALESCE(%s, close_note)
                WHERE id = %s AND status = 'booked'""",
            ["admin" if user else "patient",
             ("管理端退号（%s）" % operator) if user else None,
             apt_id],
            operator=operator,
        )
        if upd.rowcount == 0:
            return jsonify(error="该挂号已取消，无需重复操作"), 409

        return jsonify(ok=True)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[退号] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/appointments")
def list_appointments():
    """挂号记录列表。

    患者端（没登录）必须带 idCard，只返回他自己那几条；
    管理端带了有效令牌，可以跨就诊人筛选。
    """
    try:
        user = get_login_user()
        args = request.args

        cond = []
        params = []

        # 患者端：身份证号不是秘密，必须同时持有该就诊人的凭证
        if not user:
            _, err = require_patient_by_id_card(args.get("idCard"))
            if err:
                return err

        if args.get("idCard"):
            params.append(str(args["idCard"]).strip().upper())
            cond.append("id_card = %s")
        if args.get("status") and args["status"] != "all":
            # 兼容旧前端传的 active：库里现在的状态叫 booked
            st = "booked" if args["status"] == "active" else args["status"]
            params.append(st)
            cond.append("status = %s")
        if args.get("deptId"):
            params.append(args["deptId"])
            cond.append("dept_id = %s")
        if args.get("date"):
            params.append(args["date"])
            cond.append("work_date = %s::date")
        if args.get("keyword"):
            # 同一个关键词要在四个列上各用一次，所以占位符写四个、
            # 同一个值也传四遍（占位符是按位置对参数的，不能复用）
            kw = "%" + args["keyword"] + "%"
            params.extend([kw, kw, kw, kw])
            cond.append("(patient_name ILIKE %s OR phone ILIKE %s "
                        "OR id ILIKE %s OR id_card ILIKE %s)")

        where = ("WHERE " + " AND ".join(cond)) if cond else ""

        try:
            limit = int(float(args.get("limit") or 0))
        except (TypeError, ValueError):
            limit = 0
        limit = max(1, min(limit or 500, 2000))

        # 查视图：患者姓名 / 身份证 / 手机号在 patients 表，
        # 就诊日期 / 时段在 schedules 表，五表 JOIN 已经封装在视图里了。
        r = query(
            "SELECT * FROM v_appointment_detail %s "
            "ORDER BY created_at DESC, id DESC LIMIT %s" % (where, limit),
            params,
        )
        # ⑥ 权限控制：患者端与后台列表**默认都脱敏**。
        # 管理员也不能随手翻患者身份证和手机号 —— 想看明文必须点「查看完整信息」，
        # 走 reveal 接口并填理由，那一次访问会写进 access_log。
        return jsonify([map_appointment(row, True, True) for row in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[挂号列表] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/appointments/<apt_id>")
def get_appointment(apt_id):
    """单条挂号（管理端）。

    ?reveal=1&reason=xxx 才返回完整身份证与手机号，并且：
      · 只有 admin / auditor 能用（desk 窗口人员只能看脱敏）；
      · 必须填理由（至少 2 个字）；
      · 每一次都写一条 access_log —— 「谁在什么时候因为什么看了谁的隐私」。
    """
    try:
        user, err = require_role()
        if err:
            return err

        reveal = request.args.get("reveal") == "1"
        reason = (request.args.get("reason") or "").strip()

        if reveal and user["role"] not in ("admin", "auditor"):
            return jsonify(error="当前账号无权查看完整患者信息", code="FORBIDDEN"), 403
        if reveal and len(reason) < 2:
            return jsonify(error="查看完整信息必须填写理由", code="REASON_REQUIRED"), 400

        r = query("SELECT * FROM v_appointment_detail WHERE id = %s", [apt_id])
        if r.rowcount == 0:
            return jsonify(error="挂号记录不存在"), 404

        row = r.rows[0]
        if reveal:
            write_access_log(user, "reveal_idcard", "appointment", apt_id,
                             row["patient_id"], reason)
            return jsonify(map_appointment(row, False, False))
        return jsonify(map_appointment(row, True, True))
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[单条挂号] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/appointments/<apt_id>/logs")
def appointment_logs(apt_id):
    """一张挂号单的完整时间线（④ 挂号审计）。

    回答「这个号什么时候挂的、什么时候退的、谁操作的」：
      created_at / cancelled_at 来自 appointments 表，
      每一次状态变更来自 appointment_log（触发器写的，应用层改不了）。
    """
    try:
        user, err = require_role()
        if err:
            return err

        head = query(
            """SELECT a.id, a.status, a.created_at, a.updated_at, a.cancelled_at,
                      a.cancel_reason, a.close_note, p.id AS patient_id, p.name AS patient_name
                 FROM appointments a
                 JOIN patients p ON p.id = a.patient_id
                WHERE a.id = %s""",
            [apt_id],
        )
        if head.rowcount == 0:
            return jsonify(error="挂号记录不存在"), 404

        h = head.rows[0]
        logs = query(
            """SELECT id, action, old_status, new_status, operator, changed_at
                 FROM appointment_log
                WHERE appointment_id = %s
                ORDER BY changed_at, id""",
            [apt_id],
        ).rows

        write_access_log(user, "view_audit", "appointment", apt_id, h["patient_id"],
                         "查看挂号审计时间线")

        return jsonify(
            appointment={
                "id": h["id"],
                "status": h["status"],
                "patientName": h["patient_name"],
                "createdAt": as_iso(h["created_at"]),
                "updatedAt": as_iso(h["updated_at"]),
                "cancelledAt": as_iso(h["cancelled_at"]),
                "cancelReason": h["cancel_reason"],
                "closeNote": h["close_note"],
            },
            timeline=[{
                "action": x["action"],
                "oldStatus": x["old_status"],
                "newStatus": x["new_status"],
                "operator": x["operator"],
                "at": as_iso(x["changed_at"]),
            } for x in logs],
        )
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[挂号审计] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 六、管理端：调号源 / 停诊（都要登录）
# ============================================================

@app.patch("/api/schedules/<sid>/quota")
def update_quota(sid):
    """调整某半天排班的号源总量。

    一条 UPDATE 同时做「判断」和「写入」：
    WHERE 里带上 booked_count <= %s，改完天然满足 ck_schedule_booked_range，
    不会出现「总数被改成比已约数还小」的坏数据。
    数据库那边还有 fn_schedule_before_update 触发器再挡一次（P0001，中文提示），
    两条路径互为兜底。
    """
    try:
        user = get_login_user()
        if not user:
            return jsonify(error="未登录或登录已过期，请重新登录"), 401

        total = body_json().get("total")
        # JSON 里的 20 和 20.0 在 JS 里都是同一个数，这里也照此处理；
        # 但布尔值 True 在 Python 里是 int 的子类，要单独挡掉
        valid = (isinstance(total, (int, float)) and not isinstance(total, bool)
                 and float(total).is_integer() and total >= 1)
        if not valid:
            return jsonify(error="号源总数必须为正整数"), 400
        total = int(total)

        upd = query(
            "UPDATE schedules SET max_quota = %s "
            "WHERE id = %s AND booked_count <= %s RETURNING *",
            [total, sid, total],
            operator=user["username"],
        )
        if upd.rowcount == 0:
            cur = query("SELECT booked_count FROM schedules WHERE id = %s", [sid])
            if cur.rowcount == 0:
                return jsonify(error="排班不存在"), 404
            return jsonify(error="号源总数不能小于已预约数（%d）"
                           % cur.rows[0]["booked_count"]), 409
        return jsonify(map_schedule(upd.rows[0]))
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[调号源] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.post("/api/schedules/<sid>/toggle")
def toggle_schedule(sid):
    """停诊 / 恢复出诊。

    停诊时该排班下所有「待就诊」的挂号自动改成 cancelled，
    cancel_reason 记为 closure（接口再把它还原成前端认识的 closed）。
    号源不需要手工清零 —— 每改一张单子，fn_appt_after_update 就减一次，
    全部退完后 booked_count 自然回到 0。
    """
    try:
        user = get_login_user()
        if not user:
            return jsonify(error="未登录或登录已过期，请重新登录"), 401

        sc_res = query("SELECT * FROM schedules WHERE id = %s", [sid])
        if sc_res.rowcount == 0:
            return jsonify(error="排班不存在"), 404

        will_close = not sc_res.rows[0]["closed"]
        affected = 0

        if will_close:
            upd = query(
                """UPDATE appointments
                      SET status = 'cancelled',
                          cancel_reason = 'closure',
                          close_note = '医生停诊，系统自动退号'
                    WHERE schedule_id = %s AND status = 'booked'
                    RETURNING id""",
                [sid],
                operator=user["username"],
            )
            affected = upd.rowcount

        query("UPDATE schedules SET closed = %s WHERE id = %s",
              [will_close, sid], operator=user["username"])
        return jsonify(ok=True, closed=will_close, affected=affected)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[停诊] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 六之二、管理端：工作量报表（视图 v_doctor_workload）
# ============================================================

@app.get("/api/stats/doctors")
def stats_doctors():
    """按医生 / 日期统计预约、取消、完成、爽约（管理端）。

    数据全部来自视图 v_doctor_workload，接口只做过滤和类型转换 ——
    这也正是这个视图存在的理由：报表口径只有一份，
    以后再加导出 Excel、大屏，直接查视图就行，不用重写一遍聚合 SQL。

    参数：
        date=2026-10-28   只看某天（不传默认今天）
        date=all          看全部日期
        deptId=D01        只看某个科室
    """
    try:
        user = get_login_user()
        if not user:
            return jsonify(error="未登录或登录已过期，请重新登录"), 401

        args = request.args
        cond = []
        params = []

        if args.get("date") and args["date"] != "all":
            params.append(args["date"])
            cond.append("work_date = %s::date")
        elif not args.get("date"):
            cond.append("work_date = CURRENT_DATE")

        if args.get("deptId"):
            params.append(args["deptId"])
            cond.append("dept_id = %s")

        where = ("WHERE " + " AND ".join(cond)) if cond else ""
        r = query(
            "SELECT * FROM v_doctor_workload %s "
            "ORDER BY work_date DESC, doctor_id" % where,
            params,
        )

        out = []
        for x in r.rows:
            out.append({
                "doctorId": x["doctor_id"],
                "doctorName": x["doctor_name"],
                "deptId": x["dept_id"],
                "deptName": x["dept_name"],
                "date": as_date_str(x["work_date"]),
                "total": int(x["total_count"]),
                "booked": int(x["booked_count"]),
                "cancelled": int(x["cancelled_count"]),
                "completed": int(x["completed_count"]),
                "noShow": int(x["no_show_count"]),
                "revenue": as_float(x["revenue"]),
            })
        return jsonify(out)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[工作量报表] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 六之三、候补队列（① 候补与自动补位）
#
# 状态机：
#   waiting ──有人退号──▶ offered（保留 2 小时）──确认──▶ converted
#      │                     │
#      └──自己取消──▶ cancelled └──超时──▶ expired（自动顺延给下一位）
#
# 「谁来补位」不在这段代码里：退号的那一刻，schema_v3.sql 的
# trg_appt_promote_waitlist 已经把队首的人标成 offered 并写好通知了。
# 接口只负责「排队」「确认」「取消」这三个动作。
# ============================================================

def resolve_patient(patient, email, trusted=False):
    """按身份证找 / 建患者档案。挂号、候补、代约三条路径共用。

    返回 (patient_id, 新凭证或 None, 提示或 None, 错误响应或 None)。

    ★ 已有档案时，只有「带着这个就诊人的凭证」或「窗口人员代约（trusted）」
      才能改姓名 / 手机号 / 邮箱。以前这里是无条件 upsert ——
      知道别人身份证号的人挂一次号，就能把对方的手机号换成自己的，
      之后的验证码、提醒全发到他那里。
    """
    def find():
        return query("SELECT id, name, phone, email FROM patients WHERE id_card = %s",
                     [patient["idCard"]])

    r = find()
    if r.rowcount == 0:
        ins = query(
            """INSERT INTO patients (id, name, id_card, phone, email)
               VALUES ('P' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS'),
                       %s, %s, %s, %s)
               ON CONFLICT (id_card) DO NOTHING
               RETURNING id""",
            [patient["name"], patient["idCard"], patient["phone"], email],
        )
        if ins.rowcount == 1:
            pid = ins.rows[0]["id"]
            # 档案是这次请求建的，建档人就是本人：直接发凭证
            return pid, (None if trusted else issue_patient_token(pid)), None, None
        r = find()   # 并发下别人刚建好，按已有档案处理

    row = r.rows[0]
    if trusted or row["id"] in request_patient_ids():
        query(
            """UPDATE patients
                  SET name = %s, phone = %s,
                      email = COALESCE(%s, email), updated_at = NOW()
                WHERE id = %s""",
            [patient["name"], patient["phone"], email, row["id"]],
        )
        return row["id"], None, None, None

    if row["name"] != patient["name"]:
        # 不能直接拒绝：档案里的名字可能本来就填错了，本人要能改过来。
        # 回 PATIENT_AUTH_REQUIRED，前端会弹验证框；验证通过后带着凭证重发，
        # 就走上面「本人」分支，姓名随这次挂号一起更新。
        return None, None, None, (jsonify(
            error="姓名与该身份证号的档案不一致。如果是本人，请验证身份后更新档案",
            code="PATIENT_AUTH_REQUIRED"), 401)

    notice = None
    if row["phone"] != patient["phone"] or (email and email != row["email"]):
        notice = ("该就诊人已建档，就诊提醒仍发送到档案登记的联系方式（%s）。"
                  "如需修改，请在「我的资料」中验证身份后修改。" % mask_phone_str(row["phone"]))
    return row["id"], None, notice, None


def map_waitlist(r):
    """v_waitlist_detail 的一行 → 前端对象。"""
    return {
        "id": r["id"],
        "position": int(r["position"]),
        "status": r["status"],
        "scheduleId": r["schedule_id"],
        "deptId": r["dept_id"],
        "deptName": r["dept_name"],
        "doctorId": r["doctor_id"],
        "doctorName": r["doctor_name"],
        "doctorTitle": r["doctor_title"],
        "date": as_date_str(r["work_date"]),
        "weekday": r["weekday"],
        "period": r["time_slot"],
        "fee": as_float(r["fee"]),
        "remain": int(r["remain"]),
        "patientName": r["patient_name"],
        "idCard": r["id_card_masked"],
        "phone": mask_phone_str(r["phone"]),
        "hasEmail": bool(r["email"]),
        "createdAt": as_iso(r["created_at"]),
        "offeredAt": as_iso(r["offered_at"]),
        "offerExpiresAt": as_iso(r["offer_expires_at"]),
        "convertedAppointmentId": r["converted_appointment_id"],
    }


@app.get("/api/captcha")
def captcha():
    """放号验证码：一道算术题，答案只存服务端，5 分钟有效、一次一用。"""
    return jsonify(guard.issue_captcha())


@app.post("/api/waitlist")
def join_waitlist():
    """排候补。

    号源没满时数据库会直接拒绝（「还有 N 个号，请直接挂号」）——
    候补队列不该变成「慢一点再挂号」的通道。
    """
    try:
        body = body_json()
        schedule_id = body.get("scheduleId")
        if not schedule_id:
            return jsonify(error="缺少排班参数"), 400

        ok, msg, patient = check_patient(body.get("patient"))
        if not ok:
            return jsonify(error=msg), 400
        ok, msg, email = check_email((body.get("patient") or {}).get("email"))
        if not ok:
            return jsonify(error=msg), 400

        patient_id, patient_token, notice, err = resolve_patient(patient, email)
        if err:
            return err

        ins = query(
            """INSERT INTO waitlist (id, schedule_id, patient_id, position, status)
               VALUES ('W' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS'),
                       %s, %s, 0, 'waiting')
               RETURNING id""",
            [schedule_id, patient_id],
            operator=patient["name"],
        )

        row = query("SELECT * FROM v_waitlist_detail WHERE id = %s",
                    [ins.rows[0]["id"]]).rows[0]
        ahead = query(
            """SELECT COUNT(*)::int AS n FROM waitlist
                WHERE schedule_id = %s AND status IN ('waiting','offered')
                  AND position < %s""",
            [schedule_id, row["position"]],
        ).rows[0]["n"]

        extra = {}
        if patient_token:
            extra["patientToken"] = patient_token
        if notice:
            extra["notice"] = notice
        return jsonify(waitlist=map_waitlist(row), ahead=ahead,
                       message="已排入候补，前面还有 %d 人" % ahead, **extra), 201
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[候补] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/waitlist")
def list_waitlist():
    """两种查法：

        ?idCard=xxx          患者查自己的候补（默认只看还在排的）
        ?scheduleId=xxx      某个号源现在排了多少人（前端显示「已满 · 候补 3 人」）
    """
    try:
        args = request.args

        if args.get("scheduleId"):
            r = query(
                """SELECT status, COUNT(*)::int AS n
                     FROM waitlist
                    WHERE schedule_id = %s AND status IN ('waiting','offered')
                    GROUP BY status""",
                [args["scheduleId"]],
            )
            stat = {x["status"]: x["n"] for x in r.rows}
            return jsonify(waiting=stat.get("waiting", 0),
                           offered=stat.get("offered", 0),
                           total=stat.get("waiting", 0) + stat.get("offered", 0))

        pid, err = require_patient_by_id_card(args.get("idCard"))
        if err:
            return err

        r = query(
            """SELECT * FROM v_waitlist_detail
                WHERE patient_id = %s
                ORDER BY created_at DESC LIMIT 200""",
            [pid],
        )
        rows = [map_waitlist(x) for x in r.rows]
        if args.get("all") != "1":
            rows = [x for x in rows if x["status"] in ("waiting", "offered")]
        return jsonify(rows)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[候补查询] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.post("/api/waitlist/<wl_id>/cancel")
def cancel_waitlist(wl_id):
    """自己放弃候补（需本人凭证）。"""
    try:
        ids = request_patient_ids()
        if not ids:
            return patient_auth_error()
        upd = query(
            """UPDATE waitlist SET status = 'cancelled'
                WHERE id = %s AND status IN ('waiting','offered')
                  AND patient_id = ANY(%s)""",
            [wl_id, list(ids)],
        )
        if upd.rowcount == 0:
            return jsonify(error="该候补已失效，无需取消"), 409
        return jsonify(ok=True)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[取消候补] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.post("/api/waitlist/<wl_id>/confirm")
def confirm_waitlist(wl_id):
    """候补转正：把保留的号真正挂下来。

    只需要一条 INSERT —— 号序、号源 +1、审计日志、候补闭环
    （trg_appt_close_waitlist 把这条候补标成 converted）全在触发器里。
    """
    try:
        wl = query("SELECT * FROM v_waitlist_detail WHERE id = %s", [wl_id])
        if wl.rowcount == 0:
            return jsonify(error="候补记录不存在"), 404

        w = wl.rows[0]
        if w["patient_id"] not in request_patient_ids():
            return patient_auth_error()
        if w["status"] != "offered":
            return jsonify(error="该候补当前不可确认（状态：%s）" % w["status"]), 409

        exp = w["offer_expires_at"]
        if exp is not None:
            now = query("SELECT NOW() AS n").rows[0]["n"]
            if exp <= now:
                return jsonify(error="候补保留时间已过，号源已顺延给下一位"), 409

        appt_no = generate_appointment_no()
        ins = query(
            """INSERT INTO appointments
                     (id, appointment_no, seq_no, schedule_id, doctor_id, patient_id, fee, status)
               SELECT 'A' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS'),
                      %s, 0, s.id, s.doctor_id, %s, d.fee, 'booked'
                 FROM schedules s
                 JOIN doctors d ON d.id = s.doctor_id
                WHERE s.id = %s
               RETURNING id""",
            [appt_no, w["patient_id"], w["schedule_id"]],
            operator=w["patient_name"] + "（候补转正）",
        )
        if ins.rowcount == 0:
            return jsonify(error="排班不存在，请刷新后重试"), 404

        detail = query("SELECT * FROM v_appointment_detail WHERE id = %s",
                       [ins.rows[0]["id"]])
        return jsonify(map_appointment(detail.rows[0], False)), 201
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[候补转正] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/notifications")
def my_notifications():
    """患者的站内消息（候补通知、提醒都会落一条 inapp）。

    按身份证查，并且必须带该就诊人的凭证（X-Patient-Token）。
    """
    try:
        pid, err = require_patient_by_id_card(request.args.get("idCard"))
        if err:
            return err

        r = query(
            """SELECT o.id, o.template, o.subject, o.body, o.status, o.created_at, o.sent_at
                 FROM notification_outbox o
                WHERE o.channel = 'inapp' AND o.recipient = %s
                ORDER BY o.created_at DESC LIMIT 50""",
            [pid],
        )
        return jsonify([{
            "id": x["id"],
            "template": x["template"],
            "subject": x["subject"],
            "body": x["body"],
            "at": as_iso(x["created_at"]),
        } for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[站内消息] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 六之四、管理端：审计 / 权限 / 黑名单 / 通知队列
# ============================================================

@app.get("/api/admin/waitlist")
def admin_waitlist():
    """全量候补队列（管理端）。

    按 (排班, 序号) 排 —— 就是补位的真实顺序，方便窗口人员回答
    「我前面还有几个人」这类电话咨询。
    """
    try:
        user, err = require_role("admin", "auditor", "desk")
        if err:
            return err

        r = query(
            """SELECT * FROM v_waitlist_detail
                WHERE status IN ('waiting','offered')
                ORDER BY work_date, time_slot, schedule_id, position
                LIMIT 300"""
        )
        return jsonify([map_waitlist(x) for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[候补队列] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/admin/access-log")
def admin_access_log():
    """谁看过谁的隐私（⑥ 权限控制）。

    只有 admin 与 auditor 能看 —— 窗口人员看不到，
    否则「查看留痕」就变成了「互相监视」，反而没人敢用系统。
    """
    try:
        user, err = require_role("admin", "auditor")
        if err:
            return err

        r = query(
            """SELECT a.id, a.username, a.action, a.target_type, a.target_id,
                      a.reason, a.client_ip, a.created_at, p.name AS patient_name
                 FROM access_log a
                 LEFT JOIN patients p ON p.id = a.patient_id
                ORDER BY a.created_at DESC, a.id DESC
                LIMIT 200"""
        )
        return jsonify([{
            "id": x["id"],
            "username": x["username"],
            "action": x["action"],
            "targetType": x["target_type"],
            "targetId": x["target_id"],
            "patientName": x["patient_name"],
            "reason": x["reason"],
            "ip": x["client_ip"],
            "at": as_iso(x["created_at"]),
        } for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[访问日志] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/admin/outbox")
def admin_outbox():
    """通知发件箱：待发 / 已发 / 失败，一眼看到提醒有没有真的发出去。"""
    try:
        user, err = require_role("admin", "auditor")
        if err:
            return err

        r = query(
            """SELECT id, channel, template, recipient, subject, status,
                      attempts, scheduled_at, sent_at, last_error, created_at
                 FROM notification_outbox
                ORDER BY id DESC LIMIT 100"""
        )
        return jsonify([{
            "id": x["id"],
            "channel": x["channel"],
            "template": x["template"],
            "recipient": x["recipient"],
            "subject": x["subject"],
            "status": x["status"],
            "attempts": int(x["attempts"]),
            "scheduledAt": as_iso(x["scheduled_at"]),
            "sentAt": as_iso(x["sent_at"]),
            "lastError": x["last_error"],
        } for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[发件箱] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.post("/api/admin/notify/scan")
def admin_notify_scan():
    """手工触发一次「生成提醒 + 处理候补过期 + 发信」。

    平时由 python server/app.py --worker 每分钟自动跑；
    这个接口是给答辩演示用的 —— 点一下就能看到提醒进队列。
    """
    try:
        user, err = require_role("admin")
        if err:
            return err

        import reminder
        r = reminder.tick(ignore_window=True)
        return jsonify(
            remind={"%s/%s" % k: v for k, v in r["remind"].items()},
            expired=r["expire"]["expired"],
            reoffered=r["expire"]["reoffered"],
            mail=r["mail"],
        )
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[通知扫描] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.get("/api/admin/blacklist")
def admin_blacklist():
    try:
        user, err = require_role("admin", "auditor")
        if err:
            return err
        r = query(
            """SELECT b.id, b.id_card, b.reason, b.until, b.created_by, b.created_at,
                      p.name AS patient_name
                 FROM blacklist b
                 LEFT JOIN patients p ON p.id = b.patient_id
                ORDER BY b.created_at DESC LIMIT 200"""
        )
        return jsonify([{
            "id": x["id"],
            "idCard": mask_id_card_str(x["id_card"]),
            "patientName": x["patient_name"],
            "reason": x["reason"],
            "until": as_iso(x["until"]),
            "createdBy": x["created_by"],
            "at": as_iso(x["created_at"]),
        } for x in r.rows])
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[黑名单] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.post("/api/admin/blacklist")
def admin_blacklist_add():
    """拉黑：身份证 + 理由 + 截止时间（不填=永久）。

    黑名单检查在触发器 fn_appt_guard_before_insert 里，
    所以拉黑之后哪怕绕过接口手写 SQL 也挂不上号。
    """
    try:
        user, err = require_role("admin")
        if err:
            return err

        body = body_json()
        id_card = str(body.get("idCard") or "").strip().upper()
        reason = str(body.get("reason") or "").strip()
        until = body.get("until") or None

        ok, msg, id_card = check_id_card(id_card)
        if not ok:
            return jsonify(error=msg), 400
        if len(reason) < 2:
            return jsonify(error="请填写拉黑理由"), 400

        pid = query("SELECT id FROM patients WHERE id_card = %s", [id_card])
        patient_id = pid.rows[0]["id"] if pid.rowcount else None

        query(
            """INSERT INTO blacklist (id_card, patient_id, reason, until, created_by)
               VALUES (%s, %s, %s, %s::timestamptz, %s)
               ON CONFLICT (id_card) DO UPDATE
                  SET reason = EXCLUDED.reason,
                      until  = EXCLUDED.until,
                      created_by = EXCLUDED.created_by""",
            [id_card, patient_id, reason, until, user["username"]],
        )
        write_access_log(user, "blacklist", "patient", id_card, patient_id,
                         "加入黑名单：" + reason)
        return jsonify(ok=True)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[加黑名单] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.delete("/api/admin/blacklist/<id_card>")
def admin_blacklist_remove(id_card):
    try:
        user, err = require_role("admin")
        if err:
            return err
        r = query("DELETE FROM blacklist WHERE id_card = %s", [id_card.strip().upper()])
        return jsonify(ok=True, removed=r.rowcount)
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[解除黑名单] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


@app.post("/api/admin/proxy-booking")
def proxy_booking():
    """窗口代约（③ 适老化：电话 / 线下代约入口）。

    老人不会用手机，打服务台电话或到窗口，由工作人员代为挂号。
    代约和自助挂号走的是同一条 INSERT、同一套触发器 ——
    号源、防黄牛规则一样生效，唯一的区别是审计日志里的操作人
    记成「代约:工号」，事后能查清是谁帮谁挂的。
    """
    try:
        user, err = require_role("admin", "desk")
        if err:
            return err

        body = body_json()
        schedule_id = body.get("scheduleId")
        if not schedule_id:
            return jsonify(error="缺少排班参数"), 400

        ok, msg, patient = check_patient(body.get("patient"))
        if not ok:
            return jsonify(error=msg), 400
        ok, msg, email = check_email((body.get("patient") or {}).get("email"))
        if not ok:
            return jsonify(error=msg), 400

        # 代约也要过验证码这一关 —— 否则「窗口代约」就成了绕开限流的后门。
        # 窗口人员多算一道题，比让黄牛从这条路径批量占号划算。
        sc = query("SELECT max_quota - booked_count AS remain FROM schedules WHERE id = %s",
                   [schedule_id])
        if sc.rowcount == 0:
            return jsonify(error="排班不存在，请刷新后重试"), 404
        remain = int(sc.rows[0]["remain"])
        if guard.captcha_required(remain):
            if not guard.verify_captcha(body.get("captchaToken"), body.get("captchaAnswer")):
                return jsonify(
                    error="该时段仅剩 %d 个号，请先完成验证码" % remain,
                    code="CAPTCHA_REQUIRED",
                    remain=remain,
                ), 428

        # 窗口人员当面核验过证件，允许顺手更新联系方式
        patient_id, _, _, _ = resolve_patient(patient, email, trusted=True)

        appt_no = generate_appointment_no()
        ins = query(
            """INSERT INTO appointments
                     (id, appointment_no, seq_no, schedule_id, doctor_id, patient_id, fee, status)
               SELECT 'A' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS'),
                      %s, 0, s.id, s.doctor_id, %s, d.fee, 'booked'
                 FROM schedules s
                 JOIN doctors d ON d.id = s.doctor_id
                WHERE s.id = %s
               RETURNING id""",
            [appt_no, patient_id, schedule_id],
            operator="代约:" + user["username"],
        )
        if ins.rowcount == 0:
            return jsonify(error="排班不存在，请刷新后重试"), 404

        detail = query("SELECT * FROM v_appointment_detail WHERE id = %s",
                       [ins.rows[0]["id"]])
        return jsonify(map_appointment(detail.rows[0], False)), 201
    except Exception as err:                                  # noqa: BLE001
        app.logger.error("[代约] %s", err)
        status, msg = db_error(err)
        return jsonify(error=msg), status


# ============================================================
# 七、健康检查
# ============================================================

@app.get("/api/health")
def api_health():
    try:
        info = health_check()
        return jsonify(ok=True, database=info["db"], time=as_iso(info["now"]))
    except Exception as err:                                  # noqa: BLE001
        return jsonify(ok=False, error=str(err)), 503


# ============================================================
# 八、404 与兜底错误处理
# ============================================================

@app.errorhandler(404)
def not_found(err):
    """只拦 /api，静态文件照旧走 Flask 自己的 404。"""
    if request.path.startswith("/api"):
        # 旧版把路由挂在 /api 上，报错时打印的是「挂载点之后」的那一段路径，
        # 所以 /api/nonexistent 报的是 /nonexistent。这里跟着去掉前缀，
        # 免得提示语和以前不一样。
        sub = request.path[4:] or "/"
        return jsonify(error="接口不存在：%s %s" % (request.method, sub)), 404
    return err


@app.errorhandler(Exception)
def unhandled(err):
    """兜底：万一哪个接口漏了 try/except，错误会落到这里，不至于把进程带崩。"""
    if isinstance(err, HTTPException):
        return err
    app.logger.error("[未捕获的错误] %s", err)
    status, msg = db_error(err)
    return jsonify(error=msg), status


# ============================================================
# 九、启动
# ============================================================

def start_server():
    try:
        info = health_check()
        print("\n数据库连接正常：%s\n" % info["db"])
    except Exception as err:                                  # noqa: BLE001
        print("\n无法连接数据库：%s" % err)
        print("请检查 server/db.py 开头 DB_CONFIG 的地址、账号、密码，"
              "并确认 PostgreSQL 已启动。")
        print("如未初始化，请先运行：python server/app.py --init\n")
        sys.exit(1)

    print("智慧医院预约挂号系统已启动")
    print("  前端页面   http://%s:%d/" % (HOST if HOST != "0.0.0.0" else "127.0.0.1", PORT))
    print("  健康检查   http://%s:%d/api/health\n"
          % (HOST if HOST != "0.0.0.0" else "127.0.0.1", PORT))

    # threaded=True：并发处理请求。挂号防超卖靠的是那条原子 UPDATE，
    # 单线程跑反而测不出并发问题，所以这里必须开。
    app.run(host=HOST, port=PORT, threaded=True, debug=False, use_reloader=False)


def _arg_value(argv, name, default=None):
    """取 --xxx 后面跟的那个值；没写就返回 default。"""
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
            return argv[i + 1]
    return default


def main(argv):
    # 命令行参数：
    #   什么都不带              → 启动 Web 服务
    #   --init                  → 初始化数据库（幂等，会顺带补齐 v3 对象）
    #   --force                 → 删表重建（★ 会清空所有挂号）
    #   --migrate               → 只打 v3 增量补丁（不建表、不删数据）
    #   --worker                → 常驻定时任务：提醒 / 候补过期 / 发信
    #   --remind                → 只扫一次（带时间窗判断）
    #   --remind --force        → 只扫一次，忽略时间窗（演示用，会立刻生成提醒）
    #   --flush-mail            → 只把发件箱里到点的发出去
    #   --test-mail <地址>      → 发一封测试邮件验 SMTP 配置
    if "--force" in argv or "--init" in argv:
        # 只在初始化时才导入 init_db：平时启动服务不需要它，
        # 也就不会去读 schema.sql
        from init_db import init_database

        try:
            init_database(force="--force" in argv)
        except Exception as err:                              # noqa: BLE001
            print("\n初始化失败：%s" % err)
            code = getattr(err, "sqlstate", None)
            if code:
                print("错误码：%s" % code)
            pool.close_all()
            sys.exit(1)
        return

    if "--migrate" in argv:
        # 只跑 v3 增量脚本，不碰已有数据。给「库已经在跑、只想升级」的场景用。
        import migrate_v3

        try:
            code = migrate_v3.main()
        except Exception as err:                              # noqa: BLE001
            print("\n升级失败：%s" % err)
            code = 1
        pool.close_all()
        sys.exit(code)

    if "--worker" in argv:
        import reminder

        reminder.run_forever(int(_arg_value(argv, "--interval", "60")))
        return

    if "--remind" in argv:
        import reminder

        r = reminder.tick(ignore_window="--force" in argv)
        print("提醒入库：%s" % r["remind"])
        print("候补过期：%s" % r["expire"])
        print("发件箱  ：%s" % r["mail"])
        return

    if "--flush-mail" in argv:
        import mailer

        print("发信配置：%s" % mailer.CONFIG.describe())
        print("结果    ：%s" % mailer.flush(int(_arg_value(argv, "--limit", "50"))))
        return

    if "--test-mail" in argv:
        import mailer

        target = _arg_value(argv, "--test-mail") or mailer.CONFIG.sender
        print("发信配置：%s" % mailer.CONFIG.describe())
        mailer.send_test(target)
        return

    start_server()


if __name__ == "__main__":
    main(sys.argv[1:])
