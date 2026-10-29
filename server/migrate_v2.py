# -*- coding: utf-8 -*-
"""v1 → v2 数据库迁移（保留全部既有数据）。

用法：
    python server/migrate_v2.py --yes            迁移当前库（PGDATABASE 可覆盖库名）
    python server/migrate_v2.py --yes --check     只检查，不写库

为什么不是手写一堆 ALTER：
    改列名、加约束、加视图触发器，写成 ALTER 的话，新库（--force 重建）
    和迁移上来的库就是两套 DDL，早晚会漂移。
    这里换了个做法 —— 把旧表整体挪进 old_v1 schema，然后原样执行
    server/schema.sql（和全新安装用的是同一份文件），最后把数据搬过去。
    好处：结构只有一份定义，迁移完的库与 --force 重建的库逐字节一致。

事务：
    整个过程在一个事务里。任何一步失败都整体回滚，旧数据分毫不动。
    开始前请自行备份（pg_dump），本脚本不会替你备份。
"""

import sys
from pathlib import Path

import psycopg

from db import DB_CONFIG, DB_NAME

HERE = Path(__file__).resolve().parent
SCHEMA_FILE = HERE / "schema.sql"

OLD_SCHEMA = "old_v1"
OLD_TABLES = ["user_sessions", "users", "appointments",
              "schedules", "doctors", "departments"]


def table_exists(cur, name, schema="public"):
    cur.execute(
        "SELECT to_regclass(%s) IS NOT NULL AS ok",
        ['%s."%s"' % (schema, name)],
    )
    return cur.fetchone()["ok"]


def column_exists(cur, table, column):
    cur.execute(
        """SELECT EXISTS (
             SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = %s AND column_name = %s
           ) AS ok""",
        [table, column],
    )
    return cur.fetchone()["ok"]


def scalar(cur, sql):
    cur.execute(sql)
    return cur.fetchone()["v"]


