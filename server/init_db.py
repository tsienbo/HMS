# -*- coding: utf-8 -*-
"""数据库初始化 —— 建库、建表、灌基础数据、铺排班、一致性自检。

三种用法（在 app.py 里按命令行参数调用）：
    python server/app.py --init     幂等：缺什么补什么，不动已有数据
    python server/app.py --force    删表重建（★ 会清空所有挂号记录）
"""

import time
from pathlib import Path

import psycopg
from psycopg import sql

from db import DB_CONFIG, DB_NAME, pool, query
from seed_data import DEPARTMENTS, DOCTORS, SEED_DAYS, USERS, build_schedules
from validators import hash_password

HERE = Path(__file__).resolve().parent
SCHEMA_FILE = HERE / "schema.sql"
SCHEMA_V3_FILE = HERE / "schema_v3.sql"
SCHEMA_INTL_FILE = HERE / "schema_intl.sql"        # v3.5 国际化：多证件、证件键 doc_key、实名校验
SCHEMA_DICT_FILE = HERE / "schema_dict.sql"        # 科室搜索词典（表 + 索引 + 搜索函数）
DICT_CSV = HERE / "data" / "dept_keywords.csv"      # 词典数据，由 tools/build_dept_keywords.py 生成

# v2 的核心表（顺序按依赖排）。缺任何一张都说明库是坏的 → 整份重建。
CORE_TABLES = ["departments", "doctors", "patients", "schedules",
               "appointments", "users", "user_sessions", "appointment_log"]

# v3 新增的四张表。缺它们只说明还没升级，**绝不能**因此重建整个库 ——
# 那是「加功能」不是「修坏库」，重建会把用户的挂号记录清掉。
V3_TABLES = ["waitlist", "notification_outbox", "access_log", "blacklist"]

# v3.x 陆续加的表（患者凭证、验证码、实名校验）与科室搜索词典 —— 只用于对象清单核对
OTHER_TABLES = ["patient_sessions", "verification_codes", "citizen_registry",
                "identity_verify_log", "dept_keywords", "doctor_fee_history"]

EXPECTED_TABLES = CORE_TABLES + V3_TABLES + OTHER_TABLES

# 视图 / 触发器 / 函数：少一个就说明 schema 没跑全
EXPECTED_VIEWS = ["v_available_schedules", "v_appointment_detail",
                  "v_doctor_workload", "v_appointment_public",
                  "v_waitlist_detail"]
EXPECTED_TRIGGERS = 21
# 14 个触发器函数 + fn_offer_next_waitlist + fn_verify_identity + fn_search_departments
# + 证件工具 5 个（fn_gb11643_ok / fn_doc_valid / fn_doc_key / fn_mask_doc / fn_norm_name）
# + 挂号费 2 个（fn_doctor_fee 定价规则 / fn_doctor_fee_history 价目历史触发器）
EXPECTED_FUNCTIONS = 24


# ------------------------------------------------------------
# 建库：连到 PostgreSQL 自带的 postgres 库上，才能 CREATE DATABASE
# ------------------------------------------------------------
def ensure_database():
    conn = psycopg.connect(**DB_CONFIG, dbname="postgres", autocommit=True)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", [DB_NAME])
            if cur.fetchone() is None:
                # 库名不能用占位符传（DDL 里标识符不能参数化），
                # 所以用 sql.Identifier 做转义，避免库名里带引号时拼坏
                cur.execute(sql.SQL("CREATE DATABASE {} ENCODING 'UTF8'").format(
                    sql.Identifier(DB_NAME)))
                print("  · 已创建数据库 %s" % DB_NAME)
            else:
                print("  · 数据库 %s 已存在" % DB_NAME)
    finally:
        conn.close()


# ------------------------------------------------------------
# 表结构
# ------------------------------------------------------------
def inspect_schema():
    """看看 v2 的核心表在不在。"""
    r = query(
        """SELECT tablename FROM pg_tables
            WHERE schemaname = 'public' AND tablename = ANY(%s::text[])""",
        [CORE_TABLES],
    )
    present = {x["tablename"] for x in r.rows}
    missing = [t for t in CORE_TABLES if t not in present]
    return {"missing": missing, "complete": not missing}


# 存业务数据的表：这些表里有行，--init 就绝不能走 DROP / TRUNCATE
BUSINESS_TABLES = ["patients", "appointments", "waitlist"]


