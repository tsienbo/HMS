# -*- coding: utf-8 -*-
"""v2 库 → v3 库（增量，幂等）。

    python server/migrate_v3.py

做四件事：
    1. 把 schema_v3.sql 整份发给数据库（全是 ALTER / CREATE IF NOT EXISTS，
       反复执行结果一样，不会动 v2 已有的表和数据）；
    2. 把现有后台账号的 role 补成 admin（v3 之前没有这一列，默认值已经兜住，
       这一步只是把「历史上唯一的管理员」明确下来）；
    3. 打印对象清单，和预期数字对一下；
    4. 自检：候补 / 发件箱 / 访问日志 / 黑名单四张表在不在，触发器挂上没。

★ 为什么单独一个文件而不是塞进 schema.sql：
  schema.sql 是「从零建库」，里面全是 DROP TABLE ... CASCADE；
  v3 是「给已经跑着数据的库加东西」，绝不能带 DROP。
  两者分开，--force 重建时先跑 schema.sql 再跑 schema_v3.sql，路径只有一条。
"""

import sys
from pathlib import Path

from db import DB_NAME, pool, query

HERE = Path(__file__).resolve().parent
V3_FILE = HERE / "schema_v3.sql"

EXPECTED_V3_TABLES = ["waitlist", "notification_outbox", "access_log", "blacklist",
                      "citizen_registry", "identity_verify_log"]
EXPECTED_V3_VIEWS = ["v_waitlist_detail"]
EXPECTED_V3_TRIGGERS = [
    "trg_waitlist_touch", "trg_waitlist_before_insert", "trg_waitlist_before_update",
    "trg_appt_promote_waitlist", "trg_appt_close_waitlist", "trg_appt_guard",
]
EXPECTED_V3_FUNCTIONS = [
    "fn_waitlist_before_insert", "fn_waitlist_before_update", "fn_offer_next_waitlist",
    "fn_appt_promote_waitlist", "fn_appt_guard_before_insert", "fn_appt_close_waitlist",
]


def apply_schema_v3():
    text = V3_FILE.read_text(encoding="utf-8")
    query(text)


def seed_roles():
    """v3 之前建的账号没有角色概念，统一按管理员处理。

    之后再想分权，直接改 users.role 就行：
        UPDATE users SET role = 'auditor' WHERE username = 'audit01';
    """
    r = query("SELECT username, role FROM users ORDER BY id")
    for row in r.rows:
        if not row["role"]:
            query("UPDATE users SET role = 'admin' WHERE username = %s", [row["username"]])
    return r.rows


def verify():
    tables = {x["tablename"] for x in query(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public'").rows}
    views = {x["viewname"] for x in query(
        "SELECT viewname FROM pg_views WHERE schemaname = 'public'").rows}
    triggers = {x["tgname"] for x in query("""
        SELECT t.tgname FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND NOT t.tgisinternal
    """).rows}
    funcs = {x["proname"] for x in query("""
        SELECT p.proname FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
    """).rows}

    missing = {
        "表": [t for t in EXPECTED_V3_TABLES if t not in tables],
        "视图": [v for v in EXPECTED_V3_VIEWS if v not in views],
        "触发器": [t for t in EXPECTED_V3_TRIGGERS if t not in triggers],
        "函数": [f for f in EXPECTED_V3_FUNCTIONS if f not in funcs],
    }
    return missing


def main():
    print("\n升级数据库 %s → v3 ...\n" % DB_NAME)

    apply_schema_v3()
    print("  · schema_v3.sql 已执行（幂等，未删除任何 v2 对象）")

    roles = seed_roles()
    print("  · 后台账号角色：%s"
          % "、".join("%s=%s" % (r["username"], r["role"] or "admin") for r in roles))

    missing = verify()
    bad = {k: v for k, v in missing.items() if v}
    if bad:
        print("  [!!] 缺失对象：")
        for k, v in bad.items():
            print("       %s：%s" % (k, ", ".join(v)))
        return 1

    r = query("""
        SELECT (SELECT count(*) FROM pg_tables  WHERE schemaname='public')::int AS tables,
               (SELECT count(*) FROM pg_views   WHERE schemaname='public')::int AS views,
               (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public')::int AS functions,
               (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                  JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND NOT t.tgisinternal)::int AS triggers,
               (SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
                 WHERE n.nspname='public')::int AS constraints,
               (SELECT count(*) FROM pg_indexes WHERE schemaname='public')::int AS indexes
    """).rows[0]
    print("  · 对象清单：表 %d / 视图 %d / 函数 %d / 触发器 %d / 约束 %d / 索引 %d"
          % (r["tables"], r["views"], r["functions"],
             r["triggers"], r["constraints"], r["indexes"]))
    print("\n完成。\n")
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except Exception as err:                                  # noqa: BLE001
        print("\n升级失败：%s" % err)
        code = 1
    finally:
        pool.close_all()
    sys.exit(code)
