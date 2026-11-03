# -*- coding: utf-8 -*-
"""生成 数据库脚本.sql：假设从零开始，执行这一个文件就得到与系统运行库完全一致的数据库。

脚本描述的是数据库「现在的样子」，不是升级过程：每张表的全部列和约束都写在它自己的
CREATE TABLE 里，没有事后的 ALTER TABLE；对象的定义从正在运行的库（server/db.py 配置的库）
读出来，约束旁边的说明取自 数据库对象.md。

结构：建库 → 扩展与建表要用的函数 → 表（按外键依赖排序）→ 视图 → 函数 → 触发器 → 基础数据 → 检查
用法（在 HMS 目录）：.venv\\Scripts\\python.exe tools\\build_db_script.py
表结构改了以后重新运行即可；生成后可以用 --verify 在临时库里执行一遍并与运行库逐项比对。
"""
import datetime
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "server"))
import psycopg  # noqa: E402
import db as hmsdb  # noqa: E402
from seed_data import DEPARTMENTS, DOCTORS, PERIODS, QUOTA_BY_TITLE, SEED_DAYS, USERS  # noqa: E402
from validators import hash_password  # noqa: E402

OUT = os.path.join(ROOT, "数据库脚本.sql")
DOC = os.path.join(ROOT, "数据库对象.md")
DB = hmsdb.DB_NAME
CFG = hmsdb.DB_CONFIG
PSQL = r"C:/Program Files/PostgreSQL/18/bin/psql.exe"

# 建表时就要用到的函数（CHECK 约束、生成列、视图里调用），必须先于表创建
HELPER_FUNCS = ["fn_gb11643_ok", "fn_doc_valid", "fn_doc_key", "fn_norm_name", "fn_mask_doc", "fn_doctor_fee"]

LIT_RE = r"'(?:[^']|'')*'"      # SQL 字符串字面量

TYPE_MAP = [("character varying", "VARCHAR"), ("timestamp with time zone", "TIMESTAMPTZ"),
            ("time without time zone", "TIME"), ("character(", "CHAR("), ("integer", "INTEGER"),
            ("bigint", "BIGINT"), ("numeric", "NUMERIC"), ("boolean", "BOOLEAN"), ("text", "TEXT"), ("date", "DATE")]


def connect(dbname):
    return psycopg.connect(dbname=dbname, autocommit=True, **CFG)


def nice_type(t):
    for a, b in TYPE_MAP:
        if t.startswith(a):
            return b + t[len(a):]
    return t.upper()


def tidy(expr):
    """把 pg_get_constraintdef 输出里机器味很重的写法还原成手写的样子（--verify 会确认语义不变）"""
    s = expr
    lit = r"'(?:[^']|'')*'"
    # (col)::text = ANY ((ARRAY['a'::character varying, ...])::text[])  →  col IN ('a', ...)
    def in_list(m, neg=False):
        items = re.findall(lit, m.group(2))
        return f"{m.group(1)} {'NOT IN' if neg else 'IN'} ({', '.join(items)})"
    s = re.sub(r"\(\((\w+)\)::text = ANY \(\(ARRAY\[(.*?)\]\)::text\[\]\)\)", lambda m: "(" + in_list(m) + ")", s)
    s = re.sub(r"\(\((\w+)\)::text <> ALL \(\(ARRAY\[(.*?)\]\)::text\[\]\)\)", lambda m: "(" + in_list(m, True) + ")", s)
    s = re.sub(r"\((\w+) = ANY \(ARRAY\[(.*?)\]\)\)", lambda m: "(" + in_list(m) + ")", s)
    s = re.sub(r"\((\w+)\)::text", r"\1", s)
    s = re.sub(r"(" + lit + r")::(?:text|character varying|bpchar)", r"\1", s)
    s = re.sub(r"\((\d+(?:\.\d+)?)\)::numeric", r"\1", s)
    s = s.replace("public.", "")
    # CHECK ((表达式)) 多了一层括号
    m = re.fullmatch(r"CHECK \(\((.*)\)\)", s, re.S)
    if m and balanced(m.group(1)):
        s = f"CHECK ({m.group(1)})"
    return s