def business_row_count():
    """业务表（就诊人 / 挂号 / 候补）里一共有多少行；表不存在按 0 算。"""
    r = query(
        """SELECT tablename FROM pg_tables
            WHERE schemaname = 'public' AND tablename = ANY(%s::text[])""",
        [BUSINESS_TABLES],
    )
    total = 0
    for t in (x["tablename"] for x in r.rows):
        # 表名来自上面的白名单，不是用户输入
        total += query("SELECT COUNT(*)::int AS n FROM %s" % t).rows[0]["n"]
    return total


def inspect_v3():
    """v3 的四张表在不在。不在只补 v3，不重建。"""
    r = query(
        """SELECT tablename FROM pg_tables
            WHERE schemaname = 'public' AND tablename = ANY(%s::text[])""",
        [V3_TABLES],
    )
    present = {x["tablename"] for x in r.rows}
    missing = [t for t in V3_TABLES if t not in present]
    return {"missing": missing, "complete": not missing}


def drop_v3_tables():
    """--force 时先清掉 v3 的四张表。

    ★ 为什么必须显式删：schema.sql 里只有 v2 那 8 张表的 DROP TABLE ... CASCADE，
      而 waitlist / notification_outbox 是通过外键指向 schedules、appointments 的。
      删父表时 CASCADE 只带走外键约束，**子表本身会留下来**，
      于是重建之后库里躺着一批指向「上一世」患者和排班的孤儿候补 ——
      下次退号触发补位就会撞上外键报错。这是实测踩出来的坑。

    顺序：先删引用别人的（outbox → waitlist），再删独立的。
    """
    query("""
        DROP TABLE IF EXISTS dept_keywords       CASCADE;
        DROP TABLE IF EXISTS doctor_fee_history  CASCADE;
        DROP TABLE IF EXISTS patient_sessions    CASCADE;
        DROP TABLE IF EXISTS notification_outbox CASCADE;
        DROP TABLE IF EXISTS waitlist            CASCADE;
        DROP TABLE IF EXISTS access_log          CASCADE;
        DROP TABLE IF EXISTS blacklist           CASCADE;
    """)


def run_schema():
    """建表：schema.sql 一次性发过去。

    PostgreSQL 对「一次查询里的多条语句」按一个隐式事务处理，
    所以要么全建成、要么全回滚。
    """
    text = SCHEMA_FILE.read_text(encoding="utf-8")
    query(text)
    print("  · 表结构已创建（8 张表 + 约束 + 索引 + 4 视图 + 9 函数 + 14 触发器）")


def run_schema_v3():
    """叠加 v3 增量结构（幂等，不删任何已有对象）。"""
    text = SCHEMA_V3_FILE.read_text(encoding="utf-8")
    query(text)
    print("  · v3 增量结构已叠加 / 更新（候补 / 发件箱 / 访问日志 / 黑名单 + 触发器函数）")


def inspect_objects():
    """数一数库里到底有哪些对象 —— 答辩时这几个数字要能对得上。"""
    r = query("""
        SELECT
          (SELECT count(*) FROM pg_tables
            WHERE schemaname = 'public')::int AS tables,
          (SELECT count(*) FROM pg_views
            WHERE schemaname = 'public')::int AS views,
          (SELECT count(*) FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public')::int AS functions,
          (SELECT count(*) FROM pg_trigger t
             JOIN pg_class c ON c.oid = t.tgrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND NOT t.tgisinternal)::int AS triggers,
          (SELECT count(*) FROM pg_constraint c
             JOIN pg_namespace n ON n.oid = c.connamespace
            WHERE n.nspname = 'public')::int AS constraints,
          (SELECT count(*) FROM pg_indexes
            WHERE schemaname = 'public')::int AS indexes
    """).rows[0]

    view_names = {x["viewname"] for x in query(
        "SELECT viewname FROM pg_views WHERE schemaname = 'public'").rows}

    ok = (r["tables"] == len(EXPECTED_TABLES)
          and all(v in view_names for v in EXPECTED_VIEWS)
          and r["triggers"] == EXPECTED_TRIGGERS
          and r["functions"] == EXPECTED_FUNCTIONS)

    return {"ok": ok, **r}


