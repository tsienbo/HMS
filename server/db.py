# -*- coding: utf-8 -*-
"""数据库访问层 —— 连接池、查询、错误翻译、行 → JSON 的转换。

这一层只做四件事，业务逻辑一概不碰：
  1. 开一个够用的连接池（默认 10 条）
  2. 提供一个 query(sql, params) 函数，用法和以前的 pg.Pool.query 一样
  3. 把 PostgreSQL 的约束错误翻译成中文提示
  4. 把数据库行（下划线列名、Decimal、date）转成前端要的形状

★ 为什么不用 ORM：本项目的 SQL 全部手写，因为要演示的就是 SQL 本身
  （约束、外键、原子 UPDATE 防超卖）。ORM 会把 SQL 藏起来，
  答辩时反而说不清数据库到底做了什么。
"""

import os
import queue
import threading
from datetime import date, datetime, timezone

import psycopg
from psycopg.rows import dict_row

# ------------------------------------------------------------
# 一、连接参数
# ------------------------------------------------------------

# 换一台电脑只改这四行
DB_CONFIG = {
    "host": "127.0.0.1",
    "port": 5432,
    "user": "postgres",
    "password": "123456",
}

# 库名。平时就是 hospital_registration。
# 只有跑测试/截图时才会用 PGDATABASE=临时库名 起第二个服务，
# 免得把自己的正式数据改坏；平时不带这个环境变量。
DB_NAME = os.environ.get("PGDATABASE") or "hospital_registration"

# 连接池上限。够这个项目用了。
POOL_SIZE = 10
# 池子空了的时候最多等多久（秒）——超过就当作数据库忙不过来
POOL_TIMEOUT = 5.0


class Result:
    """查询结果。字段名刻意和以前 Node 版一样，路由代码几乎能一一对应。

    rows     —— 结果行（dict 列表）
    rowcount —— SELECT 时是行数，INSERT/UPDATE 时是受影响行数
    """

    __slots__ = ("rows", "rowcount")

    def __init__(self, rows, rowcount):
        self.rows = rows
        self.rowcount = rowcount


class ConnectionPool:
    """一个很小的连接池。

    为什么自己写而不用 psycopg_pool：
      · 依赖能少一个是一个（这个项目跑在没网的教学机上也能起）；
      · 逻辑简单到可以直接讲清楚：拿不到空闲连接就新建，
        新建到上限就排队等，还回去时如果连接坏了就丢掉重开。
    """

    def __init__(self, size=POOL_SIZE, **kwargs):
        self._size = size
        self._kwargs = kwargs
        self._idle = queue.LifoQueue(maxsize=size)
        self._created = 0
        self._lock = threading.Lock()

    def _connect(self):
        # autocommit=True 是刻意的：Node 的 pg 每执行一条语句就是一个
        # 独立的隐式事务，这里保持一致，路由里就不用到处写 commit。
        # （需要多条语句原子执行的场合，SQL 里自己写 BEGIN/COMMIT。）
        return psycopg.connect(
            **self._kwargs,
            row_factory=dict_row,
            autocommit=True,
            connect_timeout=5,
        )

    def acquire(self, timeout=POOL_TIMEOUT):
        try:
            return self._idle.get_nowait()
        except queue.Empty:
            pass

        with self._lock:
            if self._created < self._size:
                self._created += 1
                try:
                    return self._connect()
                except Exception:
                    # 连不上就把名额退回去，不然池子会以为已经满了
                    self._created -= 1
                    raise

        # 池子满了，等别人还回来
        try:
            return self._idle.get(timeout=timeout)
        except queue.Empty:
            raise TimeoutError("数据库连接池已满，请稍后重试")

    def release(self, conn):
        if conn is None:
            return
        if conn.closed or conn.broken:
            with self._lock:
                self._created -= 1
            try:
                conn.close()
            except Exception:
                pass
            return
        try:
            self._idle.put_nowait(conn)
        except queue.Full:
            with self._lock:
                self._created -= 1
            conn.close()

    def close_all(self):
        while True:
            try:
                conn = self._idle.get_nowait()
            except queue.Empty:
                break
            try:
                conn.close()
            except Exception:
                pass
        with self._lock:
            self._created = 0


pool = ConnectionPool(size=POOL_SIZE, **DB_CONFIG, dbname=DB_NAME)


# ------------------------------------------------------------
# 二、查一次数据库
# ------------------------------------------------------------

def _run(conn, sql, params):
    """在一条连接上真正执行 SQL，把结果包成 Result。"""
    with conn.cursor() as cur:
        cur.execute(sql, params)
        if cur.description is not None:
            rows = cur.fetchall()
            return Result(rows, len(rows))
        return Result([], cur.rowcount)