def balanced(expr):
    """去掉外层括号前确认里面的括号是配对的（避免把 (a) OR (b) 错拆成 a) OR (b）"""
    depth = 0
    for ch in expr:
        depth += {"(": 1, ")": -1}.get(ch, 0)
        if depth < 0:
            return False
    return depth == 0


def doc_notes():
    """从 数据库对象.md 取表说明、列说明、约束作用"""
    txt = open(DOC, encoding="utf-8").read().replace("\r\n", "\n")
    tables, cols, cons = {}, {}, {}
    for m in re.finditer(r"^#### `(\w+)` —— (.+)$", txt, re.M):
        tables.setdefault(m.group(1), m.group(2).strip())
    # 列说明：第一~五节里每个表标题下的「| 列 | 类型 | 说明 |」
    head = txt.split("## 二、")[0]
    for sec in re.split(r"^#### ", head, flags=re.M)[1:]:
        m = re.match(r"`(\w+)`", sec)
        if not m:
            continue
        for row in re.findall(r"^\| ([^|]+) \| [^|]+ \| ([^|]+) \|$", sec, re.M):
            name = row[0].strip().strip("`")
            if re.fullmatch(r"\w+", name):          # 一行说明多个列的（如 name / title / fee）不用，免得每列都挂同一句
                cols.setdefault((m.group(1), name), re.sub(r"\*\*|`|\(v3\)\s*", "", row[1]).strip())
    # 文档里和别的列写在一行的，单独补一句
    for k, v in {("doctors", "name"): "姓名", ("doctors", "title"): "职称（主任医师 / 副主任医师 / 主治医师）",
                 ("doctors", "fee"): "现行挂号费，由 ck_doctor_fee_rule 按湖北省标准约束",
                 ("patients", "phone_cc"): "国际区号，默认 86", ("patients", "phone"): "手机号（不含区号）",
                 ("appointments", "schedule_id"): "排班编号", ("appointments", "doctor_id"): "接诊医生（与排班一致）",
                 ("appointments", "patient_id"): "就诊人", ("appointments", "close_note"): "停诊 / 退号备注",
                 ("appointments", "cancelled_at"): "取消时间（已取消时必填）"}.items():
        cols.setdefault(k, v)
    for row in re.findall(r"^\| (\S+) \| (?:PK|FK|UQ|CK|UI) \| [^|]+ \| ([^|]+) \|$", txt, re.M):
        cons[row[0]] = re.sub(r"\*\*", "", row[1].strip())
    return tables, cols, cons


# 列的书写顺序：运行库里后加的列（ALTER TABLE ADD COLUMN）都排在末尾，读起来不顺，这里按含义重新排；
# 没列出的表保持原顺序，创建 / 修改时间一律放最后
COL_ORDER = {
    "departments": ["id", "name", "description", "location", "sex_limit"],
    "patients": ["id", "name", "sex", "id_type", "nationality", "id_card", "doc_key", "phone_cc", "phone", "email"],
    "appointments": ["id", "appointment_no", "seq_no", "schedule_id", "doctor_id", "patient_id", "fee", "status",
                     "cancel_reason", "close_note", "cancelled_at"],
    "schedules": ["id", "doctor_id", "dept_id", "work_date", "weekday", "time_slot", "start_time", "end_time", "room",
                  "max_quota", "booked_count", "closed"],
    "users": ["id", "username", "password_hash", "display_name", "role", "status", "last_login_at"],
}


def col_rank(table, col):
    order = COL_ORDER.get(table, [])
    if col in order:
        return (0, order.index(col))
    if col in ("created_at", "updated_at"):
        return (2, 0 if col == "created_at" else 1)
    return (1, 0)