# ------------------------------------------------------------
# 基础数据
# ------------------------------------------------------------
def seed_reference_data():
    """灌基础数据。CASCADE 会连带清掉排班与挂号 —— 只有基础数据为空时才会走到这里。"""
    query("TRUNCATE departments, doctors, users RESTART IDENTITY CASCADE")

    for d in DEPARTMENTS:
        query(
            "INSERT INTO departments (id, name, description, location, sex_limit) VALUES (%s, %s, %s, %s, %s)",
            [d["id"], d["name"], d["description"], d.get("location") or "", d.get("sexLimit")],
        )
    for d in DOCTORS:
        query(
            "INSERT INTO doctors (id, dept_id, name, title, fee) VALUES (%s, %s, %s, %s, %s)",
            [d["id"], d["deptId"], d["name"], d["title"], d["fee"]],
        )
    # 明文口令在这里派生成散列后写库
    for u in USERS:
        query(
            """INSERT INTO users (id, username, password_hash, display_name, status)
               VALUES (%s, %s, %s, %s, 'active')""",
            [u["id"], u["username"], hash_password(u["password"]), u["displayName"]],
        )

    print("  · 基础数据：科室 %d / 医生 %d / 后台账号 %d"
          % (len(DEPARTMENTS), len(DOCTORS), len(USERS)))
    for u in USERS:
        print("      管理员  %s / %s（%s）" % (u["username"], u["password"], u["displayName"]))


def add_missing_reference_data():
    """已有库里补上 seed_data 新增的科室与医生（按编号判重，不改动已有的行）。

    基础数据不为空时 seed_reference_data 不会再跑，新增的科室要靠这里补进去；
    新医生的排班由随后的 ensure_schedules 补齐。
    """
    nd = nr = 0
    for d in DEPARTMENTS:
        nd += query(
            """INSERT INTO departments (id, name, description, location, sex_limit) VALUES (%s, %s, %s, %s, %s)
               ON CONFLICT (id) DO NOTHING""",
            [d["id"], d["name"], d["description"], d.get("location") or "", d.get("sexLimit")],
        ).rowcount
    for d in DOCTORS:
        nr += query(
            """INSERT INTO doctors (id, dept_id, name, title, fee) VALUES (%s, %s, %s, %s, %s)
               ON CONFLICT (id) DO NOTHING""",
            [d["id"], d["deptId"], d["name"], d["title"], d["fee"]],
        ).rowcount
    nu = 0
    for u in USERS:
        nu += query(
            """INSERT INTO users (id, username, password_hash, display_name, status)
               VALUES (%s, %s, %s, %s, 'active')
               ON CONFLICT DO NOTHING""",
            [u["id"], u["username"], hash_password(u["password"]), u["displayName"]],
        ).rowcount
    if nd or nr or nu:
        print("  · 补充基础数据：新增科室 %d / 医生 %d / 后台账号 %d" % (nd, nr, nu))


# ------------------------------------------------------------
# 科室搜索词典
# ------------------------------------------------------------
def run_schema_intl():
    """v3.5 国际化（幂等）：证件类型、证件键、国际手机号、实名校验函数、脱敏视图。"""
    query(SCHEMA_INTL_FILE.read_text(encoding="utf-8"))


def run_schema_dict():
    """建词典表、索引与搜索函数（幂等）。"""
    query(SCHEMA_DICT_FILE.read_text(encoding="utf-8"))


def ensure_dept_keywords():
    """把词典 CSV 导入 dept_keywords（表结构由 run_schema_dict 建好）。

    表为空，或条数与 CSV 不一致（重新生成过词典），就整表替换；一致则跳过。
    放在基础数据之后：词典里的 dept_id 外键引用 departments。
    灌基础数据时 TRUNCATE departments ... CASCADE 会连带清空词典，这里会重新导入。
    """
    if not DICT_CSV.exists():
        print("  [!!] 缺少词典文件 %s，科室搜索只能按科室名匹配" % DICT_CSV)
        return
    with open(DICT_CSV, encoding="utf-8") as f:
        want = sum(1 for _ in f) - 1                     # 去掉表头
    n = query("SELECT COUNT(*)::int AS n FROM dept_keywords").rows[0]["n"]
    if n == want:
        print("  · 科室搜索词典已就绪（%d 条）" % n)
        return
    with psycopg.connect(dbname=DB_NAME, **DB_CONFIG) as conn:
        # 删旧数据与导入放在同一个事务里：导入失败就回滚，词典不会变空
        with conn.cursor() as cur, open(DICT_CSV, encoding="utf-8") as f:
            cur.execute("DELETE FROM dept_keywords")
            with cur.copy("COPY dept_keywords (term, kind, dept_id, other_dept, weight, pinyin, abbr) "
                          "FROM STDIN WITH (FORMAT csv, HEADER true, NULL '')") as cp:
                while chunk := f.read(1 << 16):
                    cp.write(chunk)
    n = query("SELECT COUNT(*)::int AS n FROM dept_keywords").rows[0]["n"]
    print("  · 科室搜索词典导入 %d 条（疾病 / 症状 / 科室名 → 科室）" % n)