def query(sql, params=None, operator=None):
    """执行一条 SQL，返回 Result。

    用法：
        r = query('SELECT * FROM doctors WHERE id = %s', ['DR01'])
        r.rows[0]['name']

    ★ 一定要用 %s 占位符传参数，不要把变量拼进 SQL 字符串。
      拼字符串会被 SQL 注入：用户把 idCard 填成  ' OR '1'='1  就能把整张表读走。
      用 %s 传参时，psycopg 会把参数单独送过去，数据库不会把它当成 SQL 代码。

    ★ operator 参数：传了它就把这条语句放进一个显式事务里，并先
      SET LOCAL app.operator = '当前操作人'。appointment_log 的触发器
      用 current_setting('app.operator') 读取它，于是审计日志里就有了「谁干的」。
      用 SET LOCAL 而不是 SET，是因为连接池会复用连接 —— SET LOCAL 只活到
      事务结束，不会把上一个人的身份漏给下一个请求。
    """
    conn = pool.acquire()
    try:
        if operator is None:
            return _run(conn, sql, params)

        # autocommit=True 的连接上也能开事务，psycopg 会自己补 BEGIN / COMMIT
        with conn.transaction():
            # 用 set_config(..., true) 而不是 SET LOCAL：SET 是 DDL 语法，
            # 参数占位符在那里不合法（会报 syntax error at or near "$1"）。
            # 第三个参数 true = 只在本事务内有效，和 SET LOCAL 等价。
            conn.execute("SELECT set_config('app.operator', %s, true)", [operator])
            return _run(conn, sql, params)
    finally:
        pool.release(conn)


def health_check():
    """启动时确认数据库连得上。"""
    r = query("SELECT NOW() AS now, current_database() AS db")
    return r.rows[0]


# ------------------------------------------------------------
# 三、约束错误 → 中文提示
# ------------------------------------------------------------

def db_error(err):
    """把数据库抛出的错误翻译成 (HTTP 状态码, 提示语)。

    SQLSTATE 是 PostgreSQL 的标准错误码，比匹配错误文本可靠得多：
      P0001 raise_exception      —— 触发器里主动 RAISE 的业务提示（中文，直接回给用户）
      23514 check_violation      —— CHECK 约束没过（号源超卖、价格档位不对…）
      23505 unique_violation     —— 唯一约束冲突
      23503 foreign_key_violation —— 外键指向的行不存在
      23502 not_null_violation   —— 必填字段为空

    ★ P0001 之所以原样透传：触发器里写的就是给人看的中文
      （「该时段号源已挂完」「您已预约该时段」），
      翻译一遍反而会把「为什么失败」这个信息丢掉。
      这也是把业务规则写进数据库的一个前提 —— 报错信息得自己写清楚。
    """
    code = getattr(err, "sqlstate", None)

    diag = getattr(err, "diag", None)
    primary = (getattr(diag, "message_primary", None) or "").strip() if diag else ""

    if code == "P0001" and primary:
        return 409, primary
    if code == "23514":
        return 409, "号源已满或数据不合法"
    if code == "23505":
        return 409, "数据重复，请勿重复提交"
    if code == "23503":
        return 400, "关联数据不存在"
    if code == "23502":
        return 400, "缺少必填字段"
    return 500, "服务器内部错误：" + str(err).splitlines()[0]


# ------------------------------------------------------------
# 四、数据库行 → 前端对象
#
# psycopg 把 NUMERIC 读成 Decimal、DATE 读成 date、TIMESTAMPTZ 读成
# 带时区的 datetime。这三种都不能直接 jsonify，所以统一在这里转。
# 转换只在这几个函数里做，改一处就够了。
# ------------------------------------------------------------

def as_float(v):
    """NUMERIC → 数字。

    ★ 整数值输出成 int，而不是 50.0。这不是吹毛求疵：
      JS 里所有数字都是双精度，JSON.stringify(50) 得到的是 50 而不是 50.0，
      旧版接口返回的就是 50。前端用 toFixed(2) 显示，两者结果一样，
      但抓包截图和报告里的 JSON 要保持一致，所以这里跟着旧版走。
      真的带小数（比如 50.5）时仍然是 float，不会被截断。
    """
    if v is None:
        return None
    f = float(v)
    return int(f) if f.is_integer() else f


def as_date_str(v):
    """DATE → 'YYYY-MM-DD'。

    直接给前端一个 date 对象，jsonify 会输出成 'Wed, 14 Oct 2026 00:00:00 GMT'，
    前端按字符串截前 10 位就会拿到 'Wed, 14 Oc' —— 必须自己转成字符串。
    """
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d")
    if isinstance(v, date):
        return v.isoformat()
    return str(v)[:10]