def table_order(conn, tables):
    deps = {t: set() for t in tables}
    for child, parent in conn.execute("""SELECT conrelid::regclass::text, confrelid::regclass::text FROM pg_constraint co
            JOIN pg_namespace n ON n.oid = co.connamespace WHERE n.nspname = 'public' AND contype = 'f'""").fetchall():
        if child != parent:
            deps[child].add(parent)
    order, done = [], set()
    # 尽量保持「核心业务 → 后台 → 审计 → 其它」的阅读顺序，同时满足外键依赖
    prefer = ["departments", "doctors", "doctor_fee_history", "schedules", "patients", "appointments", "waitlist",
              "users", "user_sessions", "patient_sessions", "citizen_registry", "identity_verify_log",
              "verification_codes", "blacklist", "appointment_log", "access_log", "notification_outbox", "dept_keywords"]
    pending = [t for t in prefer if t in tables] + sorted(t for t in tables if t not in prefer)
    while pending:
        for t in pending:
            if deps[t] <= done:
                order.append(t); done.add(t); pending.remove(t)
                break
        else:
            raise RuntimeError("外键存在环：%s" % pending)
    return order


def build():
    conn = connect(DB)
    q = lambda sql, *a: conn.execute(sql, a).fetchall()
    tnotes, cnotes, knotes = doc_notes()
    tables = [r[0] for r in q("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")]
    order = table_order(conn, tables)
    funcs = {r[0]: (r[1], r[2]) for r in q("""SELECT p.proname, pg_get_functiondef(p.oid), pg_get_function_identity_arguments(p.oid)
                                              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'""")}

    def func_sql(name):
        # 只去掉函数名前的 public.；函数体里的 public. 前缀要保留（pg_restore 恢复时搜索路径为空，少了它会找不到函数）
        return funcs[name][0].strip().replace("FUNCTION public.", "FUNCTION ", 1) + ";"

    out = []
    w = out.append
    line = "-- " + "=" * 76
    sec = lambda t: w(f"\n\n{line}\n--  {t}\n{line}\n")

    w(f"""{line}
--  智慧医院预约挂号系统（HMS）—— 数据库完整脚本
--  PostgreSQL 14 及以上（开发与验证环境：PostgreSQL 18）
{line}
--
--  用途
--    假设从零开始：执行本脚本，得到与系统运行库完全一致的数据库 ——
--    {len(tables)} 张表、5 个视图、{len(funcs)} 个函数、21 个触发器、全部约束与索引，
--    以及基础数据（{len(DEPARTMENTS)} 个科室、{len(DOCTORS)} 位医生、后台账号、未来 {SEED_DAYS} 天的排班、
--    约 1.9 万条科室搜索词典）。执行完即可启动应用。
--
--  执行方式（在 HMS 目录、以超级用户身份；科室词典按相对路径 server/data/dept_keywords.csv 导入）
--    psql -U postgres -f 数据库脚本.sql
--
--  ★ 本脚本会删除并重建全部表，对已有挂号数据的库执行会清空数据。
--    已在使用的库升级请运行 .venv\\Scripts\\python.exe server\\app.py --init（只补缺少的对象）。
--
--  本文件由 tools/build_db_script.py 按运行库的实际结构生成（{datetime.date.today():%Y-%m-%d}），请勿手工修改。
--
--  脚本结构
--    第 0 部分  建库并连接
--    第 1 部分  清理旧对象（可重复执行）
--    第 2 部分  扩展与建表要用的函数（证件校验、证件键、脱敏、挂号费定价）
--    第 3 部分  数据表（每张表的列、约束、索引都写在一起；按外键依赖排序）
--    第 4 部分  视图
--    第 5 部分  函数（触发器函数与可直接调用的函数）
--    第 6 部分  触发器
--    第 7 部分  基础数据装载
--    第 8 部分  检查与验证
--
--  设计原则
--    能在数据库里表达的业务规则，就写进数据库：号源增减、号序分配、状态流转、防超卖、限挂、
--    候补补位、实名校验、科室性别限制、挂号费定价都由约束、触发器和函数完成。应用层的校验
--    只为给用户即时、友好的提示；数据库这一层保证「绕过接口直接写库，也写不进不合规的数据」。
--
--  挂号费
--    按湖北省门诊诊查费标准（鄂医保发〔2025〕56 号）：主治 4.5、副主任 14.5、主任 21.5 元，
--    妇产科、口腔科加收 2 元，中医科 11.5 / 16.5 / 21.5 元（函数 fn_doctor_fee）。
--
--  业务错误的抛出方式
--    触发器中的 RAISE EXCEPTION 不指定 ERRCODE，默认 SQLSTATE = P0001；
--    应用层把 P0001 的消息原样返回给用户，所以错误信息都写成中文。
{line}""")

    sec("第 0 部分  建库并连接")
    w(f"""-- 库不存在才创建（CREATE DATABASE 不能放进事务或 DO 块，用 \\gexec 实现条件执行）
SELECT 'CREATE DATABASE {DB} WITH ENCODING = ''UTF8'' TEMPLATE = template0'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '{DB}')
\\gexec
\\c {DB}
SET client_encoding = 'UTF8';
SET client_min_messages = warning;
-- 任一语句出错就停止，避免在半成品的库上继续执行
\\set ON_ERROR_STOP on""")

    sec("第 1 部分  清理旧对象（可重复执行）")
    w("\n".join(f"DROP TABLE IF EXISTS {t:<20} CASCADE;" for t in reversed(order)))
    w("")
    w("\n".join(f"DROP FUNCTION IF EXISTS {n}({funcs[n][1]}) CASCADE;" for n in sorted(funcs)))

    sec("第 2 部分  扩展与建表要用的函数")
    w("""-- 科室搜索的「包含」匹配（LIKE '%胃%'）要用三元组索引，扩展装在单独的 ext 模式里
CREATE SCHEMA IF NOT EXISTS ext;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA ext;
""")
    for n in HELPER_FUNCS:
        w(func_sql(n) + "\n")

    sec("第 3 部分  数据表")
    cols_all = q("""SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, a.attidentity, a.attgenerated,
                           pg_get_expr(d.adbin, d.adrelid)
                      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                     WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
                     ORDER BY c.relname, a.attnum""")
    cons_all = q("""SELECT conrelid::regclass::text, conname, contype, pg_get_constraintdef(co.oid)
                      FROM pg_constraint co JOIN pg_namespace n ON n.oid = co.connamespace
                     WHERE n.nspname = 'public' AND contype IN ('p', 'u', 'f', 'c')
                     ORDER BY 1, position(contype IN 'pufc'), 2""")
    idx_all = q("""SELECT tablename, indexname, indexdef FROM pg_indexes i WHERE schemaname = 'public'
                     AND NOT EXISTS (SELECT 1 FROM pg_constraint co WHERE co.conname = i.indexname) ORDER BY 1, 2""")
    for t in order:
        w(f"-- {t}：{tnotes.get(t, '')}".rstrip("："))
        body = []
        cols = sorted([r for r in cols_all if r[0] == t], key=lambda r: col_rank(t, r[1]))
        width = max(len(r[1]) for r in cols)
        for _, name, typ, notnull, ident, gen, dflt in cols:
            s = f"  {name.ljust(width)}  {nice_type(typ)}"
            if gen == "s":
                s += f" GENERATED ALWAYS AS ({tidy(dflt)}) STORED"
            elif ident == "d":
                s += " GENERATED BY DEFAULT AS IDENTITY"
            elif dflt is not None:
                s += " DEFAULT " + {"now()": "NOW()", "true": "TRUE", "false": "FALSE"}.get(tidy(dflt), tidy(dflt))
            if notnull:
                s += " NOT NULL"
            body.append([s, cnotes.get((t, name), "")])
        for _, name, typ, d in [r for r in cons_all if r[0] == t]:
            note = knotes.get(name, "")
            if note:
                body.append(["", "-- " + note])
            body.append([f"  CONSTRAINT {name} {tidy(d)}", ""])
        lines = []
        for i, (s, note) in enumerate(body):
            if s == "":
                lines.append("  " + note)
                continue
            comma = "," if any(x[0] for x in body[i + 1:]) else ""
            lines.append(s + comma + (f"   -- {note}" if note else ""))
        w(f"CREATE TABLE {t} (\n" + "\n".join(lines) + "\n);")
        for _, iname, idef in [r for r in idx_all if r[0] == t]:
            note = knotes.get(iname, "")
            idef = tidy(idef).replace(" USING btree", "")
            w((f"-- {note}\n" if note else "") + idef + ";")
        w("")

    sec("第 4 部分  视图")
    views = {r[0]: r[1] for r in q("SELECT viewname, pg_get_viewdef(('public.' || viewname)::regclass, true) FROM pg_views WHERE schemaname = 'public'")}
    vdeps = {v: set() for v in views}
    for v, dep in q("""SELECT DISTINCT cl.relname, ref.relname FROM pg_rewrite r JOIN pg_class cl ON cl.oid = r.ev_class
                         JOIN pg_depend d ON d.objid = r.oid JOIN pg_class ref ON ref.oid = d.refobjid
                        WHERE ref.relkind = 'v' AND cl.relname <> ref.relname AND cl.relkind = 'v'"""):
        if v in vdeps:
            vdeps[v].add(dep)
    vorder, vdone = [], set()
    while len(vorder) < len(views):
        for v in sorted(views):
            if v not in vdone and vdeps[v] <= vdone:
                vorder.append(v); vdone.add(v)
                break
    for v in vorder:
        # x::text = ANY (ARRAY['a'::character varying, ...]::text[]) 原样执行会被改写成另一种形式，还原成 IN 列表
        body = re.sub(r"([\w.]+)::text = ANY \(ARRAY\[(.*?)\]::text\[\]\)",
                      lambda m: m.group(1) + " IN (" + ", ".join(re.findall(LIT_RE, m.group(2))) + ")",
                      views[v].strip().rstrip(";"))
        w(f"CREATE VIEW {v} AS\n{body};\n")

    sec("第 5 部分  函数")
    for n in sorted(funcs):
        if n not in HELPER_FUNCS:
            w(func_sql(n) + "\n")

    sec("第 6 部分  触发器")
    for tname, d in q("""SELECT t.tgname, pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                          JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND NOT t.tgisinternal
                          ORDER BY c.relname, t.tgname"""):
        w(d.replace("public.", "") + ";")

    sec("第 7 部分  基础数据装载")
    lit = lambda v: "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"
    w("-- 业务数据（就诊人、挂号、候补等）初始为空，由患者在系统中产生。\n")
    w(f"-- 科室（{len(DEPARTMENTS)} 个）：sex_limit 为 F 只接诊女性、M 只接诊男性")
    w("INSERT INTO departments (id, name, description, location, sex_limit) VALUES\n" + ",\n".join(
        f"  ({lit(d['id'])}, {lit(d['name'])}, {lit(d['description'])}, {lit(d['location'])}, {lit(d.get('sexLimit'))})" for d in DEPARTMENTS) + ";\n")
    w(f"-- 医生（{len(DOCTORS)} 位）：挂号费必须等于 fn_doctor_fee(职称, 科室)，否则违反 ck_doctor_fee_rule；")
    w("-- 插入时触发器 trg_doctor_fee_history 自动把这个价格登记进价目历史")
    w("INSERT INTO doctors (id, dept_id, name, title, fee) VALUES\n" + ",\n".join(
        f"  ({lit(d['id'])}, {lit(d['deptId'])}, {lit(d['name'])}, {lit(d['title'])}, {d['fee']:.2f})" for d in DOCTORS) + ";\n")
    w("-- 后台账号：初始口令见 server/seed_data.py（存的是 scrypt 散列，明文不入库），正式使用前请修改。")
    w("INSERT INTO users (id, username, password_hash, display_name, role, status) VALUES\n" + ",\n".join(
        f"  ({lit(u['id'])}, {lit(u['username'])}, {lit(hash_password(u['password']))}, {lit(u['displayName'])}, {lit(u.get('role', 'admin'))}, 'active')"
        for u in USERS) + ";\n")
    quota = " ".join(f"WHEN {lit(t)} THEN {n}" for t, n in QUOTA_BY_TITLE.items())
    periods = ",\n                    ".join(f"({lit(p['key'])}, {lit(p['slot'])}, TIME {lit(p['start'])}, TIME {lit(p['end'])})" for p in PERIODS)
    w(f"""-- 排班：从今天起 {SEED_DAYS} 天 × 每位医生 × 上午 / 下午；号源按职称分档，诊室号按医生编号推导（DR01 → 诊室 01）
INSERT INTO schedules (id, doctor_id, dept_id, work_date, weekday, time_slot, start_time, end_time, room, max_quota)
SELECT 'SC_' || doc.id || '_' || to_char(day, 'YYYY-MM-DD') || '_' || p.code,
       doc.id, doc.dept_id, day::date,
       (ARRAY['周日','周一','周二','周三','周四','周五','周六'])[EXTRACT(DOW FROM day)::int + 1],
       p.slot, p.start_time, p.end_time,
       '诊室 ' || lpad(substring(doc.id FROM 3)::int::text, 2, '0'),
       CASE doc.title {quota} END
  FROM doctors doc
 CROSS JOIN generate_series(CURRENT_DATE, CURRENT_DATE + {SEED_DAYS - 1}, INTERVAL '1 day') AS day
 CROSS JOIN (VALUES {periods})
            AS p(code, slot, start_time, end_time)
 ORDER BY day, doc.id, p.code;

-- 科室搜索词典（约 1.9 万条「疾病 / 症状 → 科室」，来自开源医疗知识图谱，由 tools/build_dept_keywords.py 整理）
\\copy dept_keywords (term, kind, dept_id, other_dept, weight, pinyin, abbr) FROM 'server/data/dept_keywords.csv' WITH (FORMAT csv, HEADER true, NULL '')""")

    sec("第 8 部分  检查与验证")
    w(f"""-- 8.1 数据装载结果
SELECT 'departments' AS 表名, COUNT(*) AS 行数 FROM departments
UNION ALL SELECT 'doctors',            COUNT(*) FROM doctors
UNION ALL SELECT 'doctor_fee_history', COUNT(*) FROM doctor_fee_history
UNION ALL SELECT 'users',              COUNT(*) FROM users
UNION ALL SELECT 'schedules',          COUNT(*) FROM schedules
UNION ALL SELECT 'dept_keywords',      COUNT(*) FROM dept_keywords;

-- 8.2 数据库对象数量（应为：表 {len(tables)} / 视图 {len(views)} / 函数 {len(funcs)} / 触发器 21 / 索引 53）
SELECT (SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public') AS 表,
       (SELECT COUNT(*) FROM pg_views  WHERE schemaname = 'public') AS 视图,
       (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public') AS 函数,
       (SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND NOT t.tgisinternal) AS 触发器,
       (SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public') AS 索引;

-- 8.3 约束分类计数（应为：主键 18 / 外键 19 / 唯一 11 / 检查 43 / 非空 123）
SELECT CASE c.contype WHEN 'p' THEN '主键' WHEN 'f' THEN '外键' WHEN 'u' THEN '唯一'
                      WHEN 'c' THEN '检查' WHEN 'n' THEN '非空' END AS 约束类型,
       COUNT(*) AS 数量
  FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
 WHERE n.nspname = 'public'
 GROUP BY c.contype ORDER BY c.contype;

-- 8.4 核心不变量：所有排班的已约数之和 = 待就诊挂号单数（差值应为 0）
SELECT (SELECT COALESCE(SUM(booked_count), 0) FROM schedules)      AS 已约号源,
       (SELECT COUNT(*) FROM appointments WHERE status = 'booked') AS 待就诊挂号,
       (SELECT COALESCE(SUM(booked_count), 0) FROM schedules)
     - (SELECT COUNT(*) FROM appointments WHERE status = 'booked') AS 差值;

-- 8.5 挂号费：每位医生的现行价格与标准价格
SELECT d.id, dp.name AS 科室, d.title AS 职称, d.fee AS 挂号费, fn_doctor_fee(d.title, d.dept_id) AS 标准价格
  FROM doctors d JOIN departments dp ON dp.id = d.dept_id ORDER BY d.id;

-- 8.6 价格防篡改演示（取消注释执行，最后回滚）：把医生价格改成 1 元会违反 ck_doctor_fee_rule
-- BEGIN;
-- UPDATE doctors SET fee = 1 WHERE id = 'DR01';
-- ROLLBACK;""")

    text = "\n".join(out).strip() + "\n"
    # 换行用 \n：psql 会把 \r 原样存进函数体，用 Windows 换行会让函数定义和运行库不一致
    open(OUT, "wb").write(text.encode("utf-8"))
    print(OUT, len(text.splitlines()), "行")
    return text