def migrate(check_only=False):
    schema_text = SCHEMA_FILE.read_text(encoding="utf-8")

    conn = psycopg.connect(**DB_CONFIG, dbname=DB_NAME,
                           row_factory=psycopg.rows.dict_row,
                           autocommit=False)
    try:
        with conn.cursor() as cur:
            # ---------- 1. 判断当前版本 ----------
            if not table_exists(cur, "schedules"):
                print("库 %s 里没有 schedules 表 —— 这是空库，直接跑 "
                      "python server/app.py --init 即可，不需要迁移。" % DB_NAME)
                return 1

            if column_exists(cur, "schedules", "max_quota"):
                print("库 %s 已经是 v2（schedules.max_quota 存在），无需迁移。" % DB_NAME)
                return 0

            if not column_exists(cur, "schedules", "quota_total"):
                print("库 %s 的 schedules 既不是 v1 也不是 v2，无法识别。" % DB_NAME)
                return 1

            before = {
                "departments": scalar(cur, "SELECT count(*)::int AS v FROM departments"),
                "doctors": scalar(cur, "SELECT count(*)::int AS v FROM doctors"),
                "schedules": scalar(cur, "SELECT count(*)::int AS v FROM schedules"),
                "appointments": scalar(cur, "SELECT count(*)::int AS v FROM appointments"),
                "users": scalar(cur, "SELECT count(*)::int AS v FROM users"),
            }
            print("\n迁移目标库：%s" % DB_NAME)
            print("  迁移前：科室 %(departments)d / 医生 %(doctors)d / 排班 %(schedules)d "
                  "/ 挂号 %(appointments)d / 账号 %(users)d" % before)

            if check_only:
                print("\n--check：只检查，不写库。")
                conn.rollback()
                return 0

            # ---------- 2. 旧表挪进 old_v1 ----------
            # 换 schema 而不是改名：索引名在 schema 内唯一，直接改名会和
            # 新建的同名索引（departments_pkey 等）撞车。
            cur.execute("DROP SCHEMA IF EXISTS %s CASCADE" % OLD_SCHEMA)
            cur.execute("CREATE SCHEMA %s" % OLD_SCHEMA)
            for t in OLD_TABLES:
                cur.execute('ALTER TABLE public."%s" SET SCHEMA %s' % (t, OLD_SCHEMA))
            print("  · 旧表已移入 %s schema" % OLD_SCHEMA)

            # ---------- 3. 建新结构 ----------
            # schema.sql 里的 DROP TABLE IF EXISTS 此时都是空操作（public 里已经没有表了）
            cur.execute(schema_text)
            print("  · 已执行 schema.sql（8 张表 / 4 视图 / 9 函数 / 14 触发器）")

            # ---------- 4. 搬数据 ----------
            cur.execute("""
                INSERT INTO departments (id, name, description)
                SELECT id, name, description FROM old_v1.departments
            """)
            cur.execute("""
                INSERT INTO doctors (id, dept_id, name, title, fee)
                SELECT id, dept_id, name, title, fee FROM old_v1.doctors
            """)
            # 排班：period → time_slot，号源列改名，并补上半天起止时间
            cur.execute("""
                INSERT INTO schedules
                       (id, doctor_id, dept_id, work_date, weekday, time_slot,
                        start_time, end_time, max_quota, booked_count, closed)
                SELECT id, doctor_id, dept_id, work_date, weekday, period,
                       CASE period WHEN '上午' THEN TIME '08:00' ELSE TIME '13:30' END,
                       CASE period WHEN '上午' THEN TIME '12:00' ELSE TIME '17:00' END,
                       quota_total, quota_booked, closed
                  FROM old_v1.schedules
            """)

            # 患者：从旧挂号单里按身份证去重，取该人最新一条的姓名与手机号
            cur.execute("""
                INSERT INTO patients (id, name, id_card, phone)
                SELECT 'P' || lpad(row_number() OVER (ORDER BY id_card)::text, 6, '0'),
                       patient_name, id_card, phone
                  FROM (SELECT DISTINCT ON (id_card) patient_name, id_card, phone
                          FROM old_v1.appointments
                         ORDER BY id_card, created_at DESC) t
            """)

            # 挂号单：先把触发器关掉，否则搬历史单据会重新分配号序、
            # 还会把号源再加一遍（数据已经是「加过」的状态）。
            cur.execute("ALTER TABLE appointments DISABLE TRIGGER USER")
            # v1 退号时会把后面人的号序整体前移，所以历史数据里存在
            # 同一排班两条单据共用一个 seq_no 的情况。v2 有 uq_appt_schedule_seq，
            # 直接搬会撞唯一约束，所以这里按 created_at 重新编成 1..n。
            cur.execute("""
                INSERT INTO appointments
                       (id, seq_no, schedule_id, doctor_id, patient_id, fee,
                        status, cancel_reason, close_note, created_at, cancelled_at)
                SELECT a.id,
                       row_number() OVER (PARTITION BY a.schedule_id
                                          ORDER BY a.created_at, a.id),
                       a.schedule_id, a.doctor_id, p.id, a.fee,
                       CASE a.status WHEN 'active' THEN 'booked' ELSE 'cancelled' END,
                       CASE WHEN a.status = 'closed' THEN 'closure'
                            WHEN a.status = 'cancelled' AND a.close_note LIKE '医生停诊%' THEN 'closure'
                            WHEN a.status = 'cancelled' AND a.close_note LIKE '管理端%'   THEN 'admin'
                            WHEN a.status = 'cancelled' THEN 'patient'
                       END,
                       NULLIF(a.close_note, ''),
                       a.created_at,
                       a.cancelled_at
                  FROM old_v1.appointments a
                  JOIN patients p ON p.id_card = a.id_card
            """)

            cur.execute("ALTER TABLE appointments ENABLE TRIGGER USER")

            # 审计日志：历史单据补一条「创建」，已取消的再补一条「取消」
            cur.execute("""
                INSERT INTO appointment_log
                       (appointment_id, action, old_status, new_status, operator, changed_at)
                SELECT id, 'insert', NULL, 'booked', 'migration-v2', created_at
                  FROM appointments
            """)
            cur.execute("""
                INSERT INTO appointment_log
                       (appointment_id, action, old_status, new_status, operator, changed_at)
                SELECT id, 'cancel', 'booked', 'cancelled', 'migration-v2', cancelled_at
                  FROM appointments
                 WHERE status = 'cancelled'
            """)

            cur.execute("""
                INSERT INTO users (id, username, password_hash, display_name,
                                   status, last_login_at, created_at)
                SELECT id, username, password_hash, display_name,
                       status, last_login_at, created_at
                  FROM old_v1.users
            """)
            cur.execute("""
                INSERT INTO user_sessions (token, user_id, created_at, expires_at)
                SELECT token, user_id, created_at, expires_at
                  FROM old_v1.user_sessions
            """)

            # ---------- 5. 一致性自检 ----------
            # booked_count 必须等于该排班「待就诊」的挂号数，否则说明搬数据时算错了
            bad = scalar(cur, """
                SELECT count(*)::int AS v FROM schedules s
                 WHERE s.booked_count <> (
                       SELECT count(*) FROM appointments a
                        WHERE a.schedule_id = s.id AND a.status = 'booked')
            """)
            if bad:
                raise RuntimeError("号源一致性校验失败：%d 条排班的 booked_count 对不上" % bad)

            seq_bad = scalar(cur, """
                SELECT count(*)::int AS v FROM (
                  SELECT schedule_id, seq_no FROM appointments
                   GROUP BY 1, 2 HAVING count(*) > 1) t
            """)
            if seq_bad:
                raise RuntimeError("号序唯一性校验失败：%d 组重复" % seq_bad)

            after = {
                "departments": scalar(cur, "SELECT count(*)::int AS v FROM departments"),
                "doctors": scalar(cur, "SELECT count(*)::int AS v FROM doctors"),
                "schedules": scalar(cur, "SELECT count(*)::int AS v FROM schedules"),
                "appointments": scalar(cur, "SELECT count(*)::int AS v FROM appointments"),
                "patients": scalar(cur, "SELECT count(*)::int AS v FROM patients"),
                "logs": scalar(cur, "SELECT count(*)::int AS v FROM appointment_log"),
            }

            cur.execute("DROP SCHEMA %s CASCADE" % OLD_SCHEMA)
            conn.commit()

            print("  · 数据已搬迁（患者档案 %d 条 / 审计日志 %d 条）"
                  % (after["patients"], after["logs"]))
            print("  迁移后：科室 %(departments)d / 医生 %(doctors)d / 排班 %(schedules)d "
                  "/ 挂号 %(appointments)d" % after)
            print("\n迁移完成。请重启服务进程，让它重新读取新的表结构。\n")
            return 0
    except Exception as err:
        conn.rollback()
        print("\n[!!] 迁移失败，已整体回滚，原数据未受影响。")
        print("     错误：%s" % str(err).splitlines()[0])
        return 1
    finally:
        conn.close()


def main(argv):
    if "--yes" not in argv:
        print(__doc__)
        print("请在确认已备份后加上 --yes 再执行。")
        return 1
    return migrate(check_only="--check" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