def as_iso(v):
    """TIMESTAMPTZ → ISO 8601 字符串，带毫秒和 Z。

    和以前 Node 版 Date.toISOString() 的输出逐字符一致：
        2026-10-14T09:32:50.865Z
    """
    if v is None:
        return None
    if not isinstance(v, datetime):
        return v
    if v.tzinfo is None:
        # 库里是 TIMESTAMPTZ，理论上不会走到这里；保险起见按 UTC 处理
        v = v.replace(tzinfo=timezone.utc)
    v = v.astimezone(timezone.utc)
    return "%s.%03dZ" % (v.strftime("%Y-%m-%dT%H:%M:%S"), v.microsecond // 1000)


def map_department(r):
    return {"id": r["id"], "name": r["name"],
            "desc": r["description"], "location": r.get("location") or ""}


def map_doctor(r):
    remain = r.get("remain")
    out = {
        "id": r["id"],
        "deptId": r["dept_id"],
        "name": r["name"],
        "title": r["title"],
        "fee": as_float(r["fee"]),
    }
    # remain 只有 /departments/<id>/doctors 会带上（用来显示「剩 N 号 / 已约满」）。
    # 没有这个字段时整条键都不输出 —— 旧版 JS 里它是 undefined，
    # JSON.stringify 会把这个键直接丢掉；这里用「不加键」保持一致，
    # 而不是输出 "remain": null。
    if remain is not None:
        out["remain"] = int(remain)
    return out


def map_schedule(r):
    """一条排班 = 某医生某天某个半天（上午/下午），号源量就挂在这一行上。

    库里叫 max_quota / booked_count / time_slot，接口仍然输出
    quotaTotal / quotaBooked / period —— 前端页面一行没改，
    改的只是数据库里的列名（v1 用的是 quota_total / quota_booked / period）。
    """
    total = int(r["max_quota"])
    booked = int(r["booked_count"])
    return {
        "id": r["id"],
        "doctorId": r["doctor_id"],
        "deptId": r["dept_id"],
        "date": as_date_str(r["work_date"]),
        "weekday": r["weekday"],
        "period": r["time_slot"],
        "closed": bool(r["closed"]),
        "room": r.get("room") or "",
        "quotaTotal": total,
        "quotaBooked": booked,
        "remain": max(0, total - booked),
    }


def mask_id_card_str(v):
    """身份证脱敏：保留前 6 位（地区码）与后 4 位，中间打星。"""
    v = v or ""
    return v[:6] + "********" + v[-4:] if len(v) >= 10 else v


def mask_phone_str(v):
    """手机号脱敏：保留前 3 位与后 4 位。"""
    v = v or ""
    return v[:3] + "****" + v[-4:] if len(v) >= 8 else v


def map_appointment(r, mask_id_card, mask_phone=False):
    """挂号单 → 前端对象。

    入参 r 来自视图 v_appointment_detail（预约 + 患者 + 医生 + 科室 + 就诊时间），
    所以这里的字段名是视图的列名，而不是 appointments 表的列名。

    mask_id_card / mask_phone：
        患者端自助查询时两个都打码；
        管理端列表默认也打码（⑥ 权限控制：管理员不能随手翻患者隐私），
        只有点「查看完整信息」并写明理由，才走 reveal 接口拿明文 —— 那次访问会写 access_log。
    """
    id_card = r.get("id_card") or ""
    phone = r.get("phone") or ""
    if mask_id_card:
        id_card = mask_id_card_str(id_card)
    if mask_phone:
        phone = mask_phone_str(phone)

    # 库里只有四个状态（booked / cancelled / completed / no_show），
    # 「已停诊」不是独立状态 —— 停诊退号本质也是取消，靠 cancel_reason 区分。
    # 这里把它还原成前端认识的 closed，页面上才能显示成「已停诊」而不是「已取消」。
    status = r["status"]
    if status == "cancelled" and r.get("cancel_reason") == "closure":
        status = "closed"

    return {
        "id": r["id"],
        "appointmentNo": r.get("appointment_no") or "",
        "seqNo": int(r["seq_no"]),
        "scheduleId": r["schedule_id"],
        "deptId": r["dept_id"],
        "deptName": r["dept_name"],
        "doctorId": r["doctor_id"],
        "doctorName": r["doctor_name"],
        "doctorTitle": r["doctor_title"],
        "location": r.get("location") or "",
        "room": r.get("room") or "",
        "date": as_date_str(r["work_date"]),
        "weekday": r["weekday"],
        "period": r["time_slot"],
        "patientName": r["patient_name"],
        "idCard": id_card,
        "phone": phone,
        # 前端据此决定要不要显示「查看完整信息」按钮
        "masked": bool(mask_id_card or mask_phone),
        "fee": as_float(r["fee"]),
        "status": status,
        "closeNote": r.get("close_note") or None,
        "createdAt": as_iso(r.get("created_at")),
        "cancelledAt": as_iso(r.get("cancelled_at")),
    }


__all__ = [
    "DB_CONFIG", "DB_NAME", "Result", "pool", "query", "health_check",
    "db_error", "as_float", "as_date_str", "as_iso",
    "mask_id_card_str", "mask_phone_str",
    "map_department", "map_doctor", "map_schedule", "map_appointment",
]