def snapshot(dbname):
    """数据库结构的规范化快照，用来比对脚本建出的库与运行库是否一致"""
    with connect(dbname) as c:
        return _snapshot(c)


def _snapshot(c):
    q = lambda s: [tuple(r) for r in c.execute(s).fetchall()]
    return {
        "columns": q("""SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, a.attidentity,
                               a.attgenerated, pg_get_expr(d.adbin, d.adrelid)
                          FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                          LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                         WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped ORDER BY 1, 2"""),   # 不比较列的物理顺序
        "constraints": q("""SELECT conrelid::regclass::text, conname, contype, pg_get_constraintdef(co.oid) FROM pg_constraint co
                             JOIN pg_namespace n ON n.oid = co.connamespace WHERE n.nspname = 'public' AND contype <> 'n' ORDER BY 1, 2"""),
        "notnull": q("""SELECT count(*) FROM pg_constraint co JOIN pg_namespace n ON n.oid = co.connamespace
                         WHERE n.nspname = 'public' AND contype = 'n'"""),
        "indexes": q("SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1, 2"),
        "views": q("SELECT viewname, pg_get_viewdef(('public.' || viewname)::regclass, true) FROM pg_views WHERE schemaname = 'public' ORDER BY 1"),
        "functions": q("""SELECT p.proname, pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                           WHERE n.nspname = 'public' ORDER BY 1"""),
        "triggers": q("""SELECT t.tgname, pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                          JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND NOT t.tgisinternal ORDER BY 1"""),
    }