# ------------------------------------------------------------
# 排班
# ------------------------------------------------------------
def ensure_schedules(days=SEED_DAYS):
    """铺排班。

    排班编号 SC_医生_日期_AM|PM 本身就是唯一的，
    已经存在的直接跳过，绝不覆盖已有的号源和挂号。
    """
    items = build_schedules(days)
    if not items:
        return 0

    dates = sorted({s["date"] for s in items})
    exist_res = query(
        "SELECT id FROM schedules WHERE work_date = ANY(%s::date[])", [dates]
    )
    exist = {r["id"] for r in exist_res.rows}

    n = 0
    for sc in items:
        if sc["id"] in exist:
            continue
        inserted = query(
            """INSERT INTO schedules
                 (id, doctor_id, dept_id, work_date, weekday, time_slot,
                  start_time, end_time, room, max_quota, booked_count, closed)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 0, FALSE)
               ON CONFLICT DO NOTHING""",
            [sc["id"], sc["doctorId"], sc["deptId"], sc["date"],
             sc["weekday"], sc["timeSlot"], sc["startTime"], sc["endTime"],
             sc["room"], sc["maxQuota"]],
        )
        n += inserted.rowcount
    return n


# ------------------------------------------------------------
# 一致性自检
# ------------------------------------------------------------
def verify_consistency():
    """所有排班的已约号源之和，应当等于「待就诊」的挂号数。

    对不上就说明号源和挂号记录脱节了（触发器没生效、有人手工改过库…）。
    """
    a = query("""
        SELECT (SELECT COALESCE(SUM(booked_count), 0) FROM schedules)::int AS booked,
               (SELECT COUNT(*) FROM appointments WHERE status = 'booked')::int AS active
    """)
    row = a.rows[0]

    bad = query("""
        SELECT s.id, s.time_slot, s.booked_count,
               (SELECT COUNT(*) FROM appointments a
                 WHERE a.schedule_id = s.id AND a.status = 'booked') AS actual
          FROM schedules s
         WHERE s.booked_count <> (SELECT COUNT(*) FROM appointments a
                                   WHERE a.schedule_id = s.id AND a.status = 'booked')
         LIMIT 20
    """)

    return {
        "ok": row["booked"] == row["active"] and bad.rowcount == 0,
        "booked": row["booked"],
        "active": row["active"],
        "bad": bad.rows,
    }


# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
def init_database(force=False):
    """force=True 表示删表重建（会清空所有挂号）。"""
    t0 = time.time()

    print("\n初始化数据库...\n")
    ensure_database()

    # --- 表结构 ---
    schema = inspect_schema()
    if force:
        print("  · --force：删除并重建所有表")
        drop_v3_tables()
        run_schema()
        run_schema_v3()
    elif schema["complete"]:
        print("  · 表结构完整，跳过重建（如需清空重建请用 --force）")
    else:
        # ★ 只有业务表里一行数据都没有时才允许自动重建（全新空库 / 建了一半失败的库）。
        #   有数据就停下来：schema.sql 里是 DROP TABLE ... CASCADE，缺一张 user_sessions
        #   也会把就诊人和挂号一起删掉。要重建必须由人显式加 --force。
        rows = business_row_count()
        if rows:
            raise RuntimeError(
                "表结构不完整（缺失：%s），但就诊人 / 挂号 / 候补表里还有 %d 行数据。\n"
                "为避免清空数据，没有自动重建。请先用 pg_dump 备份，再二选一：\n"
                "  · 按 server/schema.sql 里对应的 CREATE TABLE 手工补建缺失的表，再重新 --init\n"
                "  · 确认可以清空：python server/app.py --force 整库重建，之后用备份恢复数据"
                % (", ".join(schema["missing"]), rows))
        print("  · 表结构不完整，缺失：%s，且库里没有业务数据 → 重建" % ", ".join(schema["missing"]))
        # 重建核心表时 v3 的表也会变成孤儿（外键指向新建的同名表），一起清掉
        drop_v3_tables()
        run_schema()
        run_schema_v3()

    # --- v3 增量（只补缺，不重建）---
    if not force:
        # schema_v3.sql 是幂等的（IF NOT EXISTS / CREATE OR REPLACE），每次都重跑：
        # 触发器函数修了 bug，已有库 --init 一下就能用上新版本，不用等「缺表」才升级
        v3 = inspect_v3()
        if not v3["complete"]:
            print("  · v3 结构缺失：%s → 叠加增量" % ", ".join(v3["missing"]))
        run_schema_v3()

    # --- v3.5 国际化与科室搜索词典的表结构（幂等，每次都跑）---
    run_schema_intl()
    run_schema_dict()

    # --- 对象清单（视图 / 函数 / 触发器有没有建全）---
    obj = inspect_objects()
    print("  · 对象清单：表 %d / 视图 %d / 函数 %d / 触发器 %d / 约束 %d / 索引 %d"
          % (obj["tables"], obj["views"], obj["functions"],
             obj["triggers"], obj["constraints"], obj["indexes"]))
    if not obj["ok"]:
        print("  [!!] 对象清单与 schema.sql 不一致（预期 表 %d / 视图 %d / 函数 %d / 触发器 %d）"
              % (len(EXPECTED_TABLES), len(EXPECTED_VIEWS),
                 EXPECTED_FUNCTIONS, EXPECTED_TRIGGERS))

    # --- 基础数据 ---
    ref = query("""
        SELECT (SELECT COUNT(*) FROM departments)::int AS departments,
               (SELECT COUNT(*) FROM doctors)::int     AS doctors,
               (SELECT COUNT(*) FROM users)::int       AS users
    """).rows[0]
    ref_empty = not (ref["departments"] and ref["doctors"] and ref["users"])
    # 基础数据缺了但已经有挂号：seed_reference_data 的 TRUNCATE ... CASCADE 会连带清掉排班与挂号，
    # 这种情况只按编号补缺（INSERT ... ON CONFLICT DO NOTHING），不清空
    if ref_empty and not force and business_row_count():
        print("  · 基础数据不完整（科室 %d / 医生 %d / 账号 %d），但已有业务数据 → 只补缺，不清空"
              % (ref["departments"], ref["doctors"], ref["users"]))
        add_missing_reference_data()
    elif force or ref_empty:
        if force and not ref_empty:
            print("  · --force：清空基础数据后重新灌入")
        if ref_empty and not force:
            print("  · 基础数据不完整（科室 %d / 医生 %d / 账号 %d）→ 重新灌入"
                  % (ref["departments"], ref["doctors"], ref["users"]))
        seed_reference_data()
    else:
        print("  · 基础数据完整（科室 %d / 医生 %d / 账号 %d），跳过灌入"
              % (ref["departments"], ref["doctors"], ref["users"]))
        add_missing_reference_data()

    # --- 科室搜索词典 ---
    ensure_dept_keywords()

    # --- 排班与号源 ---
    # 每次都补：ensure_schedules 按「医生 + 日期 + 时段」拼出的固定编号判重，
    # 已存在的直接跳过，不会覆盖已有的号源和挂号。
    # 这样隔几天再打开系统，--init 一下就能把未来 14 天补齐 ——
    # 否则排班一旦过期，挂号页就整个空了。
    print("\n生成排班与号源...")
    n = ensure_schedules(SEED_DAYS)
    if n:
        print("  · 新增排班 %d 条（已约数从 0 开始）" % n)
    else:
        print("  · 未来 %d 天的排班已齐，无需新增" % SEED_DAYS)

    # --- 一致性自检（每次都跑）---
    ck = verify_consistency()
    if ck["ok"]:
        print("  · 号源一致性校验通过（booked 合计 %d = active 挂号 %d）"
              % (ck["booked"], ck["active"]))
    else:
        print("  [!!] 号源一致性校验失败！")
        print("    booked 合计 %d vs active 挂号 %d" % (ck["booked"], ck["active"]))
        for m in ck["bad"]:
            print("      %s（%s）: booked_count=%d 实际=%d"
                  % (m["id"], m["time_slot"], m["booked_count"], m["actual"]))

    days = query(
        "SELECT MIN(work_date) AS a, MAX(work_date) AS b FROM schedules"
    ).rows[0]
    if days["a"]:
        print("  · 可预约日期范围：%s ~ %s"
              % (days["a"].isoformat(), days["b"].isoformat()))

    print("\n完成，耗时 %.1fs\n" % (time.time() - t0))
    pool.close_all()