def verify(text):
    """在临时库里执行脚本，再与运行库逐项比对"""
    tmp = "hms_scriptcheck"
    script = text.replace(DB, tmp)
    path = os.path.join(os.environ.get("TEMP", "."), "hms_scriptcheck.sql")
    open(path, "w", encoding="utf-8", newline="\n").write(script)
    env = dict(os.environ, PGPASSWORD=CFG["password"], PGCLIENTENCODING="UTF8")
    r = subprocess.run([PSQL, "-X", "-q", "-h", CFG["host"], "-p", str(CFG["port"]), "-U", CFG["user"], "-d", "postgres", "-f", path],
                       cwd=ROOT, capture_output=True, env=env)
    err = r.stderr.decode("utf-8", "replace")
    if r.returncode or "ERROR" in err:
        print("脚本执行失败：\n" + err[-3000:])
        return False
    a, b = snapshot(DB), snapshot(tmp)
    ok = True
    for k in a:
        da, db_ = set(a[k]), set(b[k])
        if da != db_:
            ok = False
            print(f"[不一致] {k}：运行库独有 {len(da - db_)} 项，脚本库独有 {len(db_ - da)} 项")
            for x in sorted(da - db_, key=str)[:5]:
                print("   运行库:", str(x)[:300])
            for x in sorted(db_ - da, key=str)[:5]:
                print("   脚本库:", str(x)[:300])
    with connect("postgres") as c:
        c.execute(f"DROP DATABASE {tmp}")
    os.remove(path)
    print("与运行库逐项比对：" + ("完全一致" if ok else "有差异（见上）"))
    return ok


if __name__ == "__main__":
    text = build()
    if "--verify" in sys.argv:
        sys.exit(0 if verify(text) else 1)
