-- ============================================================================
--  智慧医院预约挂号系统 —— 数据库完整脚本（PostgreSQL）
-- ============================================================================
--
--  文件说明
--  --------
--  本文件把整个项目用到的全部 SQL 命令汇总在一起，按顺序执行即可
--  从零建起一套完整、自洽、可运行的数据库。共 16 组 + 1 个附录。
--
--      第 0 组    连接与建库
--      第 1 组    幂等清理（可重复执行）
--      第 2 组    建表（7 张业务表，含全部字段级完整性约束）
--      第 3 组    建索引（含 2 个"防重复挂号"的部分索引）
--      第 4 组    视图一：排班号源使用情况
--      第 5 组    视图二：医生工作量统计
--      第 6 组    审计日志表（供触发器写入）
--      第 7 组    触发器函数 + 触发器
--      第 8 组    函数一：查询某医生的剩余号源
--      第 9 组    函数二：按科室统计某日挂号情况（返回表）
--      第 10 组   存储过程：归档过期挂号
--      第 11 组   基础数据装载（科室 / 医生 / 后台账号）
--      第 12 组   业务数据装载（排班 / 号源 / 挂号记录）
--      第 13 组   数据操纵演示（ALTER / INSERT / UPDATE / DELETE）
--      第 14 组   对象调用与业务验证
--      第 15 组   数据库对象清单查询
--      附录 A     日常排查与运维查询
--
--  阅读约定
--  --------
--    · 以  --  开头的是注释，不用敲。
--    · 以  \   开头的是 psql 客户端元命令（如 \c \dt \d \df），不是 SQL，
--      只能在 psql 里执行；用 pgAdmin 查询工具时要换成等价的 SQL 查询。
--    · 建议一组一组执行、一组一组核对输出，不要一口气全贴进去。
--
--  执行方式
--  --------
--    【推荐】命令行整体执行（psql 会按顺序逐条跑，遇到错误会提示行号）：
--
--        set PGCLIENTENCODING=UTF8
--        psql -U postgres -f 智慧医院挂号系统_数据库脚本.sql
--
--        Windows 中文环境若报 "invalid byte sequence for encoding UTF8"，
--        说明客户端编码没设对，务必先执行上面的 set PGCLIENTENCODING=UTF8。
--
--    【手动】在 psql 交互界面里逐组粘贴执行。
--
--    【注意】不要用"把所有语句包在一个事务里"的方式执行本文件，
--            因为 CREATE DATABASE 不允许出现在事务块中。
--
--  环境
--  ----
--    PostgreSQL 12 及以上（本项目在 PostgreSQL 18.6 上实测通过）。
--    库名、字符集、连接参数见第 0 组。
--
--  与项目其它部分的关系
--  --------------------
--    · 本文件 = 结构 + 对象 + 数据 + 验证命令，是"纯 SQL"的完整版本，
--      适合交作业、答辩演示、以及在没有 Node 环境的机器上重建数据库。
--    · 项目仓库里还有 server/init-db.js，它用 JS 按同样的确定性规则
--      批量生成排班与号源，效果与本文件第 12 组等价（结果都是
--      130 条排班 / 1560 个号源时段 / 1885 条挂号记录）。
--      日常开发用 init-db.js 更方便，本文件胜在"不依赖任何运行环境"。
--
--  关于"为什么不建 hospitals 表"
--  ----------------------------
--    本系统面向的是"某一家医院"的挂号业务，医院名称/等级/地址是部署期
--    常量，不存在第二家医院。若仍建一张 hospitals 表，则
--      departments.hospital_id / schedules.hospital_id /
--      appointments.hospital_id 三列会恒为同一个值 'H01'，
--      UNIQUE (hospital_id, name) 也会退化成 UNIQUE (name) ——
--    多出来的一张表、三条外键、一个索引，没有带来任何约束能力，
--    属于典型的"伪 1:N"冗余。因此本设计直接把院区信息放在前端常量
--    （js/utils.js 的 HOSPITAL）里，数据库只保留真正会变化的主体。
--    详见报告第 3 章"概念结构设计"的论述。
--
-- ============================================================================


-- ============================================================================
--  第 0 组：连接与建库
-- ============================================================================

-- 0.1 用超级用户连上 PostgreSQL（在命令行执行，不是 SQL 语句）
--       psql -U postgres
--     或者指定主机与端口：
--       psql -h 127.0.0.1 -p 5432 -U postgres

-- 0.2 创建数据库
--     ENCODING 'UTF8' 是必须的：本系统要存中文（科室名、医生姓名、就诊人姓名）。
--     若数据库已存在，这一句会报 "database already exists"，
--     属正常情况，跳过即可（后面各组是幂等的，可以放心重跑）。
CREATE DATABASE hospital_registration ENCODING 'UTF8';

-- 0.3 切换到刚创建的数据库
--     ★ 这一句是 psql 的元命令，必须执行，否则后面的建表语句
--       会全部落在 postgres 库里（而不是 hospital_registration）。
--       用 pgAdmin 的查询工具时元命令不支持，请改为在左侧对象树里
--       双击 hospital_registration 库切换，或直接删掉这一行。
\c hospital_registration

-- 0.4 确认当前连的库和字符集对不对
--     期望输出：当前数据库 = hospital_registration，字符集 = UTF8
--     注意 pg_encoding_to_char 需要传入 pg_database.encoding 列，
--     所以必须带 FROM 子句，不能直接 SELECT 常量。
SELECT d.datname                        AS "当前数据库",
       pg_encoding_to_char(d.encoding)  AS "字符集",
       current_user                     AS "当前用户",
       version()                        AS "版本"
  FROM pg_database d
 WHERE d.datname = current_database();


-- ============================================================================
--  第 1 组：幂等清理（按依赖倒序删，可反复执行）
-- ============================================================================
--
--  为什么需要这一组？
--    建表语句里用了 CREATE TABLE（不是 IF NOT EXISTS），重复执行会报错。
--    先删干净再建，整个脚本就变成"幂等"的 —— 跑多少遍结果都一样，
--    这正是数据库脚本应当具备的性质。
--
--  关于 CASCADE：
--    删除主表时会自动连带删除依赖它的对象（外键、视图、触发器）。
--    因此下面不需要单独写 DROP VIEW / DROP TRIGGER，
--    删掉 appointments / schedules 时它们会被一起清掉。
--
--  删除顺序必须是"子表 → 父表"（依赖倒序）：
--    user_sessions → users
--    appointments → schedule_slots → schedules → doctors → departments
-- ============================================================================

DROP TABLE IF EXISTS user_sessions    CASCADE;   -- 登录会话（依赖 users）
DROP TABLE IF EXISTS users            CASCADE;   -- 后台账号
DROP TABLE IF EXISTS appointments     CASCADE;   -- 挂号记录（最下游）
DROP TABLE IF EXISTS appointment_audit CASCADE;  -- 挂号审计日志（触发器写入）
DROP TABLE IF EXISTS schedule_slots   CASCADE;   -- 号源时段
DROP TABLE IF EXISTS schedules        CASCADE;   -- 排班
DROP TABLE IF EXISTS doctors          CASCADE;   -- 医生
DROP TABLE IF EXISTS departments      CASCADE;   -- 科室

-- hospitals 表已从本设计中移除（理由见文件头）。这里仍保留一句 DROP：
-- 从"改造前"的旧库升级上来时，旧 hospitals 表不会被上面的语句清掉，
-- 会留下一个孤立的空表混进第 15 组的对象清单统计里。显式删掉才彻底。
DROP TABLE IF EXISTS hospitals        CASCADE;

DROP SEQUENCE IF EXISTS appointment_no_seq;

-- 函数与存储过程不依赖表，需要单独删除。
-- 注意：必须放在上面 DROP TABLE 之后 —— 因为触发器依赖触发器函数，
-- 而触发器是随表一起被 CASCADE 删掉的，表删完函数才能删。
DROP FUNCTION  IF EXISTS fn_appointment_audit();
DROP FUNCTION  IF EXISTS fn_doctor_remain(VARCHAR);
DROP FUNCTION  IF EXISTS fn_dept_daily_stats(DATE);
DROP PROCEDURE IF EXISTS sp_archive_past_appointments();


-- ============================================================================
--  第 2 组：建表（7 张业务表，另有 1 张审计表在第 6 组）
-- ============================================================================
--
--  实体关系总览（→ 表示"一对多"，外键指向父表）：
--
--      departments ──→ doctors ──→ schedules ──→ schedule_slots
--           │              │            │              │
--           └──────────────┴────────────┴──────────────┴──→ appointments
--
--      users ──→ user_sessions
--
--  两张"字典表"（departments / doctors）描述主数据；
--  两张"业务表"（schedules / schedule_slots）描述号源供给；
--  一张"单据表"（appointments）描述挂号这一业务动作的结果；
--  两张"安全表"（users / user_sessions）支撑管理后台的登录与鉴权；
--  一张"日志表"（appointment_audit）由触发器自动维护，用于追溯。
--
--  完整性约束在本项目中分四类落地：
--    实体完整性 → PRIMARY KEY
--    参照完整性 → FOREIGN KEY（含 ON DELETE CASCADE）
--    用户定义完整性 → CHECK / UNIQUE / NOT NULL
--    业务规则完整性 → 部分唯一索引（见第 3 组）+ 应用层事务
-- ============================================================================

-- ------------------------------------------------------------
-- 2.1 科室表 departments
--     uq_dept_name：科室名不允许重复。
--     改造前这里是 UNIQUE (hospital_id, name) —— 因为 hospital_id 恒为
--     'H01'，那个组合唯一约束实际上等价于本约束，去掉冗余列后语义更直白。
-- ------------------------------------------------------------
CREATE TABLE departments (
  id          VARCHAR(8)   PRIMARY KEY,             -- 科室编号，如 D01
  name        VARCHAR(50)  NOT NULL,                -- 科室名称
  icon        VARCHAR(16)  NOT NULL,                -- 图标（emoji）
  description VARCHAR(200) NOT NULL,                -- 科室简介
  CONSTRAINT uq_dept_name UNIQUE (name)
);
COMMENT ON COLUMN departments.icon IS '前端展示用 emoji，直接存字符，不存图片路径';


-- ------------------------------------------------------------
-- 2.2 医生表 doctors
--     ck_doctor_title：职称只能取三个值 —— 这是典型的"枚举用 CHECK 表达"，
--     比另建一张职称字典表更轻，且对三值以内的场景足够。
--     ck_doctor_fee_tier：挂号费必须与职称匹配（跨列 CHECK）。
--     这里刻意不写 CHECK (fee >= 0)：那种单列"域约束"只能挡住负数，
--     挡不住"主任医师 50 元被改成 1 元"——1 是合法数字，但不是合法价格。
--     真正的业务规则是"价格按职称分档"，把规则如实写成约束才拦得住。
--     rating / cases 仍用普通范围 CHECK。
-- ------------------------------------------------------------
CREATE TABLE doctors (
  id      VARCHAR(8)   PRIMARY KEY,                 -- 医生编号，如 DR01
  dept_id VARCHAR(8)   NOT NULL
          REFERENCES departments(id) ON DELETE CASCADE,
  name    VARCHAR(50)  NOT NULL,                    -- 姓名
  title   VARCHAR(20)  NOT NULL,                    -- 职称
  fee     NUMERIC(8,2) NOT NULL,                    -- 挂号费（元），取值见 ck_doctor_fee_tier
  good_at VARCHAR(200) NOT NULL,                    -- 擅长方向
  rating  NUMERIC(2,1) NOT NULL CHECK (rating >= 0 AND rating <= 5),
  cases   INTEGER      NOT NULL DEFAULT 0 CHECK (cases >= 0),
  CONSTRAINT ck_doctor_title CHECK (title IN ('主任医师','副主任医师','主治医师')),
  -- 价格档位：主任医师 50 / 副主任医师 30 / 主治医师 15。
  -- 由于 ck_doctor_title 已把 title 限死在三个值上，这条约束同时蕴含了 fee >= 0。
  -- 效果：UPDATE doctors SET fee = 1 WHERE id = 'DR01' 会被直接拒绝，
  --       因为不存在"主任医师 且 fee = 1"这一档。
  CONSTRAINT ck_doctor_fee_tier CHECK (
    (title = '主任医师'   AND fee = 50.00) OR
    (title = '副主任医师' AND fee = 30.00) OR
    (title = '主治医师'   AND fee = 15.00)
  )
);
COMMENT ON COLUMN doctors.rating IS '评分 0.0~5.0，NUMERIC(2,1) 只占 1 位小数';
COMMENT ON COLUMN doctors.cases  IS '累计接诊量，展示用，非实时统计';
COMMENT ON COLUMN doctors.fee
  IS '挂号费，按职称分档（主任医师 50 / 副主任医师 30 / 主治医师 15），由 ck_doctor_fee_tier 强制';


-- ------------------------------------------------------------
-- 2.3 排班表 schedules
--     一条记录 = "某位医生某一天出诊"。
--     uq_schedule_doctor_date 是幂等生成排班的关键：
--     脚本可以反复跑，已存在的（医生, 日期）组合会被唯一约束挡住，
--     不会生成重复排班。
--     closed 是"停诊"开关：置为 TRUE 表示该医生当天停诊，
--     应用层会把该排班下所有有效挂号联动改为"已停诊"并释放号源。
-- ------------------------------------------------------------
CREATE TABLE schedules (
  id        VARCHAR(32) PRIMARY KEY,                -- 排班编号，格式 SC_医生编号_日期
  doctor_id VARCHAR(8)  NOT NULL
            REFERENCES doctors(id)     ON DELETE CASCADE,
  dept_id   VARCHAR(8)  NOT NULL
            REFERENCES departments(id),
  work_date DATE        NOT NULL,                   -- 出诊日期
  weekday   VARCHAR(8)  NOT NULL,                   -- 星期几（中文，冗余但便于直接展示）
  closed    BOOLEAN     NOT NULL DEFAULT FALSE,     -- 是否停诊
  CONSTRAINT uq_schedule_doctor_date UNIQUE (doctor_id, work_date)
);
COMMENT ON COLUMN schedules.weekday IS '中文星期，冗余字段：避免每次展示都做日期函数换算';


-- ------------------------------------------------------------
-- 2.4 号源时段表 schedule_slots  ★ 全系统的核心表
--
--     粒度：一条排班 × 一个 30 分钟时段 = 一行，共 12 行/排班
--           （上午 S1~S6 共 08:00-11:00，下午 S7~S12 共 14:00-17:00）
--
--     total  = 该时段放出的号源总数（管理端可调）
--     booked = 该时段已被占用的号源数
--
--     ★ ck_slot_not_oversold (booked <= total) 是"防超卖的最后一道防线"：
--       应用层虽然用事务 + 行锁保证不超卖，但只要有任何人绕过应用
--       直接改库（手工 UPDATE、写错脚本、并发 bug），
--       这个 CHECK 会在数据库层面直接拒绝写入。
--       这就是把业务规则下沉到数据库的价值 —— 约束是"无法绕过"的。
--
--     ★ uq_slot_schedule (schedule_id, slot_id)：同一条排班内时段编号唯一，
--       防止脚本重复插入把号源翻倍。
--
--     注意：前端患者端现在只展示"上午/下午"两个大段，
--     但号源仍然按 30 分钟一格存储 —— 因为"格"才是并发扣减的最小单位，
--     也是管理端调号源的操作单位。展示层聚合，存储层精确。
-- ------------------------------------------------------------
CREATE TABLE schedule_slots (
  id          SERIAL      PRIMARY KEY,              -- 代理主键
  schedule_id VARCHAR(32) NOT NULL
              REFERENCES schedules(id) ON DELETE CASCADE,
  slot_id     VARCHAR(8)  NOT NULL,                 -- 时段编号 S1~S12
  label       VARCHAR(20) NOT NULL,                 -- 时段名称，如 08:00-08:30
  period      VARCHAR(8)  NOT NULL,                 -- 午别：上午 / 下午
  total       INTEGER     NOT NULL CHECK (total >= 0),   -- 号源总数
  booked      INTEGER     NOT NULL DEFAULT 0 CHECK (booked >= 0), -- 已占号源
  CONSTRAINT uq_slot_schedule     UNIQUE (schedule_id, slot_id),
  CONSTRAINT ck_slot_not_oversold CHECK (booked <= total),
  CONSTRAINT ck_slot_period       CHECK (period IN ('上午','下午'))
);
COMMENT ON COLUMN schedule_slots.booked IS '必须恒等于该时段 status=active 的挂号数，见第 12.5 组的回填';
COMMENT ON CONSTRAINT ck_slot_not_oversold ON schedule_slots IS '数据库层防超卖，绕过应用也改不坏';


-- ------------------------------------------------------------
-- 2.5 挂号流水号序列 appointment_no_seq
--     挂号单号形如 A1000、A1001……
--     "A" + nextval 拼出来，比 max(id)+1 安全：并发下不会取到同一个号。
-- ------------------------------------------------------------
CREATE SEQUENCE appointment_no_seq START 1000;
COMMENT ON SEQUENCE appointment_no_seq IS '挂号单号流水，应用侧拼成 A + 序号';


-- ------------------------------------------------------------
-- 2.6 挂号记录表 appointments  ★ 核心业务表
--
--     这张表同时承担两个角色：
--       (1) 业务单据 —— 记录"谁在什么时候挂了哪个号"；
--       (2) m:n 联系的落地 —— "患者 ↔ 号源时段"之间的"预约"联系，
--           因为带业务属性（取号序号、费用、状态），被升格为独立实体。
--
--     设计要点一：业务唯一键
--       身份证号 + 医生编号 + 就诊日期 构成业务唯一键（见第 3 组的
--       uq_appt_same_doctor 部分唯一索引），保证同一人同一天同一医生
--       只能有一个有效号。
--
--     设计要点二：有意的冗余（反规范化）
--       dept_id / doctor_id / work_date / weekday /
--       slot_label / period / fee 这些字段理论上都能通过
--       schedule_id + slot_id 推导出来，这里故意再存一份。原因：
--         · 挂号单是"凭证"，一旦生成就不应随后续排班调整而改变
--           （比如号源被改、医生调价、排班被删，历史单据必须保持原样）；
--         · 查询"我的挂号""挂号记录列表"时不必反复 JOIN 四张表，
--           读性能更好。
--       这正是 3NF 允许的"为了性能与历史可追溯性而有意保留的冗余"，
--       报告第 3 章有专门论述。
--
--     设计要点三：状态机
--       active（待就诊）→ cancelled（已取消）/ closed（已停诊）
--       用 CHECK 把状态限定为三个取值，杜绝脏状态。
-- ------------------------------------------------------------
CREATE TABLE appointments (
  id           VARCHAR(16)  PRIMARY KEY,            -- 挂号单号 A1000
  seq_no       INTEGER      NOT NULL CHECK (seq_no > 0),  -- 该时段内的取号序号
  schedule_id  VARCHAR(32)  NOT NULL
               REFERENCES schedules(id),
  slot_id      VARCHAR(8)   NOT NULL,               -- 时段编号（与 schedule_id 联合定位号源）
  dept_id      VARCHAR(8)   NOT NULL
               REFERENCES departments(id),
  doctor_id    VARCHAR(8)   NOT NULL
               REFERENCES doctors(id),
  work_date    DATE         NOT NULL,               -- 就诊日期
  weekday      VARCHAR(8)   NOT NULL,               -- 中文星期
  slot_label   VARCHAR(20)  NOT NULL,               -- 时段名称快照
  period       VARCHAR(8)   NOT NULL,               -- 午别快照
  patient_name VARCHAR(50)  NOT NULL,               -- 就诊人姓名
  id_card      VARCHAR(18)  NOT NULL,               -- 身份证号
  phone        VARCHAR(11)  NOT NULL,               -- 手机号
  fee          NUMERIC(8,2) NOT NULL CHECK (fee >= 0),   -- 挂号费快照（下单时抄自 doctors.fee）
  status       VARCHAR(12)  NOT NULL DEFAULT 'active',   -- 状态
  close_note   VARCHAR(200),                        -- 停诊说明 / 归档原因
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(), -- 下单时间
  cancelled_at TIMESTAMPTZ,                         -- 取消时间
  CONSTRAINT ck_appt_status CHECK (status IN ('active','cancelled','closed')),
  -- 用户定义完整性：格式级校验下沉到数据库，应用层校验被绕过也拦得住
  CONSTRAINT ck_appt_idcard CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_appt_phone  CHECK (phone  ~ '^1[3-9][0-9]{9}$')
);
COMMENT ON COLUMN appointments.seq_no    IS '取号序号：同一排班同一时段内从 1 递增，退号后由应用层重排不留空号';
COMMENT ON COLUMN appointments.id_card   IS '18 位身份证，CHECK 只做格式校验；校验位算法在应用层（GB 11643-1999）';
COMMENT ON COLUMN appointments.close_note IS '停诊原因或归档说明，仅 closed/cancelled 时有值';
COMMENT ON COLUMN appointments.fee
  IS '挂号费快照：下单时从 doctors.fee 抄入，属历史事实；由 trg_appointment_audit 禁止 UPDATE';


-- ------------------------------------------------------------
-- 2.7 后台用户表 users
--     对应任务书要求 4「用户登录功能（根据对用户表的访问实现）」。
--
--     ★ 密码不存明文，存的是 scrypt 派生出的口令散列，格式：
--           scrypt$<salt-hex>$<hash-hex>
--       · salt 是每个账号独立生成的 16 字节随机盐，
--         这样即使两个账号用同一个口令，散列值也完全不同，
--         无法用"彩虹表"批量反查；
--       · scrypt 是内存硬（memory-hard）算法，攻击者想暴力枚举
--         必须付出大量内存与时间，比 MD5/SHA 系列抗爆破强得多；
--       · 校验在应用层用 crypto.timingSafeEqual 做定长比较，
--         避免"比较提前返回"泄露口令前缀（时序侧信道）。
--
--     ★ role 区分「管理员 admin」与「值班员 staff」：
--       管理端里"重置数据""调整号源""停诊"等破坏性操作只允许 admin，
--       值机台人员用 staff 账号，做到最小权限。
--
--     ★ status 而不是直接删行：账号要能"停用"而不是"消失"，
--       因为历史操作日志还要引用这个操作者。
-- ------------------------------------------------------------
CREATE TABLE users (
  id            VARCHAR(16)  PRIMARY KEY,           -- 账号编号，如 U01
  username      VARCHAR(32)  NOT NULL,              -- 登录名
  password_hash VARCHAR(200) NOT NULL,              -- scrypt 散列，绝不存明文
  display_name  VARCHAR(50)  NOT NULL,              -- 显示名（如"张明"）
  role          VARCHAR(16)  NOT NULL DEFAULT 'staff',   -- 角色
  status        VARCHAR(12)  NOT NULL DEFAULT 'active',  -- 账号状态
  last_login_at TIMESTAMPTZ,                        -- 最近一次登录成功时间
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_users_username UNIQUE (username),
  -- 用户定义完整性：登录名只允许字母/数字/下划线，长度 3~32
  CONSTRAINT ck_users_username CHECK (username ~ '^[A-Za-z0-9_]{3,32}$'),
  CONSTRAINT ck_users_role     CHECK (role IN ('admin','staff')),
  CONSTRAINT ck_users_status   CHECK (status IN ('active','disabled'))
);
COMMENT ON COLUMN users.password_hash IS 'scrypt$盐$散列；明文口令不落库，校验用定长比较防时序侧信道';
COMMENT ON COLUMN users.status        IS 'disabled 表示停用；不物理删除账号，历史操作日志仍需引用';


-- ------------------------------------------------------------
-- 2.8 登录会话表 user_sessions
--
--     ★ 为什么用"落库的会话令牌"而不是 JWT？
--       令牌存进数据库后，服务端才真正掌握"这个会话还在不在"：
--         · 注销 = 删掉这一行，立即失效（JWT 只能等它自己过期）；
--         · 管理员可以把某个账号的全部会话清掉，实现"强制下线"；
--         · 会话本身成为可查询的数据，"谁在什么时候登录过"能审计。
--       代价是每次请求多一次主键查询 —— 对本系统的量级完全可接受。
--
--     ★ token 直接存明文而不做散列，与口令的处理不同，原因是：
--       口令是"人选的低熵秘密"，必须用慢哈希抗爆破；
--       而 token 是 crypto.randomBytes(32) 生成的 256 位随机值，
--       本身就是高熵、不可枚举的，散列存储换不来额外的安全性。
--
--     ★ ck_session_expiry 保证过期时间一定晚于创建时间，
--       防止写错参数造出"一出生就过期"的僵尸会话。
--       过期会话由应用层在登录时顺带清理，不需要定时任务。
-- ------------------------------------------------------------
CREATE TABLE user_sessions (
  token      VARCHAR(64) PRIMARY KEY,               -- 64 位十六进制随机令牌
  user_id    VARCHAR(16) NOT NULL
             REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT ck_session_expiry CHECK (expires_at > created_at)
);
COMMENT ON TABLE user_sessions IS '服务端会话：注销/踢下线靠删行实现，比 JWT 更可控';
COMMENT ON COLUMN user_sessions.token IS '32 字节随机数转十六进制；本身高熵，故明文存储';


-- ============================================================================
--  第 3 组：建索引
-- ============================================================================
--
--  两类索引，作用完全不同：
--
--  【A】普通索引 —— 为查询性能服务
--        外键列建索引的原因：PostgreSQL 不会自动为外键建索引，
--        而没有索引的外键在做级联删除（ON DELETE CASCADE）时，
--        会对子表做全表扫描，数据量一大就非常慢。
--
--  【B】部分唯一索引（Partial Unique Index）★ —— 为业务规则服务
--        这类索引既保证唯一性，又通过 WHERE 子句只约束"部分行"。
--        为什么要 WHERE status='active'？
--        因为"同一人同一天同一医生不能重复挂号"这条规则，
--        只对"有效号"成立：一个人完全可以挂一个号、取消掉、再挂一次。
--        如果直接对 (id_card, doctor_id, work_date) 建全局唯一索引，
--        取消后重挂就会被拦死 —— 这就是部分唯一索引的用武之地，
--        它比在应用层写 SELECT 查重更可靠（数据库层杜绝并发穿透）。
-- ============================================================================

-- 【A】外键列索引
CREATE INDEX idx_doctors_dept     ON doctors(dept_id);
CREATE INDEX idx_schedules_date   ON schedules(work_date);
CREATE INDEX idx_schedules_doctor ON schedules(doctor_id);
CREATE INDEX idx_slots_schedule   ON schedule_slots(schedule_id);

-- 【A】挂号表的高频查询条件索引
CREATE INDEX idx_appt_status  ON appointments(status);              -- 按状态筛选
CREATE INDEX idx_appt_created ON appointments(created_at DESC);     -- 按时间倒序取最新
CREATE INDEX idx_appt_date    ON appointments(work_date);           -- 按就诊日期
CREATE INDEX idx_appt_doctor  ON appointments(doctor_id);           -- 按医生统计工作量
CREATE INDEX idx_appt_dept    ON appointments(dept_id);             -- 按科室统计挂号量

-- 【A】账号与会话的检索索引
--     role：管理端"只看管理员账号"的筛选；数据量虽小，语义清晰。
--     user_id：级联删除时按用户找会话（与 idx_doctors_dept 同理）。
--     expires_at：清理过期会话时按时间范围扫描。
CREATE INDEX idx_users_role       ON users(role);
CREATE INDEX idx_sessions_user    ON user_sessions(user_id);
CREATE INDEX idx_sessions_expires ON user_sessions(expires_at);

-- 【B】冲突校验：同一就诊人、同一天、同一科室只能有一个有效号
--      （即"当天在同一科室不能重复挂号"，换医生也算重复）
CREATE INDEX idx_appt_conflict
  ON appointments(id_card, work_date, dept_id)
  WHERE status = 'active';

-- 【B】同一就诊人、同一天、同一医生只能有一个有效号（部分唯一索引）
CREATE UNIQUE INDEX uq_appt_same_doctor
  ON appointments(id_card, doctor_id, work_date)
  WHERE status = 'active';
COMMENT ON INDEX uq_appt_same_doctor IS '防重复挂号的核心：只约束 active 行，取消后可重挂';


-- ============================================================================
--  第 4 组：视图一 —— 排班号源使用情况 v_schedule_usage
-- ============================================================================
--
--  解决的问题：管理端"排班号源"页面要展示每条排班的
--              总号源 / 已占 / 剩余三个汇总值。
--              若不建视图，应用层每次都得写一遍三表聚合，
--              既啰嗦又容易写错（比如漏了 LEFT JOIN 导致
--              没有时段的排班整条消失）。
--
--  关键点：必须用 LEFT JOIN 而不是 INNER JOIN。
--          没有号源时段的排班也要出现在结果里（显示 0），
--          否则管理端会"看不到"这条排班。
--
--  知识点：COALESCE + 强制类型转换 ::INT
--          聚合函数在无匹配行时返回 NULL，COALESCE 兜底成 0；
--          SUM 返回的是 NUMERIC/BIGINT，转成 INT 便于前端直接当数字用。
-- ============================================================================

CREATE OR REPLACE VIEW v_schedule_usage AS
SELECT
  s.id            AS schedule_id,
  s.doctor_id,
  s.dept_id,
  s.work_date,
  s.closed,
  COALESCE(SUM(sl.total), 0)::INT                                  AS total_quota,
  COALESCE(SUM(sl.booked), 0)::INT                                 AS booked_quota,
  (COALESCE(SUM(sl.total), 0) - COALESCE(SUM(sl.booked), 0))::INT  AS remain_quota
FROM schedules s
LEFT JOIN schedule_slots sl ON sl.schedule_id = s.id
GROUP BY s.id, s.doctor_id, s.dept_id, s.work_date, s.closed;

COMMENT ON VIEW v_schedule_usage IS '排班号源使用情况：每条排班的总量/已占/剩余';


-- ============================================================================
--  第 5 组：视图二 —— 医生工作量统计 v_doctor_workload
-- ============================================================================
--
--  解决的问题：数据看板要展示"每位医生的有效挂号量与收入"。
--
--  关键点一：COUNT(...) FILTER (WHERE ...)
--            这是 PostgreSQL 的聚合过滤语法，等价于
--              COUNT(CASE WHEN a.status='active' THEN a.id END)
--            但可读性好得多。用它实现"只统计有效号"，
--            同时因为用了 LEFT JOIN，没有挂号的医生也会出现在结果里
--            （挂号量为 0），而不是被过滤掉。
--
--  关键点二：为什么不能用 WHERE a.status='active'？
--            那样会把 LEFT JOIN 退化成 INNER JOIN，
--            没有挂号的医生整行消失，看板上就少人了。
--            "过滤条件放在 ON 里还是 WHERE 里"是 SQL 的经典陷阱：
--            放在 ON 里保留左表全部行，放在 WHERE 里会过滤掉左表行。
-- ============================================================================

CREATE OR REPLACE VIEW v_doctor_workload AS
SELECT
  d.id                AS doctor_id,
  d.name              AS doctor_name,
  d.title,
  dp.name             AS dept_name,
  COUNT(a.id) FILTER (WHERE a.status = 'active')::INT
                      AS active_count,
  COALESCE(SUM(a.fee) FILTER (WHERE a.status = 'active'), 0)::NUMERIC(12,2)
                      AS revenue
FROM doctors d
JOIN departments dp ON dp.id = d.dept_id
LEFT JOIN appointments a ON a.doctor_id = d.id
GROUP BY d.id, d.name, d.title, dp.name;

COMMENT ON VIEW v_doctor_workload IS '医生工作量：有效挂号量 + 有效挂号收入';


-- ============================================================================
--  第 6 组：挂号审计日志表 appointment_audit
-- ============================================================================
--
--  为什么需要它？
--    挂号状态的变化（新建、取消、停诊）是有业务含义的关键事件。
--    应用层的日志只能记录"请求"，记不下"数据到底变没变"。
--    把留痕交给数据库触发器，好处是：
--      · 无论从哪个入口改（应用、手工 SQL、别的脚本）都会留痕；
--      · 应用层代码漏写日志也不会丢审计。
--
--  字段设计：
--    old_status / new_status 记录状态迁移的"从哪到哪"；
--    changed_by 记录"是谁改的"（见下面的 DEFAULT 说明）；
--    changed_at 记录时间。
--
--  ★ changed_by 的取值顺序（配合登录功能做的增强）：
--      1) 优先取应用层在事务里设置的 app.actor —— 即"登录用户名"。
--         应用层执行 withTransaction 时会先跑
--             SELECT set_config('app.actor', <用户名>, TRUE)
--         第三个参数 TRUE 表示 is_local，只在当前事务内有效，
--         事务结束自动失效，不会污染连接池里的下一个请求。
--      2) 取不到（比如手工执行 SQL、或维护脚本）则退回 CURRENT_USER，
--         也就是数据库连接用户。
--    这样保证"任何路径下都至少有一个操作者留痕"，不会出现空值。
-- ============================================================================

CREATE TABLE appointment_audit (
  audit_id       BIGSERIAL   PRIMARY KEY,           -- 审计流水号（自增）
  appointment_id VARCHAR(16) NOT NULL,              -- 关联的挂号单号
  action         VARCHAR(10) NOT NULL,              -- INSERT / UPDATE
  old_status     VARCHAR(12),                       -- 变更前状态（INSERT 时为 NULL）
  new_status     VARCHAR(12),                       -- 变更后状态
  changed_by     VARCHAR(60) NOT NULL
                 DEFAULT COALESCE(NULLIF(current_setting('app.actor', TRUE), ''), CURRENT_USER),
  changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_appointment ON appointment_audit(appointment_id);
CREATE INDEX idx_audit_time        ON appointment_audit(changed_at DESC);

COMMENT ON TABLE appointment_audit IS '挂号状态变更留痕，由 trg_appointment_audit 自动写入';
COMMENT ON COLUMN appointment_audit.changed_by
  IS '优先取事务内 app.actor（登录用户名），取不到退回数据库连接用户';


-- ============================================================================
--  第 7 组：触发器函数 + 触发器
-- ============================================================================
--
--  触发器的工作方式：把"要做什么"写在触发器函数里（PL/pgSQL），
--  再用 CREATE TRIGGER 把函数挂到表的 INSERT / UPDATE 事件上。
--
--  函数返回 TRIGGER 表示它是触发器函数；
--    · BEFORE 触发器必须 RETURN NEW 才会真正写入（返回 NULL 会取消本次操作）；
--    · 用 TG_OP 区分当前是 INSERT 还是 UPDATE。
--
--  为什么时机是 BEFORE 而不是 AFTER？
--    本触发器除了留痕，还兼任「守卫」：要拒绝修改挂号费快照。
--    守卫必须"在改动生效之前"拦下来，所以用 BEFORE。
--
--  关键细节一：IF NEW.fee IS DISTINCT FROM OLD.fee THEN RAISE EXCEPTION
--    这是 CHECK 约束做不到的事。CHECK 只能看到"新行的值"，看不到"旧值"，
--    因此它无法判断"这次改动该不该发生"。
--    例：fee NUMERIC(8,2) CHECK (fee >= 0) 只保证非负，
--    把主任医师的 50 元改成 1 元照样通过 —— 1 是合法数字，但不是合法价格。
--    要比较 OLD / NEW，只能用触发器（或用跨列 CHECK 把规则写成"fee 必须匹配职称"）。
--
--  关键细节二：IF OLD.status IS DISTINCT FROM NEW.status
--    只在状态"真的变了"时才写日志。如果不加这个判断，
--    任何一次 UPDATE（哪怕只改了手机号）都会产生一条无意义的审计记录。
--    IS DISTINCT FROM 而不是 <> 的原因：它把 NULL 当成普通值比较，
--    不会因为 NULL 参与运算而返回 NULL（NULL 在 IF 里会被当成 false）。
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_appointment_audit() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- 新建挂号：记一条 INSERT，变更前状态为 NULL
    INSERT INTO appointment_audit (appointment_id, action, new_status)
    VALUES (NEW.id, 'INSERT', NEW.status);
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    -- 【守卫】挂号费是下单那一刻从 doctors.fee 抄来的价格快照，
    -- 是历史事实，不是可编辑字段；它还参与收入统计 SUM(fee)。
    -- 一旦被改，报表数字会跟着错，所以这里硬性禁止修改。
    -- 报错码用 check_violation（23514），语义上与"违反约束"一致。
    IF NEW.fee IS DISTINCT FROM OLD.fee THEN
      RAISE EXCEPTION
        '挂号单 % 的挂号费为历史快照，不允许修改（原值 %，试图改为 %）；如需调价请修改 doctors.fee',
        OLD.id, OLD.fee, NEW.fee
        USING ERRCODE = 'check_violation';
    END IF;

    -- 【留痕】仅当状态发生变化时才写日志，避免噪音
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      INSERT INTO appointment_audit (appointment_id, action, old_status, new_status)
      VALUES (NEW.id, 'UPDATE', OLD.status, NEW.status);
    END IF;
    RETURN NEW;
  END IF;

  RETURN NULL;   -- DELETE 不记录（本项目退号是逻辑删除，走 UPDATE）
END;
$$ LANGUAGE plpgsql;

-- 幂等：先删再建（上面第 1 组删表时其实已连带删掉，这里再保险一次）
DROP TRIGGER IF EXISTS trg_appointment_audit ON appointments;

CREATE TRIGGER trg_appointment_audit
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION fn_appointment_audit();

COMMENT ON FUNCTION fn_appointment_audit()
  IS '挂号状态变更自动写审计日志；同时守卫挂号费快照不可修改';


-- ============================================================================
--  第 8 组：函数一 —— 查询某医生的剩余号源 fn_doctor_remain
-- ============================================================================
--
--  用途：医生列表页要显示"该医生近 7 天还有多少号"。
--
--  为什么封装成函数而不是让应用写 SQL？
--    · 这段聚合逻辑被多处复用（医生列表、医生详情、首页统计）；
--    · 把"什么算可约号源"这个口径收敛到一处：
--      未停诊 + 就诊日期 >= 今天 + total-booked 求和。
--      哪天口径要改（比如只算未来 3 天），只改函数即可。
--
--  知识点：STABLE
--    声明函数在"同一条 SQL 语句内"对同样的输入返回同样的结果
--    （不写库，只读）。让查询优化器可以放心地缓存/内联，
--    比默认的 VOLATILE 快得多。只读函数应当标 STABLE。
--
--  知识点：SELECT ... INTO 变量
--    PL/pgSQL 里把查询结果赋给变量的写法。
--    COALESCE 兜底：医生一条排班都没有时 SUM 返回 NULL，转成 0。
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_doctor_remain(p_doctor_id VARCHAR)
RETURNS INTEGER AS $$
DECLARE
  v_remain INTEGER;
BEGIN
  SELECT COALESCE(SUM(sl.total - sl.booked), 0)::INT
    INTO v_remain
    FROM schedules s
    JOIN schedule_slots sl ON sl.schedule_id = s.id
   WHERE s.doctor_id = p_doctor_id
     AND s.closed = FALSE                -- 停诊的排班不算
     AND s.work_date >= CURRENT_DATE;    -- 只算今天及以后
  RETURN v_remain;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION fn_doctor_remain(VARCHAR) IS '查某医生今天及以后的可约号源总数';


-- ============================================================================
--  第 9 组：函数二 —— 按科室统计某日挂号情况 fn_dept_daily_stats
-- ============================================================================
--
--  用途：报表统计。输入一个日期，输出当天各科室的
--        接诊医生数、挂号量、挂号收入。
--
--  知识点一：RETURNS TABLE
--    返回"一张表"（多行多列）而不是单个值。
--    函数体里用 RETURN QUERY 把一条 SELECT 的结果直接作为返回值，
--    这是报表类函数最常见的写法 —— 调用时可以直接
--        SELECT * FROM fn_dept_daily_stats(CURRENT_DATE);
--    当普通表用，甚至可以再 JOIN、再 WHERE。
--
--  知识点二：为什么用 LEFT JOIN + HAVING COUNT(a.id) > 0
--    用 LEFT JOIN 保证"所有科室"都参与分组，再用 HAVING 过滤掉
--    当天没有挂号的科室。这样写比 WHERE 更清晰：
--    过滤发生在聚合之后（HAVING），语义是"挂号量为 0 的科室不显示"。
--
--  知识点三：::VARCHAR 强制转换
--    RETURNS TABLE 里声明的是 VARCHAR，而 dp.id 等列本身类型不同，
--    显式转换可避免"返回类型不匹配"的报错。
--
--  ★ 知识点四：为什么这里要先 DROP FUNCTION
--    "改了返回列"属于「返回值类型变更」，CREATE OR REPLACE 只允许
--    修改函数体，不允许改返回结构，直接执行会报
--        ERROR: cannot change return type of existing function
--    所以必须先 DROP 再 CREATE。
--    （改造前本函数还有一列 hospital_name，去掉 hospitals 表后随之删除。）
-- ============================================================================

DROP FUNCTION IF EXISTS fn_dept_daily_stats(DATE);

CREATE FUNCTION fn_dept_daily_stats(p_date DATE)
RETURNS TABLE (
  dept_id      VARCHAR,
  dept_name    VARCHAR,
  doctor_count INT,
  appt_count   INT,
  revenue      NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    dp.id::VARCHAR,
    dp.name::VARCHAR,
    COUNT(DISTINCT a.doctor_id)::INT,   -- 当天有挂号的医生数（去重）
    COUNT(a.id)::INT,                   -- 挂号量
    COALESCE(SUM(a.fee), 0)::NUMERIC    -- 挂号收入
  FROM departments dp
  LEFT JOIN appointments a
         ON a.dept_id = dp.id
        AND a.work_date = p_date        -- 注意：过滤条件写在 ON 里
        AND a.status = 'active'
  GROUP BY dp.id, dp.name
  HAVING COUNT(a.id) > 0                -- 过滤发生在聚合之后
  -- 挂号量从高到低。追加 dp.id 作次序键：挂号量相同的科室（如儿科与外科
  -- 都是 75 条）若只按 COUNT 排序，PostgreSQL 不保证稳定顺序，
  -- 同一份数据两次执行可能给出不同行序，报告里的截图就对不上了。
  ORDER BY COUNT(a.id) DESC, dp.id;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION fn_dept_daily_stats(DATE) IS '报表函数：按科室统计某日挂号量、医生数与收入';


-- ============================================================================
--  第 10 组：存储过程 —— 归档过期挂号 sp_archive_past_appointments
-- ============================================================================
--
--  用途：维护任务。把"就诊日期已过、却还挂在 active 状态"的记录
--        归档掉（改成 cancelled），并把它们占用的号源还回去。
--
--  函数 vs 存储过程的区别（本组正好体现）：
--    函数用 SELECT 调用、必须有返回值、不能控制事务；
--    存储过程用 CALL 调用、可以不返回值、可以在内部 COMMIT。
--    这里的活儿是"改数据、不返回结果集"，所以用存储过程。
--
--  执行顺序很重要 —— 必须先还号源、再改状态：
--    如果反过来，先把 active 改成 cancelled，
--    后面的"按 active 汇总需要回退的数量"就查不到任何行了，
--    号源永远还不回去（永久泄漏）。
--
--  知识点一：UPDATE ... FROM (子查询)
--    用一条 SQL 完成"按排班+时段汇总后批量回退号源"。
--    先在子查询里把需要回退的数量算出来（cnt），
--    再让 schedule_slots 去 JOIN 这个结果集更新。
--    若用逐行循环，几千条记录会慢得离谱。
--
--  知识点二：GREATEST(sl.booked - sub.cnt, 0)
--    兜底防止出现负数 —— 虽然理论上不会，但维护脚本要能扛住脏数据。
--
--  知识点三：GET DIAGNOSTICS v_count = ROW_COUNT
--    取"上一条 DML 影响了多少行"，用于 RAISE NOTICE 打印执行结果。
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_archive_past_appointments()
LANGUAGE plpgsql AS $$
DECLARE
  v_count INT := 0;
BEGIN
  -- 第 1 步：释放号源（按排班+时段汇总需要回退的数量，一次性批量更新）
  UPDATE schedule_slots sl
     SET booked = GREATEST(sl.booked - sub.cnt, 0)
    FROM (
      SELECT schedule_id, slot_id, COUNT(*)::INT AS cnt
        FROM appointments
       WHERE status = 'active'
         AND work_date < CURRENT_DATE      -- 只处理已过期的
       GROUP BY schedule_id, slot_id
    ) sub
   WHERE sl.schedule_id = sub.schedule_id
     AND sl.slot_id = sub.slot_id;

  -- 第 2 步：把过期记录归档（状态改为 cancelled 并写取消时间与原因）
  UPDATE appointments
     SET status       = 'cancelled',
         cancelled_at = NOW(),
         close_note   = '就诊日期已过，系统自动归档'
   WHERE status = 'active'
     AND work_date < CURRENT_DATE;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '已归档过期挂号 % 条', v_count;
END;
$$;

COMMENT ON PROCEDURE sp_archive_past_appointments() IS '维护过程：归档过期挂号并释放其占用号源';


-- ============================================================================
--  第 11 组：基础数据装载（科室 / 医生 / 后台账号）
-- ============================================================================
--
--  顺序必须是 科室 → 医生，因为外键有依赖；
--  后台账号独立，可放在最后。
--  多行 INSERT 的写法（VALUES (...),(...),(...)）比一条条 INSERT 快得多，
--  也更好读。
-- ============================================================================

-- ------------------------------------------------------------
-- 11.1 科室（5 个）
--      icon 用 emoji 直接存字符（不存图片路径），前端零成本渲染。
-- ------------------------------------------------------------
INSERT INTO departments (id, name, icon, description) VALUES
('D01', '内科', '🫀', '感冒发热、高血压、糖尿病等常见内科疾病'),
('D02', '外科', '🩹', '外伤处理、体表肿物、术后复查'),
('D03', '儿科', '🧒', '0-14 岁儿童常见病、生长发育咨询'),
('D04', '骨科', '🦴', '骨折、关节疼痛、颈腰椎疾病'),
('D05', '眼科', '👁️', '视力检查、结膜炎、白内障筛查');

-- ------------------------------------------------------------
-- 11.2 医生（10 位）
--      fee 按职称定价：主任医师 50 元、副主任医师 30 元、主治医师 15 元。
--      rating / cases 用于展示，便于前端做"好评排序"。
-- ------------------------------------------------------------
INSERT INTO doctors (id, dept_id, name, title, fee, good_at, rating, cases) VALUES
('DR01', 'D01', '张建国', '主任医师',   50, '高血压、冠心病、心律失常',            4.9, 12800),
('DR02', 'D01', '李慧敏', '副主任医师', 30, '糖尿病、甲状腺疾病、内分泌失调',      4.8,  9600),
('DR03', 'D01', '王振宇', '主治医师',   15, '呼吸道感染、胃肠炎、普通内科',        4.7,  5200),
('DR04', 'D02', '陈国强', '主任医师',   50, '普外科手术、胆囊疾病、疝气',          4.8,  8100),
('DR05', 'D02', '刘文博', '主治医师',   15, '外伤清创、体表肿物切除',              4.6,  4300),
('DR06', 'D03', '赵晓萍', '副主任医师', 30, '小儿呼吸道感染、腹泻、过敏',          4.9, 11200),
('DR07', 'D03', '孙宁',   '主治医师',   15, '新生儿黄疸、儿童保健、疫苗接种咨询',  4.7,  6100),
('DR08', 'D04', '周海涛', '主任医师',   50, '关节置换、脊柱微创、复杂骨折',        4.9,  7300),
('DR09', 'D04', '吴磊',   '主治医师',   15, '骨折复位、运动损伤、腰肌劳损',        4.6,  3900),
('DR10', 'D05', '郑晓岚', '副主任医师', 30, '白内障、青光眼、眼底病变',            4.8,  6800);

-- ------------------------------------------------------------
-- 11.3 后台账号（2 个）
--
--      ★ password_hash 是真实可用的 scrypt 散列，不是占位符。
--        下面两串分别对应明文口令 admin123 与 triage123，
--        执行完本脚本后可以直接用它们登录管理后台。
--
--        格式：scrypt$<16 字节盐的十六进制>$<64 字节散列的十六进制>
--        盐是随机生成的，所以每次重新初始化（node server/init-db.js --force）
--        这两串都会变，但对应的明文口令不变、登录结果不变。
--        把散列写进脚本而不是写明文，本身就演示了"库里不存明文"。
--
--      ★ role：admin 可执行重置数据、调号源、停诊等破坏性操作；
--              staff 只能查看与日常值机，做到最小权限。
-- ------------------------------------------------------------
INSERT INTO users (id, username, password_hash, display_name, role, status) VALUES
('U01', 'admin',
 'scrypt$cfab4e7abd596dfb09e7ecd7f23a6600$7ecda01d62d5c71e0bfadbf9df4af3d3ae64e73875067337827c8f4d3c9822492d618d3c3957ebaeec8a23596eb781085fe623f0535391e824a3c1d4300b334f',
 '张明', 'admin', 'active'),
('U02', 'triage',
 'scrypt$28e31b7ba357fe728aef8576ae252b37$14039c0bb773c5b72427a2f05d6b5c476d83af795a3614bcb8fb280be3cdd0cdecb39f5156101e441a77b71c75641aadf545602c3bdd6dcf52511c59897a4a02',
 '李芳', 'staff', 'active');

-- 装载结果自检：应输出 5 / 10 / 2
SELECT (SELECT COUNT(*) FROM departments) AS "科室数",
       (SELECT COUNT(*) FROM doctors)     AS "医生数",
       (SELECT COUNT(*) FROM users)       AS "后台账号数";


-- ============================================================================
--  第 12 组：业务数据装载（排班 / 号源 / 挂号记录）  ★ 数据量最大的一组
-- ============================================================================
--
--  本组装载的数据规模（与项目实际运行状态完全一致）：
--
--      排班 schedules            130 条      （10 位医生 × 14 天，按出诊规则过滤）
--      号源时段 schedule_slots  1560 个      （130 × 12 格）
--      挂号记录 appointments    1885 条      （全部 active）
--
--  三条生成规则（理解它们才能看懂下面的数据为什么长这样）：
--
--    (1) 出诊规则：周日大部分医生停诊（主任医师部分轮值），
--        周六约八成医生出诊。所以 10 位医生 × 14 天 ≠ 140 条排班，
--        而是过滤掉停诊后剩 130 条。
--
--    (2) 号源量按职称分档：主任医师每格 3 个左右、副主任医师 4 个左右、
--        主治医师 6 个左右，上午比下午略多。所以每条排班 12 格的总号源
--        各不相同（约 30~50 个）。
--
--    (3) 占位挂号：为了让 booked 与真实挂号数自洽，
--        程序为每一个"已占号源"生成了一条对应的合成挂号记录，
--        就诊人姓名/身份证/手机号均为按确定性伪随机生成的虚构数据。
--        身份证第 18 位是用 GB 11643-1999 校验位算法算出来的，
--        因此这些号能直接通过应用层的身份证校验，可用于演示"查重拦截"。
--
--  ★ 重要：本组数据是按"2026-10-07"为基准日生成的，日期范围
--    2026-10-07 ~ 2026-10-20。如果执行日期距此较远，
--    前端"可预约日期"可能落在过去 —— 此时重新执行一次
--    server/init-db.js 即可按当天日期重新生成。
-- ============================================================================

-- ------------------------------------------------------------
-- 12.1 排班表 schedules —— 共 130 条
--      一条排班 = 某位医生某一天的门诊，由 uq_schedule_doctor_date 保证不重复。
--      日期覆盖 2026-10-07 ~ 2026-10-20（生成时的「今天」起算 14 天）。
--      注意这里没有 hospital_id —— 本系统只服务一家医院，
--      院区信息是部署期常量，不落库（见第 2 组开头的设计说明）。
-- ------------------------------------------------------------
INSERT INTO schedules (id, doctor_id, dept_id, work_date, weekday, closed) VALUES
('SC_DR01_2026-10-07', 'DR01', 'D01', DATE '2026-10-07', '周三', FALSE),
('SC_DR01_2026-10-08', 'DR01', 'D01', DATE '2026-10-08', '周四', FALSE),
('SC_DR01_2026-10-09', 'DR01', 'D01', DATE '2026-10-09', '周五', FALSE),
('SC_DR01_2026-10-10', 'DR01', 'D01', DATE '2026-10-10', '周六', FALSE),
('SC_DR01_2026-10-11', 'DR01', 'D01', DATE '2026-10-11', '周日', FALSE),
('SC_DR01_2026-10-12', 'DR01', 'D01', DATE '2026-10-12', '周一', FALSE),
('SC_DR01_2026-10-13', 'DR01', 'D01', DATE '2026-10-13', '周二', FALSE),
('SC_DR01_2026-10-14', 'DR01', 'D01', DATE '2026-10-14', '周三', FALSE),
('SC_DR01_2026-10-15', 'DR01', 'D01', DATE '2026-10-15', '周四', FALSE),
('SC_DR01_2026-10-16', 'DR01', 'D01', DATE '2026-10-16', '周五', FALSE),
('SC_DR01_2026-10-18', 'DR01', 'D01', DATE '2026-10-18', '周日', FALSE),
('SC_DR01_2026-10-19', 'DR01', 'D01', DATE '2026-10-19', '周一', FALSE),
('SC_DR01_2026-10-20', 'DR01', 'D01', DATE '2026-10-20', '周二', FALSE),
('SC_DR02_2026-10-07', 'DR02', 'D01', DATE '2026-10-07', '周三', FALSE),
('SC_DR02_2026-10-08', 'DR02', 'D01', DATE '2026-10-08', '周四', FALSE),
('SC_DR02_2026-10-09', 'DR02', 'D01', DATE '2026-10-09', '周五', FALSE),
('SC_DR02_2026-10-11', 'DR02', 'D01', DATE '2026-10-11', '周日', FALSE),
('SC_DR02_2026-10-12', 'DR02', 'D01', DATE '2026-10-12', '周一', FALSE),
('SC_DR02_2026-10-13', 'DR02', 'D01', DATE '2026-10-13', '周二', FALSE),
('SC_DR02_2026-10-14', 'DR02', 'D01', DATE '2026-10-14', '周三', FALSE),
('SC_DR02_2026-10-15', 'DR02', 'D01', DATE '2026-10-15', '周四', FALSE),
('SC_DR02_2026-10-16', 'DR02', 'D01', DATE '2026-10-16', '周五', FALSE),
('SC_DR02_2026-10-17', 'DR02', 'D01', DATE '2026-10-17', '周六', FALSE),
('SC_DR02_2026-10-18', 'DR02', 'D01', DATE '2026-10-18', '周日', FALSE),
('SC_DR02_2026-10-19', 'DR02', 'D01', DATE '2026-10-19', '周一', FALSE),
('SC_DR02_2026-10-20', 'DR02', 'D01', DATE '2026-10-20', '周二', FALSE),
('SC_DR03_2026-10-07', 'DR03', 'D01', DATE '2026-10-07', '周三', FALSE),
('SC_DR03_2026-10-08', 'DR03', 'D01', DATE '2026-10-08', '周四', FALSE),
('SC_DR03_2026-10-09', 'DR03', 'D01', DATE '2026-10-09', '周五', FALSE),
('SC_DR03_2026-10-10', 'DR03', 'D01', DATE '2026-10-10', '周六', FALSE),
('SC_DR03_2026-10-11', 'DR03', 'D01', DATE '2026-10-11', '周日', FALSE),
('SC_DR03_2026-10-12', 'DR03', 'D01', DATE '2026-10-12', '周一', FALSE),
('SC_DR03_2026-10-13', 'DR03', 'D01', DATE '2026-10-13', '周二', FALSE),
('SC_DR03_2026-10-14', 'DR03', 'D01', DATE '2026-10-14', '周三', FALSE),
('SC_DR03_2026-10-15', 'DR03', 'D01', DATE '2026-10-15', '周四', FALSE),
('SC_DR03_2026-10-16', 'DR03', 'D01', DATE '2026-10-16', '周五', FALSE),
('SC_DR03_2026-10-17', 'DR03', 'D01', DATE '2026-10-17', '周六', FALSE),
('SC_DR03_2026-10-19', 'DR03', 'D01', DATE '2026-10-19', '周一', FALSE),
('SC_DR03_2026-10-20', 'DR03', 'D01', DATE '2026-10-20', '周二', FALSE),
('SC_DR04_2026-10-07', 'DR04', 'D02', DATE '2026-10-07', '周三', FALSE),
('SC_DR04_2026-10-08', 'DR04', 'D02', DATE '2026-10-08', '周四', FALSE),
('SC_DR04_2026-10-09', 'DR04', 'D02', DATE '2026-10-09', '周五', FALSE),
('SC_DR04_2026-10-10', 'DR04', 'D02', DATE '2026-10-10', '周六', FALSE),
('SC_DR04_2026-10-11', 'DR04', 'D02', DATE '2026-10-11', '周日', FALSE),
('SC_DR04_2026-10-12', 'DR04', 'D02', DATE '2026-10-12', '周一', FALSE),
('SC_DR04_2026-10-13', 'DR04', 'D02', DATE '2026-10-13', '周二', FALSE),
('SC_DR04_2026-10-14', 'DR04', 'D02', DATE '2026-10-14', '周三', FALSE),
('SC_DR04_2026-10-15', 'DR04', 'D02', DATE '2026-10-15', '周四', FALSE),
('SC_DR04_2026-10-16', 'DR04', 'D02', DATE '2026-10-16', '周五', FALSE),
('SC_DR04_2026-10-17', 'DR04', 'D02', DATE '2026-10-17', '周六', FALSE),
('SC_DR04_2026-10-18', 'DR04', 'D02', DATE '2026-10-18', '周日', FALSE),
('SC_DR04_2026-10-19', 'DR04', 'D02', DATE '2026-10-19', '周一', FALSE),
('SC_DR04_2026-10-20', 'DR04', 'D02', DATE '2026-10-20', '周二', FALSE),
('SC_DR05_2026-10-07', 'DR05', 'D02', DATE '2026-10-07', '周三', FALSE),
('SC_DR05_2026-10-08', 'DR05', 'D02', DATE '2026-10-08', '周四', FALSE),
('SC_DR05_2026-10-09', 'DR05', 'D02', DATE '2026-10-09', '周五', FALSE),
('SC_DR05_2026-10-10', 'DR05', 'D02', DATE '2026-10-10', '周六', FALSE),
('SC_DR05_2026-10-12', 'DR05', 'D02', DATE '2026-10-12', '周一', FALSE),
('SC_DR05_2026-10-13', 'DR05', 'D02', DATE '2026-10-13', '周二', FALSE),
('SC_DR05_2026-10-14', 'DR05', 'D02', DATE '2026-10-14', '周三', FALSE),
('SC_DR05_2026-10-15', 'DR05', 'D02', DATE '2026-10-15', '周四', FALSE),
('SC_DR05_2026-10-16', 'DR05', 'D02', DATE '2026-10-16', '周五', FALSE),
('SC_DR05_2026-10-17', 'DR05', 'D02', DATE '2026-10-17', '周六', FALSE),
('SC_DR05_2026-10-19', 'DR05', 'D02', DATE '2026-10-19', '周一', FALSE),
('SC_DR05_2026-10-20', 'DR05', 'D02', DATE '2026-10-20', '周二', FALSE),
('SC_DR06_2026-10-07', 'DR06', 'D03', DATE '2026-10-07', '周三', FALSE),
('SC_DR06_2026-10-08', 'DR06', 'D03', DATE '2026-10-08', '周四', FALSE),
('SC_DR06_2026-10-09', 'DR06', 'D03', DATE '2026-10-09', '周五', FALSE),
('SC_DR06_2026-10-10', 'DR06', 'D03', DATE '2026-10-10', '周六', FALSE),
('SC_DR06_2026-10-12', 'DR06', 'D03', DATE '2026-10-12', '周一', FALSE),
('SC_DR06_2026-10-13', 'DR06', 'D03', DATE '2026-10-13', '周二', FALSE),
('SC_DR06_2026-10-14', 'DR06', 'D03', DATE '2026-10-14', '周三', FALSE),
('SC_DR06_2026-10-15', 'DR06', 'D03', DATE '2026-10-15', '周四', FALSE),
('SC_DR06_2026-10-16', 'DR06', 'D03', DATE '2026-10-16', '周五', FALSE),
('SC_DR06_2026-10-17', 'DR06', 'D03', DATE '2026-10-17', '周六', FALSE),
('SC_DR06_2026-10-18', 'DR06', 'D03', DATE '2026-10-18', '周日', FALSE),
('SC_DR06_2026-10-19', 'DR06', 'D03', DATE '2026-10-19', '周一', FALSE),
('SC_DR06_2026-10-20', 'DR06', 'D03', DATE '2026-10-20', '周二', FALSE),
('SC_DR07_2026-10-07', 'DR07', 'D03', DATE '2026-10-07', '周三', FALSE),
('SC_DR07_2026-10-08', 'DR07', 'D03', DATE '2026-10-08', '周四', FALSE),
('SC_DR07_2026-10-09', 'DR07', 'D03', DATE '2026-10-09', '周五', FALSE),
('SC_DR07_2026-10-10', 'DR07', 'D03', DATE '2026-10-10', '周六', FALSE),
('SC_DR07_2026-10-11', 'DR07', 'D03', DATE '2026-10-11', '周日', FALSE),
('SC_DR07_2026-10-12', 'DR07', 'D03', DATE '2026-10-12', '周一', FALSE),
('SC_DR07_2026-10-13', 'DR07', 'D03', DATE '2026-10-13', '周二', FALSE),
('SC_DR07_2026-10-14', 'DR07', 'D03', DATE '2026-10-14', '周三', FALSE),
('SC_DR07_2026-10-15', 'DR07', 'D03', DATE '2026-10-15', '周四', FALSE),
('SC_DR07_2026-10-16', 'DR07', 'D03', DATE '2026-10-16', '周五', FALSE),
('SC_DR07_2026-10-17', 'DR07', 'D03', DATE '2026-10-17', '周六', FALSE),
('SC_DR07_2026-10-19', 'DR07', 'D03', DATE '2026-10-19', '周一', FALSE),
('SC_DR07_2026-10-20', 'DR07', 'D03', DATE '2026-10-20', '周二', FALSE),
('SC_DR08_2026-10-07', 'DR08', 'D04', DATE '2026-10-07', '周三', FALSE),
('SC_DR08_2026-10-08', 'DR08', 'D04', DATE '2026-10-08', '周四', FALSE),
('SC_DR08_2026-10-09', 'DR08', 'D04', DATE '2026-10-09', '周五', FALSE),
('SC_DR08_2026-10-10', 'DR08', 'D04', DATE '2026-10-10', '周六', FALSE),
('SC_DR08_2026-10-11', 'DR08', 'D04', DATE '2026-10-11', '周日', FALSE),
('SC_DR08_2026-10-12', 'DR08', 'D04', DATE '2026-10-12', '周一', FALSE),
('SC_DR08_2026-10-13', 'DR08', 'D04', DATE '2026-10-13', '周二', FALSE),
('SC_DR08_2026-10-14', 'DR08', 'D04', DATE '2026-10-14', '周三', FALSE),
('SC_DR08_2026-10-15', 'DR08', 'D04', DATE '2026-10-15', '周四', FALSE),
('SC_DR08_2026-10-16', 'DR08', 'D04', DATE '2026-10-16', '周五', FALSE),
('SC_DR08_2026-10-17', 'DR08', 'D04', DATE '2026-10-17', '周六', FALSE),
('SC_DR08_2026-10-18', 'DR08', 'D04', DATE '2026-10-18', '周日', FALSE),
('SC_DR08_2026-10-19', 'DR08', 'D04', DATE '2026-10-19', '周一', FALSE),
('SC_DR08_2026-10-20', 'DR08', 'D04', DATE '2026-10-20', '周二', FALSE),
('SC_DR09_2026-10-07', 'DR09', 'D04', DATE '2026-10-07', '周三', FALSE),
('SC_DR09_2026-10-08', 'DR09', 'D04', DATE '2026-10-08', '周四', FALSE),
('SC_DR09_2026-10-09', 'DR09', 'D04', DATE '2026-10-09', '周五', FALSE),
('SC_DR09_2026-10-10', 'DR09', 'D04', DATE '2026-10-10', '周六', FALSE),
('SC_DR09_2026-10-11', 'DR09', 'D04', DATE '2026-10-11', '周日', FALSE),
('SC_DR09_2026-10-12', 'DR09', 'D04', DATE '2026-10-12', '周一', FALSE),
('SC_DR09_2026-10-13', 'DR09', 'D04', DATE '2026-10-13', '周二', FALSE),
('SC_DR09_2026-10-14', 'DR09', 'D04', DATE '2026-10-14', '周三', FALSE),
('SC_DR09_2026-10-15', 'DR09', 'D04', DATE '2026-10-15', '周四', FALSE),
('SC_DR09_2026-10-16', 'DR09', 'D04', DATE '2026-10-16', '周五', FALSE),
('SC_DR09_2026-10-17', 'DR09', 'D04', DATE '2026-10-17', '周六', FALSE),
('SC_DR09_2026-10-19', 'DR09', 'D04', DATE '2026-10-19', '周一', FALSE),
('SC_DR09_2026-10-20', 'DR09', 'D04', DATE '2026-10-20', '周二', FALSE),
('SC_DR10_2026-10-07', 'DR10', 'D05', DATE '2026-10-07', '周三', FALSE),
('SC_DR10_2026-10-08', 'DR10', 'D05', DATE '2026-10-08', '周四', FALSE),
('SC_DR10_2026-10-09', 'DR10', 'D05', DATE '2026-10-09', '周五', FALSE),
('SC_DR10_2026-10-10', 'DR10', 'D05', DATE '2026-10-10', '周六', FALSE),
('SC_DR10_2026-10-12', 'DR10', 'D05', DATE '2026-10-12', '周一', FALSE),
('SC_DR10_2026-10-13', 'DR10', 'D05', DATE '2026-10-13', '周二', FALSE),
('SC_DR10_2026-10-14', 'DR10', 'D05', DATE '2026-10-14', '周三', FALSE),
('SC_DR10_2026-10-15', 'DR10', 'D05', DATE '2026-10-15', '周四', FALSE),
('SC_DR10_2026-10-16', 'DR10', 'D05', DATE '2026-10-16', '周五', FALSE),
('SC_DR10_2026-10-17', 'DR10', 'D05', DATE '2026-10-17', '周六', FALSE),
('SC_DR10_2026-10-19', 'DR10', 'D05', DATE '2026-10-19', '周一', FALSE),
('SC_DR10_2026-10-20', 'DR10', 'D05', DATE '2026-10-20', '周二', FALSE);

-- ------------------------------------------------------------
-- 12.2 号源时段表 schedule_slots —— 共 1560 个时段
--      （每条排班 12 格 × 130 条排班 = 1560）
--
--      这里没有把 label / period 再抄一遍，而是用一张 12 行的「时段字典」
--      JOIN 出来 —— 因为全库 1560 个时段的名称与午别只有 12 种取值，
--      重复存储属于冗余。这正是数据库设计中「同一份事实只存一处」的体现。
--      VALUES 列表里只保留真正逐行不同的四个字段：
--        schedule_id（哪条排班）、slot_id（第几格）、total（放几个号）、booked（已约几个）
-- ------------------------------------------------------------
INSERT INTO schedule_slots (schedule_id, slot_id, label, period, total, booked)
SELECT v.schedule_id,
       v.slot_id,
       d.label,
       d.period,
       v.total,
       v.booked
  FROM (VALUES
         ('SC_DR01_2026-10-07', 'S1', 3, 2),
         ('SC_DR01_2026-10-07', 'S2', 4, 4),
         ('SC_DR01_2026-10-07', 'S3', 2, 1),
         ('SC_DR01_2026-10-07', 'S4', 2, 1),
         ('SC_DR01_2026-10-07', 'S5', 3, 2),
         ('SC_DR01_2026-10-07', 'S6', 4, 3),
         ('SC_DR01_2026-10-07', 'S7', 3, 3),
         ('SC_DR01_2026-10-07', 'S8', 2, 1),
         ('SC_DR01_2026-10-07', 'S9', 2, 1),
         ('SC_DR01_2026-10-07', 'S10', 2, 1),
         ('SC_DR01_2026-10-07', 'S11', 3, 3),
         ('SC_DR01_2026-10-07', 'S12', 3, 2),
         ('SC_DR01_2026-10-08', 'S1', 3, 2),
         ('SC_DR01_2026-10-08', 'S2', 3, 2),
         ('SC_DR01_2026-10-08', 'S3', 2, 1),
         ('SC_DR01_2026-10-08', 'S4', 4, 3),
         ('SC_DR01_2026-10-08', 'S5', 3, 2),
         ('SC_DR01_2026-10-08', 'S6', 3, 1),
         ('SC_DR01_2026-10-08', 'S7', 2, 1),
         ('SC_DR01_2026-10-08', 'S8', 3, 2),
         ('SC_DR01_2026-10-08', 'S9', 2, 1),
         ('SC_DR01_2026-10-08', 'S10', 3, 2),
         ('SC_DR01_2026-10-08', 'S11', 3, 2),
         ('SC_DR01_2026-10-08', 'S12', 2, 1),
         ('SC_DR01_2026-10-09', 'S1', 3, 2),
         ('SC_DR01_2026-10-09', 'S2', 4, 3),
         ('SC_DR01_2026-10-09', 'S3', 2, 0),
         ('SC_DR01_2026-10-09', 'S4', 2, 1),
         ('SC_DR01_2026-10-09', 'S5', 3, 1),
         ('SC_DR01_2026-10-09', 'S6', 4, 2),
         ('SC_DR01_2026-10-09', 'S7', 3, 2),
         ('SC_DR01_2026-10-09', 'S8', 3, 2),
         ('SC_DR01_2026-10-09', 'S9', 3, 2),
         ('SC_DR01_2026-10-09', 'S10', 3, 2),
         ('SC_DR01_2026-10-09', 'S11', 2, 1),
         ('SC_DR01_2026-10-09', 'S12', 2, 1),
         ('SC_DR01_2026-10-10', 'S1', 4, 2),
         ('SC_DR01_2026-10-10', 'S2', 2, 0),
         ('SC_DR01_2026-10-10', 'S3', 2, 1),
         ('SC_DR01_2026-10-10', 'S4', 3, 1),
         ('SC_DR01_2026-10-10', 'S5', 3, 1),
         ('SC_DR01_2026-10-10', 'S6', 4, 3),
         ('SC_DR01_2026-10-10', 'S7', 2, 0),
         ('SC_DR01_2026-10-10', 'S8', 3, 2),
         ('SC_DR01_2026-10-10', 'S9', 3, 2),
         ('SC_DR01_2026-10-10', 'S10', 2, 0),
         ('SC_DR01_2026-10-10', 'S11', 3, 2),
         ('SC_DR01_2026-10-10', 'S12', 3, 2),
         ('SC_DR01_2026-10-11', 'S1', 3, 1),
         ('SC_DR01_2026-10-11', 'S2', 2, 0),
         ('SC_DR01_2026-10-11', 'S3', 2, 0),
         ('SC_DR01_2026-10-11', 'S4', 4, 2),
         ('SC_DR01_2026-10-11', 'S5', 3, 1),
         ('SC_DR01_2026-10-11', 'S6', 3, 1),
         ('SC_DR01_2026-10-11', 'S7', 2, 0),
         ('SC_DR01_2026-10-11', 'S8', 3, 1),
         ('SC_DR01_2026-10-11', 'S9', 2, 1),
         ('SC_DR01_2026-10-11', 'S10', 2, 1),
         ('SC_DR01_2026-10-11', 'S11', 3, 1),
         ('SC_DR01_2026-10-11', 'S12', 3, 1),
         ('SC_DR01_2026-10-12', 'S1', 4, 2),
         ('SC_DR01_2026-10-12', 'S2', 2, 0),
         ('SC_DR01_2026-10-12', 'S3', 2, 0),
         ('SC_DR01_2026-10-12', 'S4', 3, 1),
         ('SC_DR01_2026-10-12', 'S5', 4, 2),
         ('SC_DR01_2026-10-12', 'S6', 2, 0),
         ('SC_DR01_2026-10-12', 'S7', 2, 0),
         ('SC_DR01_2026-10-12', 'S8', 3, 1),
         ('SC_DR01_2026-10-12', 'S9', 2, 0),
         ('SC_DR01_2026-10-12', 'S10', 3, 1),
         ('SC_DR01_2026-10-12', 'S11', 3, 1),
         ('SC_DR01_2026-10-12', 'S12', 2, 0),
         ('SC_DR01_2026-10-13', 'S1', 4, 1),
         ('SC_DR01_2026-10-13', 'S2', 3, 1),
         ('SC_DR01_2026-10-13', 'S3', 3, 1),
         ('SC_DR01_2026-10-13', 'S4', 2, 0),
         ('SC_DR01_2026-10-13', 'S5', 4, 1),
         ('SC_DR01_2026-10-13', 'S6', 3, 1),
         ('SC_DR01_2026-10-13', 'S7', 2, 0),
         ('SC_DR01_2026-10-13', 'S8', 3, 1),
         ('SC_DR01_2026-10-13', 'S9', 3, 1),
         ('SC_DR01_2026-10-13', 'S10', 3, 1),
         ('SC_DR01_2026-10-13', 'S11', 3, 1),
         ('SC_DR01_2026-10-13', 'S12', 2, 0),
         ('SC_DR01_2026-10-14', 'S1', 4, 1),
         ('SC_DR01_2026-10-14', 'S2', 2, 0),
         ('SC_DR01_2026-10-14', 'S3', 3, 0),
         ('SC_DR01_2026-10-14', 'S4', 4, 1),
         ('SC_DR01_2026-10-14', 'S5', 4, 1),
         ('SC_DR01_2026-10-14', 'S6', 2, 0),
         ('SC_DR01_2026-10-14', 'S7', 3, 0),
         ('SC_DR01_2026-10-14', 'S8', 2, 0),
         ('SC_DR01_2026-10-14', 'S9', 3, 1),
         ('SC_DR01_2026-10-14', 'S10', 3, 0),
         ('SC_DR01_2026-10-14', 'S11', 2, 0),
         ('SC_DR01_2026-10-14', 'S12', 2, 0),
         ('SC_DR01_2026-10-15', 'S1', 3, 0),
         ('SC_DR01_2026-10-15', 'S2', 2, 0),
         ('SC_DR01_2026-10-15', 'S3', 4, 1),
         ('SC_DR01_2026-10-15', 'S4', 3, 0),
         ('SC_DR01_2026-10-15', 'S5', 3, 0),
         ('SC_DR01_2026-10-15', 'S6', 2, 0),
         ('SC_DR01_2026-10-15', 'S7', 3, 1),
         ('SC_DR01_2026-10-15', 'S8', 3, 0),
         ('SC_DR01_2026-10-15', 'S9', 2, 0),
         ('SC_DR01_2026-10-15', 'S10', 3, 0),
         ('SC_DR01_2026-10-15', 'S11', 3, 0),
         ('SC_DR01_2026-10-15', 'S12', 2, 0),
         ('SC_DR01_2026-10-16', 'S1', 2, 0),
         ('SC_DR01_2026-10-16', 'S2', 3, 0),
         ('SC_DR01_2026-10-16', 'S3', 3, 0),
         ('SC_DR01_2026-10-16', 'S4', 4, 1),
         ('SC_DR01_2026-10-16', 'S5', 3, 0),
         ('SC_DR01_2026-10-16', 'S6', 4, 1),
         ('SC_DR01_2026-10-16', 'S7', 2, 0),
         ('SC_DR01_2026-10-16', 'S8', 2, 0),
         ('SC_DR01_2026-10-16', 'S9', 2, 0),
         ('SC_DR01_2026-10-16', 'S10', 2, 0),
         ('SC_DR01_2026-10-16', 'S11', 2, 0),
         ('SC_DR01_2026-10-16', 'S12', 3, 1),
         ('SC_DR01_2026-10-18', 'S1', 2, 0),
         ('SC_DR01_2026-10-18', 'S2', 3, 0),
         ('SC_DR01_2026-10-18', 'S3', 3, 0),
         ('SC_DR01_2026-10-18', 'S4', 4, 1),
         ('SC_DR01_2026-10-18', 'S5', 4, 1),
         ('SC_DR01_2026-10-18', 'S6', 3, 0),
         ('SC_DR01_2026-10-18', 'S7', 3, 0),
         ('SC_DR01_2026-10-18', 'S8', 3, 0),
         ('SC_DR01_2026-10-18', 'S9', 3, 1),
         ('SC_DR01_2026-10-18', 'S10', 2, 0),
         ('SC_DR01_2026-10-18', 'S11', 2, 0),
         ('SC_DR01_2026-10-18', 'S12', 3, 1),
         ('SC_DR01_2026-10-19', 'S1', 3, 0),
         ('SC_DR01_2026-10-19', 'S2', 2, 0),
         ('SC_DR01_2026-10-19', 'S3', 2, 0),
         ('SC_DR01_2026-10-19', 'S4', 4, 1),
         ('SC_DR01_2026-10-19', 'S5', 3, 0),
         ('SC_DR01_2026-10-19', 'S6', 3, 0),
         ('SC_DR01_2026-10-19', 'S7', 2, 0),
         ('SC_DR01_2026-10-19', 'S8', 2, 0),
         ('SC_DR01_2026-10-19', 'S9', 3, 1),
         ('SC_DR01_2026-10-19', 'S10', 2, 0),
         ('SC_DR01_2026-10-19', 'S11', 2, 0),
         ('SC_DR01_2026-10-19', 'S12', 3, 0),
         ('SC_DR01_2026-10-20', 'S1', 3, 0),
         ('SC_DR01_2026-10-20', 'S2', 2, 0),
         ('SC_DR01_2026-10-20', 'S3', 2, 0),
         ('SC_DR01_2026-10-20', 'S4', 4, 1),
         ('SC_DR01_2026-10-20', 'S5', 3, 0),
         ('SC_DR01_2026-10-20', 'S6', 3, 0),
         ('SC_DR01_2026-10-20', 'S7', 2, 0),
         ('SC_DR01_2026-10-20', 'S8', 2, 0),
         ('SC_DR01_2026-10-20', 'S9', 2, 0),
         ('SC_DR01_2026-10-20', 'S10', 2, 0),
         ('SC_DR01_2026-10-20', 'S11', 3, 0),
         ('SC_DR01_2026-10-20', 'S12', 3, 1),
         ('SC_DR02_2026-10-07', 'S1', 2, 1),
         ('SC_DR02_2026-10-07', 'S2', 5, 4),
         ('SC_DR02_2026-10-07', 'S3', 4, 2),
         ('SC_DR02_2026-10-07', 'S4', 3, 1),
         ('SC_DR02_2026-10-07', 'S5', 5, 5),
         ('SC_DR02_2026-10-07', 'S6', 4, 3),
         ('SC_DR02_2026-10-07', 'S7', 3, 2),
         ('SC_DR02_2026-10-07', 'S8', 3, 2),
         ('SC_DR02_2026-10-07', 'S9', 3, 1),
         ('SC_DR02_2026-10-07', 'S10', 4, 3),
         ('SC_DR02_2026-10-07', 'S11', 2, 1),
         ('SC_DR02_2026-10-07', 'S12', 3, 2),
         ('SC_DR02_2026-10-08', 'S1', 4, 2),
         ('SC_DR02_2026-10-08', 'S2', 5, 4),
         ('SC_DR02_2026-10-08', 'S3', 2, 0),
         ('SC_DR02_2026-10-08', 'S4', 4, 2),
         ('SC_DR02_2026-10-08', 'S5', 5, 3),
         ('SC_DR02_2026-10-08', 'S6', 5, 4),
         ('SC_DR02_2026-10-08', 'S7', 2, 1),
         ('SC_DR02_2026-10-08', 'S8', 4, 2),
         ('SC_DR02_2026-10-08', 'S9', 4, 3),
         ('SC_DR02_2026-10-08', 'S10', 3, 2),
         ('SC_DR02_2026-10-08', 'S11', 3, 1),
         ('SC_DR02_2026-10-08', 'S12', 5, 4),
         ('SC_DR02_2026-10-09', 'S1', 4, 2),
         ('SC_DR02_2026-10-09', 'S2', 3, 1),
         ('SC_DR02_2026-10-09', 'S3', 6, 5),
         ('SC_DR02_2026-10-09', 'S4', 5, 3),
         ('SC_DR02_2026-10-09', 'S5', 4, 2),
         ('SC_DR02_2026-10-09', 'S6', 3, 1),
         ('SC_DR02_2026-10-09', 'S7', 2, 0),
         ('SC_DR02_2026-10-09', 'S8', 3, 1),
         ('SC_DR02_2026-10-09', 'S9', 3, 1),
         ('SC_DR02_2026-10-09', 'S10', 5, 4),
         ('SC_DR02_2026-10-09', 'S11', 3, 1),
         ('SC_DR02_2026-10-09', 'S12', 3, 1),
         ('SC_DR02_2026-10-11', 'S1', 5, 2),
         ('SC_DR02_2026-10-11', 'S2', 3, 1),
         ('SC_DR02_2026-10-11', 'S3', 4, 1),
         ('SC_DR02_2026-10-11', 'S4', 3, 1),
         ('SC_DR02_2026-10-11', 'S5', 4, 1),
         ('SC_DR02_2026-10-11', 'S6', 5, 2),
         ('SC_DR02_2026-10-11', 'S7', 5, 3),
         ('SC_DR02_2026-10-11', 'S8', 2, 0),
         ('SC_DR02_2026-10-11', 'S9', 3, 1),
         ('SC_DR02_2026-10-11', 'S10', 4, 2),
         ('SC_DR02_2026-10-11', 'S11', 3, 1),
         ('SC_DR02_2026-10-11', 'S12', 3, 1),
         ('SC_DR02_2026-10-12', 'S1', 4, 1),
         ('SC_DR02_2026-10-12', 'S2', 3, 1),
         ('SC_DR02_2026-10-12', 'S3', 6, 3),
         ('SC_DR02_2026-10-12', 'S4', 5, 2),
         ('SC_DR02_2026-10-12', 'S5', 4, 1),
         ('SC_DR02_2026-10-12', 'S6', 3, 1),
         ('SC_DR02_2026-10-12', 'S7', 2, 0),
         ('SC_DR02_2026-10-12', 'S8', 4, 2),
         ('SC_DR02_2026-10-12', 'S9', 5, 2),
         ('SC_DR02_2026-10-12', 'S10', 4, 1),
         ('SC_DR02_2026-10-12', 'S11', 2, 0),
         ('SC_DR02_2026-10-12', 'S12', 3, 1),
         ('SC_DR02_2026-10-13', 'S1', 4, 1),
         ('SC_DR02_2026-10-13', 'S2', 4, 1),
         ('SC_DR02_2026-10-13', 'S3', 5, 2),
         ('SC_DR02_2026-10-13', 'S4', 3, 0),
         ('SC_DR02_2026-10-13', 'S5', 4, 1),
         ('SC_DR02_2026-10-13', 'S6', 5, 1),
         ('SC_DR02_2026-10-13', 'S7', 5, 2),
         ('SC_DR02_2026-10-13', 'S8', 5, 2),
         ('SC_DR02_2026-10-13', 'S9', 3, 0),
         ('SC_DR02_2026-10-13', 'S10', 2, 0),
         ('SC_DR02_2026-10-13', 'S11', 4, 1),
         ('SC_DR02_2026-10-13', 'S12', 3, 1),
         ('SC_DR02_2026-10-14', 'S1', 3, 0),
         ('SC_DR02_2026-10-14', 'S2', 5, 1),
         ('SC_DR02_2026-10-14', 'S3', 4, 1),
         ('SC_DR02_2026-10-14', 'S4', 3, 0),
         ('SC_DR02_2026-10-14', 'S5', 2, 0),
         ('SC_DR02_2026-10-14', 'S6', 5, 1),
         ('SC_DR02_2026-10-14', 'S7', 3, 0),
         ('SC_DR02_2026-10-14', 'S8', 4, 1),
         ('SC_DR02_2026-10-14', 'S9', 3, 0),
         ('SC_DR02_2026-10-14', 'S10', 3, 0),
         ('SC_DR02_2026-10-14', 'S11', 3, 0),
         ('SC_DR02_2026-10-14', 'S12', 4, 1),
         ('SC_DR02_2026-10-15', 'S1', 3, 0),
         ('SC_DR02_2026-10-15', 'S2', 4, 1),
         ('SC_DR02_2026-10-15', 'S3', 5, 1),
         ('SC_DR02_2026-10-15', 'S4', 3, 0),
         ('SC_DR02_2026-10-15', 'S5', 4, 0),
         ('SC_DR02_2026-10-15', 'S6', 5, 1),
         ('SC_DR02_2026-10-15', 'S7', 5, 1),
         ('SC_DR02_2026-10-15', 'S8', 3, 0),
         ('SC_DR02_2026-10-15', 'S9', 3, 0),
         ('SC_DR02_2026-10-15', 'S10', 4, 1),
         ('SC_DR02_2026-10-15', 'S11', 3, 0),
         ('SC_DR02_2026-10-15', 'S12', 2, 0),
         ('SC_DR02_2026-10-16', 'S1', 3, 0),
         ('SC_DR02_2026-10-16', 'S2', 2, 0),
         ('SC_DR02_2026-10-16', 'S3', 5, 1),
         ('SC_DR02_2026-10-16', 'S4', 4, 0),
         ('SC_DR02_2026-10-16', 'S5', 3, 0),
         ('SC_DR02_2026-10-16', 'S6', 5, 1),
         ('SC_DR02_2026-10-16', 'S7', 4, 1),
         ('SC_DR02_2026-10-16', 'S8', 4, 1),
         ('SC_DR02_2026-10-16', 'S9', 3, 0),
         ('SC_DR02_2026-10-16', 'S10', 4, 1),
         ('SC_DR02_2026-10-16', 'S11', 5, 1),
         ('SC_DR02_2026-10-16', 'S12', 3, 0),
         ('SC_DR02_2026-10-17', 'S1', 4, 0),
         ('SC_DR02_2026-10-17', 'S2', 5, 1),
         ('SC_DR02_2026-10-17', 'S3', 5, 1),
         ('SC_DR02_2026-10-17', 'S4', 3, 0),
         ('SC_DR02_2026-10-17', 'S5', 3, 0),
         ('SC_DR02_2026-10-17', 'S6', 4, 1),
         ('SC_DR02_2026-10-17', 'S7', 4, 1),
         ('SC_DR02_2026-10-17', 'S8', 2, 0),
         ('SC_DR02_2026-10-17', 'S9', 3, 0),
         ('SC_DR02_2026-10-17', 'S10', 3, 0),
         ('SC_DR02_2026-10-17', 'S11', 2, 0),
         ('SC_DR02_2026-10-17', 'S12', 4, 1),
         ('SC_DR02_2026-10-18', 'S1', 3, 0),
         ('SC_DR02_2026-10-18', 'S2', 5, 1),
         ('SC_DR02_2026-10-18', 'S3', 4, 1),
         ('SC_DR02_2026-10-18', 'S4', 4, 1),
         ('SC_DR02_2026-10-18', 'S5', 3, 0),
         ('SC_DR02_2026-10-18', 'S6', 5, 1),
         ('SC_DR02_2026-10-18', 'S7', 4, 1),
         ('SC_DR02_2026-10-18', 'S8', 3, 0),
         ('SC_DR02_2026-10-18', 'S9', 5, 1),
         ('SC_DR02_2026-10-18', 'S10', 3, 0),
         ('SC_DR02_2026-10-18', 'S11', 4, 1),
         ('SC_DR02_2026-10-18', 'S12', 4, 1),
         ('SC_DR02_2026-10-19', 'S1', 5, 1),
         ('SC_DR02_2026-10-19', 'S2', 3, 0),
         ('SC_DR02_2026-10-19', 'S3', 4, 0),
         ('SC_DR02_2026-10-19', 'S4', 4, 1),
         ('SC_DR02_2026-10-19', 'S5', 5, 1),
         ('SC_DR02_2026-10-19', 'S6', 3, 0),
         ('SC_DR02_2026-10-19', 'S7', 3, 0),
         ('SC_DR02_2026-10-19', 'S8', 4, 1),
         ('SC_DR02_2026-10-19', 'S9', 2, 0),
         ('SC_DR02_2026-10-19', 'S10', 3, 0),
         ('SC_DR02_2026-10-19', 'S11', 2, 0),
         ('SC_DR02_2026-10-19', 'S12', 4, 1),
         ('SC_DR02_2026-10-20', 'S1', 4, 1),
         ('SC_DR02_2026-10-20', 'S2', 5, 1),
         ('SC_DR02_2026-10-20', 'S3', 3, 0),
         ('SC_DR02_2026-10-20', 'S4', 3, 0),
         ('SC_DR02_2026-10-20', 'S5', 4, 0),
         ('SC_DR02_2026-10-20', 'S6', 5, 1),
         ('SC_DR02_2026-10-20', 'S7', 5, 1),
         ('SC_DR02_2026-10-20', 'S8', 3, 0),
         ('SC_DR02_2026-10-20', 'S9', 4, 1),
         ('SC_DR02_2026-10-20', 'S10', 3, 0),
         ('SC_DR02_2026-10-20', 'S11', 2, 0),
         ('SC_DR02_2026-10-20', 'S12', 4, 1),
         ('SC_DR03_2026-10-07', 'S1', 7, 6),
         ('SC_DR03_2026-10-07', 'S2', 8, 8),
         ('SC_DR03_2026-10-07', 'S3', 5, 2),
         ('SC_DR03_2026-10-07', 'S4', 7, 5),
         ('SC_DR03_2026-10-07', 'S5', 8, 7),
         ('SC_DR03_2026-10-07', 'S6', 4, 1),
         ('SC_DR03_2026-10-07', 'S7', 4, 2),
         ('SC_DR03_2026-10-07', 'S8', 4, 2),
         ('SC_DR03_2026-10-07', 'S9', 5, 3),
         ('SC_DR03_2026-10-07', 'S10', 5, 3),
         ('SC_DR03_2026-10-07', 'S11', 4, 2),
         ('SC_DR03_2026-10-07', 'S12', 7, 6),
         ('SC_DR03_2026-10-08', 'S1', 7, 5),
         ('SC_DR03_2026-10-08', 'S2', 6, 3),
         ('SC_DR03_2026-10-08', 'S3', 5, 2),
         ('SC_DR03_2026-10-08', 'S4', 8, 7),
         ('SC_DR03_2026-10-08', 'S5', 7, 5),
         ('SC_DR03_2026-10-08', 'S6', 5, 2),
         ('SC_DR03_2026-10-08', 'S7', 4, 1),
         ('SC_DR03_2026-10-08', 'S8', 6, 5),
         ('SC_DR03_2026-10-08', 'S9', 5, 3),
         ('SC_DR03_2026-10-08', 'S10', 4, 1),
         ('SC_DR03_2026-10-08', 'S11', 5, 3),
         ('SC_DR03_2026-10-08', 'S12', 6, 4),
         ('SC_DR03_2026-10-09', 'S1', 7, 4),
         ('SC_DR03_2026-10-09', 'S2', 4, 1),
         ('SC_DR03_2026-10-09', 'S3', 5, 2),
         ('SC_DR03_2026-10-09', 'S4', 6, 3),
         ('SC_DR03_2026-10-09', 'S5', 8, 5),
         ('SC_DR03_2026-10-09', 'S6', 4, 1),
         ('SC_DR03_2026-10-09', 'S7', 5, 2),
         ('SC_DR03_2026-10-09', 'S8', 4, 1),
         ('SC_DR03_2026-10-09', 'S9', 5, 2),
         ('SC_DR03_2026-10-09', 'S10', 5, 2),
         ('SC_DR03_2026-10-09', 'S11', 4, 1),
         ('SC_DR03_2026-10-09', 'S12', 7, 5),
         ('SC_DR03_2026-10-10', 'S1', 5, 1),
         ('SC_DR03_2026-10-10', 'S2', 6, 2),
         ('SC_DR03_2026-10-10', 'S3', 7, 4),
         ('SC_DR03_2026-10-10', 'S4', 8, 5),
         ('SC_DR03_2026-10-10', 'S5', 4, 1),
         ('SC_DR03_2026-10-10', 'S6', 5, 2),
         ('SC_DR03_2026-10-10', 'S7', 5, 2),
         ('SC_DR03_2026-10-10', 'S8', 6, 3),
         ('SC_DR03_2026-10-10', 'S9', 3, 1),
         ('SC_DR03_2026-10-10', 'S10', 6, 3),
         ('SC_DR03_2026-10-10', 'S11', 5, 2),
         ('SC_DR03_2026-10-10', 'S12', 3, 1),
         ('SC_DR03_2026-10-11', 'S1', 4, 1),
         ('SC_DR03_2026-10-11', 'S2', 8, 4),
         ('SC_DR03_2026-10-11', 'S3', 6, 2),
         ('SC_DR03_2026-10-11', 'S4', 4, 1),
         ('SC_DR03_2026-10-11', 'S5', 8, 4),
         ('SC_DR03_2026-10-11', 'S6', 7, 3),
         ('SC_DR03_2026-10-11', 'S7', 5, 2),
         ('SC_DR03_2026-10-11', 'S8', 5, 2),
         ('SC_DR03_2026-10-11', 'S9', 4, 1),
         ('SC_DR03_2026-10-11', 'S10', 6, 3),
         ('SC_DR03_2026-10-11', 'S11', 7, 4),
         ('SC_DR03_2026-10-11', 'S12', 4, 1),
         ('SC_DR03_2026-10-12', 'S1', 6, 2),
         ('SC_DR03_2026-10-12', 'S2', 8, 3),
         ('SC_DR03_2026-10-12', 'S3', 4, 1),
         ('SC_DR03_2026-10-12', 'S4', 5, 1),
         ('SC_DR03_2026-10-12', 'S5', 7, 2),
         ('SC_DR03_2026-10-12', 'S6', 8, 3),
         ('SC_DR03_2026-10-12', 'S7', 4, 1),
         ('SC_DR03_2026-10-12', 'S8', 5, 1),
         ('SC_DR03_2026-10-12', 'S9', 6, 2),
         ('SC_DR03_2026-10-12', 'S10', 6, 2),
         ('SC_DR03_2026-10-12', 'S11', 5, 1),
         ('SC_DR03_2026-10-12', 'S12', 4, 1),
         ('SC_DR03_2026-10-13', 'S1', 7, 2),
         ('SC_DR03_2026-10-13', 'S2', 5, 1),
         ('SC_DR03_2026-10-13', 'S3', 4, 0),
         ('SC_DR03_2026-10-13', 'S4', 7, 2),
         ('SC_DR03_2026-10-13', 'S5', 6, 1),
         ('SC_DR03_2026-10-13', 'S6', 5, 1),
         ('SC_DR03_2026-10-13', 'S7', 3, 0),
         ('SC_DR03_2026-10-13', 'S8', 4, 0),
         ('SC_DR03_2026-10-13', 'S9', 7, 2),
         ('SC_DR03_2026-10-13', 'S10', 4, 0),
         ('SC_DR03_2026-10-13', 'S11', 5, 1),
         ('SC_DR03_2026-10-13', 'S12', 6, 2),
         ('SC_DR03_2026-10-14', 'S1', 8, 2),
         ('SC_DR03_2026-10-14', 'S2', 4, 0),
         ('SC_DR03_2026-10-14', 'S3', 5, 1),
         ('SC_DR03_2026-10-14', 'S4', 7, 1),
         ('SC_DR03_2026-10-14', 'S5', 8, 2),
         ('SC_DR03_2026-10-14', 'S6', 5, 0),
         ('SC_DR03_2026-10-14', 'S7', 5, 1),
         ('SC_DR03_2026-10-14', 'S8', 5, 1),
         ('SC_DR03_2026-10-14', 'S9', 6, 1),
         ('SC_DR03_2026-10-14', 'S10', 4, 0),
         ('SC_DR03_2026-10-14', 'S11', 3, 0),
         ('SC_DR03_2026-10-14', 'S12', 6, 1),
         ('SC_DR03_2026-10-15', 'S1', 5, 0),
         ('SC_DR03_2026-10-15', 'S2', 4, 0),
         ('SC_DR03_2026-10-15', 'S3', 8, 1),
         ('SC_DR03_2026-10-15', 'S4', 7, 1),
         ('SC_DR03_2026-10-15', 'S5', 6, 1),
         ('SC_DR03_2026-10-15', 'S6', 5, 0),
         ('SC_DR03_2026-10-15', 'S7', 7, 1),
         ('SC_DR03_2026-10-15', 'S8', 6, 1),
         ('SC_DR03_2026-10-15', 'S9', 5, 1),
         ('SC_DR03_2026-10-15', 'S10', 4, 0),
         ('SC_DR03_2026-10-15', 'S11', 5, 1),
         ('SC_DR03_2026-10-15', 'S12', 6, 1),
         ('SC_DR03_2026-10-16', 'S1', 6, 1),
         ('SC_DR03_2026-10-16', 'S2', 7, 1),
         ('SC_DR03_2026-10-16', 'S3', 8, 2),
         ('SC_DR03_2026-10-16', 'S4', 4, 0),
         ('SC_DR03_2026-10-16', 'S5', 5, 0),
         ('SC_DR03_2026-10-16', 'S6', 7, 1),
         ('SC_DR03_2026-10-16', 'S7', 7, 1),
         ('SC_DR03_2026-10-16', 'S8', 7, 1),
         ('SC_DR03_2026-10-16', 'S9', 4, 0),
         ('SC_DR03_2026-10-16', 'S10', 5, 1),
         ('SC_DR03_2026-10-16', 'S11', 4, 0),
         ('SC_DR03_2026-10-16', 'S12', 7, 1),
         ('SC_DR03_2026-10-17', 'S1', 5, 0),
         ('SC_DR03_2026-10-17', 'S2', 8, 2),
         ('SC_DR03_2026-10-17', 'S3', 7, 1),
         ('SC_DR03_2026-10-17', 'S4', 7, 1),
         ('SC_DR03_2026-10-17', 'S5', 6, 1),
         ('SC_DR03_2026-10-17', 'S6', 4, 0),
         ('SC_DR03_2026-10-17', 'S7', 7, 1),
         ('SC_DR03_2026-10-17', 'S8', 6, 1),
         ('SC_DR03_2026-10-17', 'S9', 5, 1),
         ('SC_DR03_2026-10-17', 'S10', 6, 1),
         ('SC_DR03_2026-10-17', 'S11', 7, 1),
         ('SC_DR03_2026-10-17', 'S12', 4, 0),
         ('SC_DR03_2026-10-19', 'S1', 5, 0),
         ('SC_DR03_2026-10-19', 'S2', 4, 0),
         ('SC_DR03_2026-10-19', 'S3', 7, 1),
         ('SC_DR03_2026-10-19', 'S4', 5, 1),
         ('SC_DR03_2026-10-19', 'S5', 4, 0),
         ('SC_DR03_2026-10-19', 'S6', 8, 2),
         ('SC_DR03_2026-10-19', 'S7', 6, 1),
         ('SC_DR03_2026-10-19', 'S8', 4, 0),
         ('SC_DR03_2026-10-19', 'S9', 3, 0),
         ('SC_DR03_2026-10-19', 'S10', 5, 1),
         ('SC_DR03_2026-10-19', 'S11', 6, 1),
         ('SC_DR03_2026-10-19', 'S12', 7, 1),
         ('SC_DR03_2026-10-20', 'S1', 5, 0),
         ('SC_DR03_2026-10-20', 'S2', 4, 0),
         ('SC_DR03_2026-10-20', 'S3', 8, 1),
         ('SC_DR03_2026-10-20', 'S4', 6, 1),
         ('SC_DR03_2026-10-20', 'S5', 5, 1),
         ('SC_DR03_2026-10-20', 'S6', 4, 0),
         ('SC_DR03_2026-10-20', 'S7', 7, 1),
         ('SC_DR03_2026-10-20', 'S8', 4, 0),
         ('SC_DR03_2026-10-20', 'S9', 3, 0),
         ('SC_DR03_2026-10-20', 'S10', 7, 1),
         ('SC_DR03_2026-10-20', 'S11', 4, 0),
         ('SC_DR03_2026-10-20', 'S12', 5, 1),
         ('SC_DR04_2026-10-07', 'S1', 4, 4),
         ('SC_DR04_2026-10-07', 'S2', 4, 3),
         ('SC_DR04_2026-10-07', 'S3', 3, 2),
         ('SC_DR04_2026-10-07', 'S4', 2, 1),
         ('SC_DR04_2026-10-07', 'S5', 4, 4),
         ('SC_DR04_2026-10-07', 'S6', 3, 2),
         ('SC_DR04_2026-10-07', 'S7', 2, 1),
         ('SC_DR04_2026-10-07', 'S8', 3, 3),
         ('SC_DR04_2026-10-07', 'S9', 3, 2),
         ('SC_DR04_2026-10-07', 'S10', 3, 3),
         ('SC_DR04_2026-10-07', 'S11', 2, 1),
         ('SC_DR04_2026-10-07', 'S12', 2, 1),
         ('SC_DR04_2026-10-08', 'S1', 4, 4),
         ('SC_DR04_2026-10-08', 'S2', 3, 1),
         ('SC_DR04_2026-10-08', 'S3', 3, 2),
         ('SC_DR04_2026-10-08', 'S4', 3, 2),
         ('SC_DR04_2026-10-08', 'S5', 4, 3),
         ('SC_DR04_2026-10-08', 'S6', 2, 1),
         ('SC_DR04_2026-10-08', 'S7', 2, 1),
         ('SC_DR04_2026-10-08', 'S8', 3, 2),
         ('SC_DR04_2026-10-08', 'S9', 3, 2),
         ('SC_DR04_2026-10-08', 'S10', 2, 1),
         ('SC_DR04_2026-10-08', 'S11', 3, 2),
         ('SC_DR04_2026-10-08', 'S12', 3, 2),
         ('SC_DR04_2026-10-09', 'S1', 3, 1),
         ('SC_DR04_2026-10-09', 'S2', 2, 1),
         ('SC_DR04_2026-10-09', 'S3', 4, 3),
         ('SC_DR04_2026-10-09', 'S4', 4, 3),
         ('SC_DR04_2026-10-09', 'S5', 3, 2),
         ('SC_DR04_2026-10-09', 'S6', 2, 1),
         ('SC_DR04_2026-10-09', 'S7', 2, 0),
         ('SC_DR04_2026-10-09', 'S8', 3, 2),
         ('SC_DR04_2026-10-09', 'S9', 3, 2),
         ('SC_DR04_2026-10-09', 'S10', 2, 1),
         ('SC_DR04_2026-10-09', 'S11', 2, 1),
         ('SC_DR04_2026-10-09', 'S12', 3, 2),
         ('SC_DR04_2026-10-10', 'S1', 3, 1),
         ('SC_DR04_2026-10-10', 'S2', 3, 1),
         ('SC_DR04_2026-10-10', 'S3', 2, 0),
         ('SC_DR04_2026-10-10', 'S4', 3, 2),
         ('SC_DR04_2026-10-10', 'S5', 3, 1),
         ('SC_DR04_2026-10-10', 'S6', 2, 1),
         ('SC_DR04_2026-10-10', 'S7', 2, 0),
         ('SC_DR04_2026-10-10', 'S8', 2, 0),
         ('SC_DR04_2026-10-10', 'S9', 3, 2),
         ('SC_DR04_2026-10-10', 'S10', 2, 1),
         ('SC_DR04_2026-10-10', 'S11', 3, 1),
         ('SC_DR04_2026-10-10', 'S12', 3, 2),
         ('SC_DR04_2026-10-11', 'S1', 3, 1),
         ('SC_DR04_2026-10-11', 'S2', 3, 1),
         ('SC_DR04_2026-10-11', 'S3', 4, 2),
         ('SC_DR04_2026-10-11', 'S4', 2, 0),
         ('SC_DR04_2026-10-11', 'S5', 3, 1),
         ('SC_DR04_2026-10-11', 'S6', 3, 1),
         ('SC_DR04_2026-10-11', 'S7', 3, 1),
         ('SC_DR04_2026-10-11', 'S8', 2, 0),
         ('SC_DR04_2026-10-11', 'S9', 2, 0),
         ('SC_DR04_2026-10-11', 'S10', 3, 2),
         ('SC_DR04_2026-10-11', 'S11', 3, 1),
         ('SC_DR04_2026-10-11', 'S12', 2, 1),
         ('SC_DR04_2026-10-12', 'S1', 3, 1),
         ('SC_DR04_2026-10-12', 'S2', 2, 0),
         ('SC_DR04_2026-10-12', 'S3', 4, 2),
         ('SC_DR04_2026-10-12', 'S4', 3, 1),
         ('SC_DR04_2026-10-12', 'S5', 3, 1),
         ('SC_DR04_2026-10-12', 'S6', 2, 0),
         ('SC_DR04_2026-10-12', 'S7', 3, 1),
         ('SC_DR04_2026-10-12', 'S8', 4, 2),
         ('SC_DR04_2026-10-12', 'S9', 3, 1),
         ('SC_DR04_2026-10-12', 'S10', 2, 0),
         ('SC_DR04_2026-10-12', 'S11', 3, 1),
         ('SC_DR04_2026-10-12', 'S12', 3, 1),
         ('SC_DR04_2026-10-13', 'S1', 2, 0),
         ('SC_DR04_2026-10-13', 'S2', 3, 1),
         ('SC_DR04_2026-10-13', 'S3', 3, 1),
         ('SC_DR04_2026-10-13', 'S4', 4, 1),
         ('SC_DR04_2026-10-13', 'S5', 2, 0),
         ('SC_DR04_2026-10-13', 'S6', 3, 1),
         ('SC_DR04_2026-10-13', 'S7', 3, 1),
         ('SC_DR04_2026-10-13', 'S8', 2, 0),
         ('SC_DR04_2026-10-13', 'S9', 2, 0),
         ('SC_DR04_2026-10-13', 'S10', 3, 1),
         ('SC_DR04_2026-10-13', 'S11', 2, 0),
         ('SC_DR04_2026-10-13', 'S12', 2, 0),
         ('SC_DR04_2026-10-14', 'S1', 4, 1),
         ('SC_DR04_2026-10-14', 'S2', 4, 1),
         ('SC_DR04_2026-10-14', 'S3', 3, 0),
         ('SC_DR04_2026-10-14', 'S4', 3, 0),
         ('SC_DR04_2026-10-14', 'S5', 2, 0),
         ('SC_DR04_2026-10-14', 'S6', 4, 1),
         ('SC_DR04_2026-10-14', 'S7', 3, 1),
         ('SC_DR04_2026-10-14', 'S8', 2, 0),
         ('SC_DR04_2026-10-14', 'S9', 2, 0),
         ('SC_DR04_2026-10-14', 'S10', 2, 0),
         ('SC_DR04_2026-10-14', 'S11', 3, 0),
         ('SC_DR04_2026-10-14', 'S12', 3, 1),
         ('SC_DR04_2026-10-15', 'S1', 3, 0),
         ('SC_DR04_2026-10-15', 'S2', 3, 0),
         ('SC_DR04_2026-10-15', 'S3', 4, 1),
         ('SC_DR04_2026-10-15', 'S4', 2, 0),
         ('SC_DR04_2026-10-15', 'S5', 3, 0),
         ('SC_DR04_2026-10-15', 'S6', 4, 1),
         ('SC_DR04_2026-10-15', 'S7', 3, 1),
         ('SC_DR04_2026-10-15', 'S8', 4, 1),
         ('SC_DR04_2026-10-15', 'S9', 2, 0),
         ('SC_DR04_2026-10-15', 'S10', 3, 1),
         ('SC_DR04_2026-10-15', 'S11', 3, 0),
         ('SC_DR04_2026-10-15', 'S12', 2, 0),
         ('SC_DR04_2026-10-16', 'S1', 3, 0),
         ('SC_DR04_2026-10-16', 'S2', 2, 0),
         ('SC_DR04_2026-10-16', 'S3', 4, 1),
         ('SC_DR04_2026-10-16', 'S4', 4, 1),
         ('SC_DR04_2026-10-16', 'S5', 3, 0),
         ('SC_DR04_2026-10-16', 'S6', 3, 0),
         ('SC_DR04_2026-10-16', 'S7', 2, 0),
         ('SC_DR04_2026-10-16', 'S8', 3, 1),
         ('SC_DR04_2026-10-16', 'S9', 3, 0),
         ('SC_DR04_2026-10-16', 'S10', 2, 0),
         ('SC_DR04_2026-10-16', 'S11', 3, 0),
         ('SC_DR04_2026-10-16', 'S12', 3, 1),
         ('SC_DR04_2026-10-17', 'S1', 2, 0),
         ('SC_DR04_2026-10-17', 'S2', 3, 0),
         ('SC_DR04_2026-10-17', 'S3', 3, 0),
         ('SC_DR04_2026-10-17', 'S4', 4, 1),
         ('SC_DR04_2026-10-17', 'S5', 4, 1),
         ('SC_DR04_2026-10-17', 'S6', 3, 0),
         ('SC_DR04_2026-10-17', 'S7', 3, 0),
         ('SC_DR04_2026-10-17', 'S8', 3, 0),
         ('SC_DR04_2026-10-17', 'S9', 3, 1),
         ('SC_DR04_2026-10-17', 'S10', 3, 1),
         ('SC_DR04_2026-10-17', 'S11', 3, 0),
         ('SC_DR04_2026-10-17', 'S12', 2, 0),
         ('SC_DR04_2026-10-18', 'S1', 3, 0),
         ('SC_DR04_2026-10-18', 'S2', 3, 0),
         ('SC_DR04_2026-10-18', 'S3', 2, 0),
         ('SC_DR04_2026-10-18', 'S4', 3, 0),
         ('SC_DR04_2026-10-18', 'S5', 3, 0),
         ('SC_DR04_2026-10-18', 'S6', 2, 0),
         ('SC_DR04_2026-10-18', 'S7', 2, 0),
         ('SC_DR04_2026-10-18', 'S8', 3, 0),
         ('SC_DR04_2026-10-18', 'S9', 2, 0),
         ('SC_DR04_2026-10-18', 'S10', 2, 0),
         ('SC_DR04_2026-10-18', 'S11', 3, 0),
         ('SC_DR04_2026-10-18', 'S12', 3, 1),
         ('SC_DR04_2026-10-19', 'S1', 3, 0),
         ('SC_DR04_2026-10-19', 'S2', 4, 1),
         ('SC_DR04_2026-10-19', 'S3', 4, 1),
         ('SC_DR04_2026-10-19', 'S4', 2, 0),
         ('SC_DR04_2026-10-19', 'S5', 3, 0),
         ('SC_DR04_2026-10-19', 'S6', 3, 0),
         ('SC_DR04_2026-10-19', 'S7', 3, 1),
         ('SC_DR04_2026-10-19', 'S8', 3, 0),
         ('SC_DR04_2026-10-19', 'S9', 3, 0),
         ('SC_DR04_2026-10-19', 'S10', 2, 0),
         ('SC_DR04_2026-10-19', 'S11', 2, 0),
         ('SC_DR04_2026-10-19', 'S12', 3, 1),
         ('SC_DR04_2026-10-20', 'S1', 2, 0),
         ('SC_DR04_2026-10-20', 'S2', 3, 0),
         ('SC_DR04_2026-10-20', 'S3', 4, 1),
         ('SC_DR04_2026-10-20', 'S4', 2, 0),
         ('SC_DR04_2026-10-20', 'S5', 3, 0),
         ('SC_DR04_2026-10-20', 'S6', 3, 0),
         ('SC_DR04_2026-10-20', 'S7', 3, 1),
         ('SC_DR04_2026-10-20', 'S8', 3, 1),
         ('SC_DR04_2026-10-20', 'S9', 2, 0),
         ('SC_DR04_2026-10-20', 'S10', 2, 0),
         ('SC_DR04_2026-10-20', 'S11', 2, 0),
         ('SC_DR04_2026-10-20', 'S12', 3, 0),
         ('SC_DR05_2026-10-07', 'S1', 7, 6),
         ('SC_DR05_2026-10-07', 'S2', 4, 1),
         ('SC_DR05_2026-10-07', 'S3', 5, 3),
         ('SC_DR05_2026-10-07', 'S4', 7, 5),
         ('SC_DR05_2026-10-07', 'S5', 8, 7),
         ('SC_DR05_2026-10-07', 'S6', 5, 2),
         ('SC_DR05_2026-10-07', 'S7', 5, 3),
         ('SC_DR05_2026-10-07', 'S8', 6, 5),
         ('SC_DR05_2026-10-07', 'S9', 7, 7),
         ('SC_DR05_2026-10-07', 'S10', 3, 1),
         ('SC_DR05_2026-10-07', 'S11', 6, 5),
         ('SC_DR05_2026-10-07', 'S12', 5, 3),
         ('SC_DR05_2026-10-08', 'S1', 6, 3),
         ('SC_DR05_2026-10-08', 'S2', 5, 2),
         ('SC_DR05_2026-10-08', 'S3', 4, 1),
         ('SC_DR05_2026-10-08', 'S4', 8, 6),
         ('SC_DR05_2026-10-08', 'S5', 6, 4),
         ('SC_DR05_2026-10-08', 'S6', 5, 2),
         ('SC_DR05_2026-10-08', 'S7', 4, 1),
         ('SC_DR05_2026-10-08', 'S8', 5, 3),
         ('SC_DR05_2026-10-08', 'S9', 4, 2),
         ('SC_DR05_2026-10-08', 'S10', 5, 3),
         ('SC_DR05_2026-10-08', 'S11', 6, 4),
         ('SC_DR05_2026-10-08', 'S12', 3, 1),
         ('SC_DR05_2026-10-09', 'S1', 6, 3),
         ('SC_DR05_2026-10-09', 'S2', 7, 4),
         ('SC_DR05_2026-10-09', 'S3', 8, 6),
         ('SC_DR05_2026-10-09', 'S4', 6, 3),
         ('SC_DR05_2026-10-09', 'S5', 7, 4),
         ('SC_DR05_2026-10-09', 'S6', 8, 6),
         ('SC_DR05_2026-10-09', 'S7', 3, 1),
         ('SC_DR05_2026-10-09', 'S8', 5, 2),
         ('SC_DR05_2026-10-09', 'S9', 6, 4),
         ('SC_DR05_2026-10-09', 'S10', 6, 4),
         ('SC_DR05_2026-10-09', 'S11', 5, 3),
         ('SC_DR05_2026-10-09', 'S12', 4, 1),
         ('SC_DR05_2026-10-10', 'S1', 5, 2),
         ('SC_DR05_2026-10-10', 'S2', 7, 4),
         ('SC_DR05_2026-10-10', 'S3', 8, 5),
         ('SC_DR05_2026-10-10', 'S4', 5, 1),
         ('SC_DR05_2026-10-10', 'S5', 6, 2),
         ('SC_DR05_2026-10-10', 'S6', 7, 4),
         ('SC_DR05_2026-10-10', 'S7', 7, 5),
         ('SC_DR05_2026-10-10', 'S8', 4, 1),
         ('SC_DR05_2026-10-10', 'S9', 5, 2),
         ('SC_DR05_2026-10-10', 'S10', 5, 2),
         ('SC_DR05_2026-10-10', 'S11', 4, 1),
         ('SC_DR05_2026-10-10', 'S12', 3, 1),
         ('SC_DR05_2026-10-12', 'S1', 8, 4),
         ('SC_DR05_2026-10-12', 'S2', 5, 1),
         ('SC_DR05_2026-10-12', 'S3', 6, 2),
         ('SC_DR05_2026-10-12', 'S4', 7, 2),
         ('SC_DR05_2026-10-12', 'S5', 8, 3),
         ('SC_DR05_2026-10-12', 'S6', 4, 1),
         ('SC_DR05_2026-10-12', 'S7', 4, 1),
         ('SC_DR05_2026-10-12', 'S8', 5, 1),
         ('SC_DR05_2026-10-12', 'S9', 6, 2),
         ('SC_DR05_2026-10-12', 'S10', 6, 2),
         ('SC_DR05_2026-10-12', 'S11', 5, 2),
         ('SC_DR05_2026-10-12', 'S12', 4, 1),
         ('SC_DR05_2026-10-13', 'S1', 5, 1),
         ('SC_DR05_2026-10-13', 'S2', 8, 3),
         ('SC_DR05_2026-10-13', 'S3', 7, 2),
         ('SC_DR05_2026-10-13', 'S4', 5, 1),
         ('SC_DR05_2026-10-13', 'S5', 4, 0),
         ('SC_DR05_2026-10-13', 'S6', 8, 2),
         ('SC_DR05_2026-10-13', 'S7', 6, 2),
         ('SC_DR05_2026-10-13', 'S8', 6, 2),
         ('SC_DR05_2026-10-13', 'S9', 5, 1),
         ('SC_DR05_2026-10-13', 'S10', 4, 0),
         ('SC_DR05_2026-10-13', 'S11', 5, 1),
         ('SC_DR05_2026-10-13', 'S12', 5, 1),
         ('SC_DR05_2026-10-14', 'S1', 8, 2),
         ('SC_DR05_2026-10-14', 'S2', 4, 0),
         ('SC_DR05_2026-10-14', 'S3', 5, 1),
         ('SC_DR05_2026-10-14', 'S4', 6, 1),
         ('SC_DR05_2026-10-14', 'S5', 7, 1),
         ('SC_DR05_2026-10-14', 'S6', 4, 0),
         ('SC_DR05_2026-10-14', 'S7', 4, 0),
         ('SC_DR05_2026-10-14', 'S8', 5, 1),
         ('SC_DR05_2026-10-14', 'S9', 6, 1),
         ('SC_DR05_2026-10-14', 'S10', 5, 1),
         ('SC_DR05_2026-10-14', 'S11', 4, 0),
         ('SC_DR05_2026-10-14', 'S12', 4, 0),
         ('SC_DR05_2026-10-15', 'S1', 7, 1),
         ('SC_DR05_2026-10-15', 'S2', 5, 0),
         ('SC_DR05_2026-10-15', 'S3', 4, 0),
         ('SC_DR05_2026-10-15', 'S4', 8, 2),
         ('SC_DR05_2026-10-15', 'S5', 7, 1),
         ('SC_DR05_2026-10-15', 'S6', 5, 1),
         ('SC_DR05_2026-10-15', 'S7', 4, 0),
         ('SC_DR05_2026-10-15', 'S8', 3, 0),
         ('SC_DR05_2026-10-15', 'S9', 6, 1),
         ('SC_DR05_2026-10-15', 'S10', 4, 0),
         ('SC_DR05_2026-10-15', 'S11', 5, 1),
         ('SC_DR05_2026-10-15', 'S12', 6, 1),
         ('SC_DR05_2026-10-16', 'S1', 6, 1),
         ('SC_DR05_2026-10-16', 'S2', 7, 1),
         ('SC_DR05_2026-10-16', 'S3', 8, 2),
         ('SC_DR05_2026-10-16', 'S4', 5, 1),
         ('SC_DR05_2026-10-16', 'S5', 6, 1),
         ('SC_DR05_2026-10-16', 'S6', 8, 1),
         ('SC_DR05_2026-10-16', 'S7', 3, 0),
         ('SC_DR05_2026-10-16', 'S8', 3, 0),
         ('SC_DR05_2026-10-16', 'S9', 4, 0),
         ('SC_DR05_2026-10-16', 'S10', 6, 1),
         ('SC_DR05_2026-10-16', 'S11', 5, 1),
         ('SC_DR05_2026-10-16', 'S12', 4, 0),
         ('SC_DR05_2026-10-17', 'S1', 4, 0),
         ('SC_DR05_2026-10-17', 'S2', 8, 1),
         ('SC_DR05_2026-10-17', 'S3', 7, 1),
         ('SC_DR05_2026-10-17', 'S4', 6, 1),
         ('SC_DR05_2026-10-17', 'S5', 4, 0),
         ('SC_DR05_2026-10-17', 'S6', 8, 2),
         ('SC_DR05_2026-10-17', 'S7', 6, 1),
         ('SC_DR05_2026-10-17', 'S8', 5, 1),
         ('SC_DR05_2026-10-17', 'S9', 4, 0),
         ('SC_DR05_2026-10-17', 'S10', 5, 1),
         ('SC_DR05_2026-10-17', 'S11', 6, 1),
         ('SC_DR05_2026-10-17', 'S12', 7, 1),
         ('SC_DR05_2026-10-19', 'S1', 7, 1),
         ('SC_DR05_2026-10-19', 'S2', 5, 0),
         ('SC_DR05_2026-10-19', 'S3', 4, 0),
         ('SC_DR05_2026-10-19', 'S4', 7, 1),
         ('SC_DR05_2026-10-19', 'S5', 6, 1),
         ('SC_DR05_2026-10-19', 'S6', 5, 0),
         ('SC_DR05_2026-10-19', 'S7', 7, 1),
         ('SC_DR05_2026-10-19', 'S8', 6, 1),
         ('SC_DR05_2026-10-19', 'S9', 5, 1),
         ('SC_DR05_2026-10-19', 'S10', 4, 0),
         ('SC_DR05_2026-10-19', 'S11', 5, 1),
         ('SC_DR05_2026-10-19', 'S12', 6, 1),
         ('SC_DR05_2026-10-20', 'S1', 6, 1),
         ('SC_DR05_2026-10-20', 'S2', 5, 0),
         ('SC_DR05_2026-10-20', 'S3', 4, 0),
         ('SC_DR05_2026-10-20', 'S4', 7, 1),
         ('SC_DR05_2026-10-20', 'S5', 6, 1),
         ('SC_DR05_2026-10-20', 'S6', 4, 0),
         ('SC_DR05_2026-10-20', 'S7', 7, 1),
         ('SC_DR05_2026-10-20', 'S8', 6, 1),
         ('SC_DR05_2026-10-20', 'S9', 5, 1),
         ('SC_DR05_2026-10-20', 'S10', 5, 1),
         ('SC_DR05_2026-10-20', 'S11', 5, 1),
         ('SC_DR05_2026-10-20', 'S12', 4, 0),
         ('SC_DR06_2026-10-07', 'S1', 5, 4),
         ('SC_DR06_2026-10-07', 'S2', 4, 2),
         ('SC_DR06_2026-10-07', 'S3', 3, 1),
         ('SC_DR06_2026-10-07', 'S4', 2, 1),
         ('SC_DR06_2026-10-07', 'S5', 5, 4),
         ('SC_DR06_2026-10-07', 'S6', 4, 2),
         ('SC_DR06_2026-10-07', 'S7', 3, 1),
         ('SC_DR06_2026-10-07', 'S8', 3, 2),
         ('SC_DR06_2026-10-07', 'S9', 2, 1),
         ('SC_DR06_2026-10-07', 'S10', 3, 2),
         ('SC_DR06_2026-10-07', 'S11', 4, 3),
         ('SC_DR06_2026-10-07', 'S12', 5, 5),
         ('SC_DR06_2026-10-08', 'S1', 3, 1),
         ('SC_DR06_2026-10-08', 'S2', 4, 2),
         ('SC_DR06_2026-10-08', 'S3', 4, 3),
         ('SC_DR06_2026-10-08', 'S4', 5, 4),
         ('SC_DR06_2026-10-08', 'S5', 3, 1),
         ('SC_DR06_2026-10-08', 'S6', 3, 1),
         ('SC_DR06_2026-10-08', 'S7', 3, 2),
         ('SC_DR06_2026-10-08', 'S8', 4, 3),
         ('SC_DR06_2026-10-08', 'S9', 5, 4),
         ('SC_DR06_2026-10-08', 'S10', 2, 1),
         ('SC_DR06_2026-10-08', 'S11', 4, 3),
         ('SC_DR06_2026-10-08', 'S12', 4, 2),
         ('SC_DR06_2026-10-09', 'S1', 5, 3),
         ('SC_DR06_2026-10-09', 'S2', 4, 2),
         ('SC_DR06_2026-10-09', 'S3', 3, 1),
         ('SC_DR06_2026-10-09', 'S4', 5, 4),
         ('SC_DR06_2026-10-09', 'S5', 4, 2),
         ('SC_DR06_2026-10-09', 'S6', 4, 2),
         ('SC_DR06_2026-10-09', 'S7', 3, 1),
         ('SC_DR06_2026-10-09', 'S8', 3, 1),
         ('SC_DR06_2026-10-09', 'S9', 5, 4),
         ('SC_DR06_2026-10-09', 'S10', 3, 1),
         ('SC_DR06_2026-10-09', 'S11', 4, 2),
         ('SC_DR06_2026-10-09', 'S12', 5, 4),
         ('SC_DR06_2026-10-10', 'S1', 4, 1),
         ('SC_DR06_2026-10-10', 'S2', 3, 1),
         ('SC_DR06_2026-10-10', 'S3', 5, 3),
         ('SC_DR06_2026-10-10', 'S4', 4, 2),
         ('SC_DR06_2026-10-10', 'S5', 3, 1),
         ('SC_DR06_2026-10-10', 'S6', 5, 3),
         ('SC_DR06_2026-10-10', 'S7', 4, 2),
         ('SC_DR06_2026-10-10', 'S8', 3, 1),
         ('SC_DR06_2026-10-10', 'S9', 2, 0),
         ('SC_DR06_2026-10-10', 'S10', 4, 2),
         ('SC_DR06_2026-10-10', 'S11', 5, 3),
         ('SC_DR06_2026-10-10', 'S12', 3, 1),
         ('SC_DR06_2026-10-12', 'S1', 3, 1),
         ('SC_DR06_2026-10-12', 'S2', 3, 0),
         ('SC_DR06_2026-10-12', 'S3', 5, 2),
         ('SC_DR06_2026-10-12', 'S4', 4, 1),
         ('SC_DR06_2026-10-12', 'S5', 3, 1),
         ('SC_DR06_2026-10-12', 'S6', 5, 2),
         ('SC_DR06_2026-10-12', 'S7', 4, 1),
         ('SC_DR06_2026-10-12', 'S8', 3, 1),
         ('SC_DR06_2026-10-12', 'S9', 2, 0),
         ('SC_DR06_2026-10-12', 'S10', 3, 1),
         ('SC_DR06_2026-10-12', 'S11', 4, 1),
         ('SC_DR06_2026-10-12', 'S12', 4, 2),
         ('SC_DR06_2026-10-13', 'S1', 6, 2),
         ('SC_DR06_2026-10-13', 'S2', 3, 0),
         ('SC_DR06_2026-10-13', 'S3', 4, 1),
         ('SC_DR06_2026-10-13', 'S4', 5, 1),
         ('SC_DR06_2026-10-13', 'S5', 5, 2),
         ('SC_DR06_2026-10-13', 'S6', 3, 0),
         ('SC_DR06_2026-10-13', 'S7', 3, 1),
         ('SC_DR06_2026-10-13', 'S8', 5, 2),
         ('SC_DR06_2026-10-13', 'S9', 3, 0),
         ('SC_DR06_2026-10-13', 'S10', 4, 1),
         ('SC_DR06_2026-10-13', 'S11', 3, 1),
         ('SC_DR06_2026-10-13', 'S12', 2, 0),
         ('SC_DR06_2026-10-14', 'S1', 4, 1),
         ('SC_DR06_2026-10-14', 'S2', 3, 0),
         ('SC_DR06_2026-10-14', 'S3', 5, 1),
         ('SC_DR06_2026-10-14', 'S4', 3, 0),
         ('SC_DR06_2026-10-14', 'S5', 5, 1),
         ('SC_DR06_2026-10-14', 'S6', 4, 1),
         ('SC_DR06_2026-10-14', 'S7', 3, 0),
         ('SC_DR06_2026-10-14', 'S8', 3, 0),
         ('SC_DR06_2026-10-14', 'S9', 3, 0),
         ('SC_DR06_2026-10-14', 'S10', 4, 1),
         ('SC_DR06_2026-10-14', 'S11', 4, 1),
         ('SC_DR06_2026-10-14', 'S12', 2, 0),
         ('SC_DR06_2026-10-15', 'S1', 5, 1),
         ('SC_DR06_2026-10-15', 'S2', 3, 0),
         ('SC_DR06_2026-10-15', 'S3', 4, 0),
         ('SC_DR06_2026-10-15', 'S4', 3, 0),
         ('SC_DR06_2026-10-15', 'S5', 4, 1),
         ('SC_DR06_2026-10-15', 'S6', 3, 0),
         ('SC_DR06_2026-10-15', 'S7', 2, 0),
         ('SC_DR06_2026-10-15', 'S8', 5, 1),
         ('SC_DR06_2026-10-15', 'S9', 2, 0),
         ('SC_DR06_2026-10-15', 'S10', 3, 0),
         ('SC_DR06_2026-10-15', 'S11', 3, 0),
         ('SC_DR06_2026-10-15', 'S12', 5, 1),
         ('SC_DR06_2026-10-16', 'S1', 5, 1),
         ('SC_DR06_2026-10-16', 'S2', 4, 0),
         ('SC_DR06_2026-10-16', 'S3', 3, 0),
         ('SC_DR06_2026-10-16', 'S4', 2, 0),
         ('SC_DR06_2026-10-16', 'S5', 5, 1),
         ('SC_DR06_2026-10-16', 'S6', 4, 1),
         ('SC_DR06_2026-10-16', 'S7', 3, 0),
         ('SC_DR06_2026-10-16', 'S8', 4, 1),
         ('SC_DR06_2026-10-16', 'S9', 3, 0),
         ('SC_DR06_2026-10-16', 'S10', 4, 1),
         ('SC_DR06_2026-10-16', 'S11', 2, 0),
         ('SC_DR06_2026-10-16', 'S12', 3, 0),
         ('SC_DR06_2026-10-17', 'S1', 5, 1),
         ('SC_DR06_2026-10-17', 'S2', 5, 1),
         ('SC_DR06_2026-10-17', 'S3', 3, 0),
         ('SC_DR06_2026-10-17', 'S4', 4, 1),
         ('SC_DR06_2026-10-17', 'S5', 5, 1),
         ('SC_DR06_2026-10-17', 'S6', 3, 0),
         ('SC_DR06_2026-10-17', 'S7', 3, 0),
         ('SC_DR06_2026-10-17', 'S8', 4, 1),
         ('SC_DR06_2026-10-17', 'S9', 5, 1),
         ('SC_DR06_2026-10-17', 'S10', 2, 0),
         ('SC_DR06_2026-10-17', 'S11', 4, 1),
         ('SC_DR06_2026-10-17', 'S12', 4, 1),
         ('SC_DR06_2026-10-18', 'S1', 5, 1),
         ('SC_DR06_2026-10-18', 'S2', 4, 1),
         ('SC_DR06_2026-10-18', 'S3', 3, 0),
         ('SC_DR06_2026-10-18', 'S4', 5, 1),
         ('SC_DR06_2026-10-18', 'S5', 5, 1),
         ('SC_DR06_2026-10-18', 'S6', 4, 0),
         ('SC_DR06_2026-10-18', 'S7', 3, 0),
         ('SC_DR06_2026-10-18', 'S8', 3, 0),
         ('SC_DR06_2026-10-18', 'S9', 2, 0),
         ('SC_DR06_2026-10-18', 'S10', 4, 1),
         ('SC_DR06_2026-10-18', 'S11', 5, 1),
         ('SC_DR06_2026-10-18', 'S12', 3, 0),
         ('SC_DR06_2026-10-19', 'S1', 3, 0),
         ('SC_DR06_2026-10-19', 'S2', 4, 1),
         ('SC_DR06_2026-10-19', 'S3', 5, 1),
         ('SC_DR06_2026-10-19', 'S4', 3, 0),
         ('SC_DR06_2026-10-19', 'S5', 4, 0),
         ('SC_DR06_2026-10-19', 'S6', 5, 1),
         ('SC_DR06_2026-10-19', 'S7', 5, 1),
         ('SC_DR06_2026-10-19', 'S8', 3, 0),
         ('SC_DR06_2026-10-19', 'S9', 3, 0),
         ('SC_DR06_2026-10-19', 'S10', 2, 0),
         ('SC_DR06_2026-10-19', 'S11', 4, 1),
         ('SC_DR06_2026-10-19', 'S12', 4, 1),
         ('SC_DR06_2026-10-20', 'S1', 5, 1),
         ('SC_DR06_2026-10-20', 'S2', 3, 0),
         ('SC_DR06_2026-10-20', 'S3', 4, 0),
         ('SC_DR06_2026-10-20', 'S4', 5, 1),
         ('SC_DR06_2026-10-20', 'S5', 2, 0),
         ('SC_DR06_2026-10-20', 'S6', 4, 0),
         ('SC_DR06_2026-10-20', 'S7', 4, 1),
         ('SC_DR06_2026-10-20', 'S8', 4, 1),
         ('SC_DR06_2026-10-20', 'S9', 2, 0),
         ('SC_DR06_2026-10-20', 'S10', 4, 1),
         ('SC_DR06_2026-10-20', 'S11', 4, 1),
         ('SC_DR06_2026-10-20', 'S12', 3, 0),
         ('SC_DR07_2026-10-07', 'S1', 5, 2),
         ('SC_DR07_2026-10-07', 'S2', 6, 4),
         ('SC_DR07_2026-10-07', 'S3', 7, 6),
         ('SC_DR07_2026-10-07', 'S4', 8, 8),
         ('SC_DR07_2026-10-07', 'S5', 5, 2),
         ('SC_DR07_2026-10-07', 'S6', 6, 3),
         ('SC_DR07_2026-10-07', 'S7', 6, 5),
         ('SC_DR07_2026-10-07', 'S8', 7, 6),
         ('SC_DR07_2026-10-07', 'S9', 4, 1),
         ('SC_DR07_2026-10-07', 'S10', 3, 1),
         ('SC_DR07_2026-10-07', 'S11', 7, 6),
         ('SC_DR07_2026-10-07', 'S12', 5, 3),
         ('SC_DR07_2026-10-08', 'S1', 6, 3),
         ('SC_DR07_2026-10-08', 'S2', 4, 1),
         ('SC_DR07_2026-10-08', 'S3', 8, 7),
         ('SC_DR07_2026-10-08', 'S4', 8, 6),
         ('SC_DR07_2026-10-08', 'S5', 6, 4),
         ('SC_DR07_2026-10-08', 'S6', 5, 2),
         ('SC_DR07_2026-10-08', 'S7', 3, 1),
         ('SC_DR07_2026-10-08', 'S8', 5, 3),
         ('SC_DR07_2026-10-08', 'S9', 4, 2),
         ('SC_DR07_2026-10-08', 'S10', 5, 2),
         ('SC_DR07_2026-10-08', 'S11', 5, 3),
         ('SC_DR07_2026-10-08', 'S12', 7, 6),
         ('SC_DR07_2026-10-09', 'S1', 7, 5),
         ('SC_DR07_2026-10-09', 'S2', 4, 1),
         ('SC_DR07_2026-10-09', 'S3', 5, 2),
         ('SC_DR07_2026-10-09', 'S4', 6, 3),
         ('SC_DR07_2026-10-09', 'S5', 7, 4),
         ('SC_DR07_2026-10-09', 'S6', 8, 6),
         ('SC_DR07_2026-10-09', 'S7', 4, 1),
         ('SC_DR07_2026-10-09', 'S8', 6, 4),
         ('SC_DR07_2026-10-09', 'S9', 7, 5),
         ('SC_DR07_2026-10-09', 'S10', 5, 2),
         ('SC_DR07_2026-10-09', 'S11', 4, 1),
         ('SC_DR07_2026-10-09', 'S12', 3, 1),
         ('SC_DR07_2026-10-10', 'S1', 8, 5),
         ('SC_DR07_2026-10-10', 'S2', 5, 1),
         ('SC_DR07_2026-10-10', 'S3', 6, 2),
         ('SC_DR07_2026-10-10', 'S4', 8, 5),
         ('SC_DR07_2026-10-10', 'S5', 4, 1),
         ('SC_DR07_2026-10-10', 'S6', 5, 2),
         ('SC_DR07_2026-10-10', 'S7', 5, 2),
         ('SC_DR07_2026-10-10', 'S8', 5, 2),
         ('SC_DR07_2026-10-10', 'S9', 6, 3),
         ('SC_DR07_2026-10-10', 'S10', 5, 2),
         ('SC_DR07_2026-10-10', 'S11', 4, 1),
         ('SC_DR07_2026-10-10', 'S12', 7, 5),
         ('SC_DR07_2026-10-11', 'S1', 5, 1),
         ('SC_DR07_2026-10-11', 'S2', 4, 1),
         ('SC_DR07_2026-10-11', 'S3', 8, 4),
         ('SC_DR07_2026-10-11', 'S4', 7, 3),
         ('SC_DR07_2026-10-11', 'S5', 6, 2),
         ('SC_DR07_2026-10-11', 'S6', 5, 1),
         ('SC_DR07_2026-10-11', 'S7', 7, 4),
         ('SC_DR07_2026-10-11', 'S8', 6, 3),
         ('SC_DR07_2026-10-11', 'S9', 5, 2),
         ('SC_DR07_2026-10-11', 'S10', 4, 1),
         ('SC_DR07_2026-10-11', 'S11', 5, 2),
         ('SC_DR07_2026-10-11', 'S12', 6, 3),
         ('SC_DR07_2026-10-12', 'S1', 5, 1),
         ('SC_DR07_2026-10-12', 'S2', 7, 2),
         ('SC_DR07_2026-10-12', 'S3', 8, 3),
         ('SC_DR07_2026-10-12', 'S4', 4, 1),
         ('SC_DR07_2026-10-12', 'S5', 5, 1),
         ('SC_DR07_2026-10-12', 'S6', 7, 2),
         ('SC_DR07_2026-10-12', 'S7', 6, 2),
         ('SC_DR07_2026-10-12', 'S8', 7, 3),
         ('SC_DR07_2026-10-12', 'S9', 4, 1),
         ('SC_DR07_2026-10-12', 'S10', 3, 0),
         ('SC_DR07_2026-10-12', 'S11', 7, 3),
         ('SC_DR07_2026-10-12', 'S12', 6, 2),
         ('SC_DR07_2026-10-13', 'S1', 4, 0),
         ('SC_DR07_2026-10-13', 'S2', 7, 2),
         ('SC_DR07_2026-10-13', 'S3', 6, 1),
         ('SC_DR07_2026-10-13', 'S4', 6, 1),
         ('SC_DR07_2026-10-13', 'S5', 4, 1),
         ('SC_DR07_2026-10-13', 'S6', 8, 2),
         ('SC_DR07_2026-10-13', 'S7', 6, 1),
         ('SC_DR07_2026-10-13', 'S8', 5, 1),
         ('SC_DR07_2026-10-13', 'S9', 4, 1),
         ('SC_DR07_2026-10-13', 'S10', 7, 2),
         ('SC_DR07_2026-10-13', 'S11', 3, 0),
         ('SC_DR07_2026-10-13', 'S12', 5, 1),
         ('SC_DR07_2026-10-14', 'S1', 8, 2),
         ('SC_DR07_2026-10-14', 'S2', 5, 0),
         ('SC_DR07_2026-10-14', 'S3', 6, 1),
         ('SC_DR07_2026-10-14', 'S4', 7, 1),
         ('SC_DR07_2026-10-14', 'S5', 8, 2),
         ('SC_DR07_2026-10-14', 'S6', 4, 0),
         ('SC_DR07_2026-10-14', 'S7', 4, 0),
         ('SC_DR07_2026-10-14', 'S8', 5, 1),
         ('SC_DR07_2026-10-14', 'S9', 6, 1),
         ('SC_DR07_2026-10-14', 'S10', 4, 0),
         ('SC_DR07_2026-10-14', 'S11', 4, 0),
         ('SC_DR07_2026-10-14', 'S12', 6, 1),
         ('SC_DR07_2026-10-15', 'S1', 4, 0),
         ('SC_DR07_2026-10-15', 'S2', 8, 1),
         ('SC_DR07_2026-10-15', 'S3', 7, 1),
         ('SC_DR07_2026-10-15', 'S4', 5, 0),
         ('SC_DR07_2026-10-15', 'S5', 4, 0),
         ('SC_DR07_2026-10-15', 'S6', 7, 1),
         ('SC_DR07_2026-10-15', 'S7', 5, 1),
         ('SC_DR07_2026-10-15', 'S8', 5, 1),
         ('SC_DR07_2026-10-15', 'S9', 4, 0),
         ('SC_DR07_2026-10-15', 'S10', 7, 1),
         ('SC_DR07_2026-10-15', 'S11', 3, 0),
         ('SC_DR07_2026-10-15', 'S12', 4, 0),
         ('SC_DR07_2026-10-16', 'S1', 4, 0),
         ('SC_DR07_2026-10-16', 'S2', 6, 1),
         ('SC_DR07_2026-10-16', 'S3', 7, 1),
         ('SC_DR07_2026-10-16', 'S4', 4, 0),
         ('SC_DR07_2026-10-16', 'S5', 5, 0),
         ('SC_DR07_2026-10-16', 'S6', 6, 1),
         ('SC_DR07_2026-10-16', 'S7', 6, 1),
         ('SC_DR07_2026-10-16', 'S8', 4, 0),
         ('SC_DR07_2026-10-16', 'S9', 5, 1),
         ('SC_DR07_2026-10-16', 'S10', 6, 1),
         ('SC_DR07_2026-10-16', 'S11', 5, 1),
         ('SC_DR07_2026-10-16', 'S12', 4, 0),
         ('SC_DR07_2026-10-17', 'S1', 7, 1),
         ('SC_DR07_2026-10-17', 'S2', 5, 1),
         ('SC_DR07_2026-10-17', 'S3', 4, 0),
         ('SC_DR07_2026-10-17', 'S4', 7, 1),
         ('SC_DR07_2026-10-17', 'S5', 6, 1),
         ('SC_DR07_2026-10-17', 'S6', 5, 0),
         ('SC_DR07_2026-10-17', 'S7', 3, 0),
         ('SC_DR07_2026-10-17', 'S8', 3, 0),
         ('SC_DR07_2026-10-17', 'S9', 7, 1),
         ('SC_DR07_2026-10-17', 'S10', 5, 1),
         ('SC_DR07_2026-10-17', 'S11', 6, 1),
         ('SC_DR07_2026-10-17', 'S12', 7, 1),
         ('SC_DR07_2026-10-19', 'S1', 6, 1),
         ('SC_DR07_2026-10-19', 'S2', 5, 0),
         ('SC_DR07_2026-10-19', 'S3', 4, 0),
         ('SC_DR07_2026-10-19', 'S4', 8, 1),
         ('SC_DR07_2026-10-19', 'S5', 7, 1),
         ('SC_DR07_2026-10-19', 'S6', 6, 1),
         ('SC_DR07_2026-10-19', 'S7', 4, 0),
         ('SC_DR07_2026-10-19', 'S8', 5, 1),
         ('SC_DR07_2026-10-19', 'S9', 4, 0),
         ('SC_DR07_2026-10-19', 'S10', 7, 1),
         ('SC_DR07_2026-10-19', 'S11', 4, 0),
         ('SC_DR07_2026-10-19', 'S12', 4, 0),
         ('SC_DR07_2026-10-20', 'S1', 5, 0),
         ('SC_DR07_2026-10-20', 'S2', 4, 0),
         ('SC_DR07_2026-10-20', 'S3', 7, 1),
         ('SC_DR07_2026-10-20', 'S4', 5, 1),
         ('SC_DR07_2026-10-20', 'S5', 4, 0),
         ('SC_DR07_2026-10-20', 'S6', 8, 2),
         ('SC_DR07_2026-10-20', 'S7', 6, 1),
         ('SC_DR07_2026-10-20', 'S8', 6, 1),
         ('SC_DR07_2026-10-20', 'S9', 5, 1),
         ('SC_DR07_2026-10-20', 'S10', 7, 1),
         ('SC_DR07_2026-10-20', 'S11', 3, 0),
         ('SC_DR07_2026-10-20', 'S12', 4, 0),
         ('SC_DR08_2026-10-07', 'S1', 2, 1),
         ('SC_DR08_2026-10-07', 'S2', 2, 1),
         ('SC_DR08_2026-10-07', 'S3', 4, 3),
         ('SC_DR08_2026-10-07', 'S4', 3, 2),
         ('SC_DR08_2026-10-07', 'S5', 3, 2),
         ('SC_DR08_2026-10-07', 'S6', 2, 1),
         ('SC_DR08_2026-10-07', 'S7', 3, 3),
         ('SC_DR08_2026-10-07', 'S8', 3, 2),
         ('SC_DR08_2026-10-07', 'S9', 2, 1),
         ('SC_DR08_2026-10-07', 'S10', 3, 3),
         ('SC_DR08_2026-10-07', 'S11', 2, 1),
         ('SC_DR08_2026-10-07', 'S12', 2, 1),
         ('SC_DR08_2026-10-08', 'S1', 4, 3),
         ('SC_DR08_2026-10-08', 'S2', 2, 1),
         ('SC_DR08_2026-10-08', 'S3', 3, 1),
         ('SC_DR08_2026-10-08', 'S4', 3, 2),
         ('SC_DR08_2026-10-08', 'S5', 4, 3),
         ('SC_DR08_2026-10-08', 'S6', 2, 1),
         ('SC_DR08_2026-10-08', 'S7', 2, 1),
         ('SC_DR08_2026-10-08', 'S8', 2, 1),
         ('SC_DR08_2026-10-08', 'S9', 3, 2),
         ('SC_DR08_2026-10-08', 'S10', 3, 2),
         ('SC_DR08_2026-10-08', 'S11', 3, 2),
         ('SC_DR08_2026-10-08', 'S12', 2, 1),
         ('SC_DR08_2026-10-09', 'S1', 2, 1),
         ('SC_DR08_2026-10-09', 'S2', 4, 3),
         ('SC_DR08_2026-10-09', 'S3', 4, 2),
         ('SC_DR08_2026-10-09', 'S4', 3, 1),
         ('SC_DR08_2026-10-09', 'S5', 2, 1),
         ('SC_DR08_2026-10-09', 'S6', 4, 3),
         ('SC_DR08_2026-10-09', 'S7', 3, 2),
         ('SC_DR08_2026-10-09', 'S8', 2, 1),
         ('SC_DR08_2026-10-09', 'S9', 2, 0),
         ('SC_DR08_2026-10-09', 'S10', 2, 1),
         ('SC_DR08_2026-10-09', 'S11', 3, 2),
         ('SC_DR08_2026-10-09', 'S12', 3, 2),
         ('SC_DR08_2026-10-10', 'S1', 2, 0),
         ('SC_DR08_2026-10-10', 'S2', 4, 2),
         ('SC_DR08_2026-10-10', 'S3', 3, 1),
         ('SC_DR08_2026-10-10', 'S4', 3, 1),
         ('SC_DR08_2026-10-10', 'S5', 2, 0),
         ('SC_DR08_2026-10-10', 'S6', 4, 2),
         ('SC_DR08_2026-10-10', 'S7', 3, 2),
         ('SC_DR08_2026-10-10', 'S8', 2, 1),
         ('SC_DR08_2026-10-10', 'S9', 2, 1),
         ('SC_DR08_2026-10-10', 'S10', 3, 1),
         ('SC_DR08_2026-10-10', 'S11', 3, 2),
         ('SC_DR08_2026-10-10', 'S12', 2, 0),
         ('SC_DR08_2026-10-11', 'S1', 3, 1),
         ('SC_DR08_2026-10-11', 'S2', 4, 2),
         ('SC_DR08_2026-10-11', 'S3', 2, 0),
         ('SC_DR08_2026-10-11', 'S4', 3, 1),
         ('SC_DR08_2026-10-11', 'S5', 4, 2),
         ('SC_DR08_2026-10-11', 'S6', 2, 0),
         ('SC_DR08_2026-10-11', 'S7', 2, 0),
         ('SC_DR08_2026-10-11', 'S8', 2, 0),
         ('SC_DR08_2026-10-11', 'S9', 3, 1),
         ('SC_DR08_2026-10-11', 'S10', 3, 2),
         ('SC_DR08_2026-10-11', 'S11', 3, 1),
         ('SC_DR08_2026-10-11', 'S12', 2, 1),
         ('SC_DR08_2026-10-12', 'S1', 3, 1),
         ('SC_DR08_2026-10-12', 'S2', 2, 0),
         ('SC_DR08_2026-10-12', 'S3', 4, 2),
         ('SC_DR08_2026-10-12', 'S4', 4, 2),
         ('SC_DR08_2026-10-12', 'S5', 3, 1),
         ('SC_DR08_2026-10-12', 'S6', 2, 0),
         ('SC_DR08_2026-10-12', 'S7', 2, 0),
         ('SC_DR08_2026-10-12', 'S8', 3, 1),
         ('SC_DR08_2026-10-12', 'S9', 3, 1),
         ('SC_DR08_2026-10-12', 'S10', 3, 1),
         ('SC_DR08_2026-10-12', 'S11', 3, 1),
         ('SC_DR08_2026-10-12', 'S12', 2, 0),
         ('SC_DR08_2026-10-13', 'S1', 2, 0),
         ('SC_DR08_2026-10-13', 'S2', 3, 1),
         ('SC_DR08_2026-10-13', 'S3', 3, 1),
         ('SC_DR08_2026-10-13', 'S4', 4, 1),
         ('SC_DR08_2026-10-13', 'S5', 4, 1),
         ('SC_DR08_2026-10-13', 'S6', 3, 1),
         ('SC_DR08_2026-10-13', 'S7', 3, 1),
         ('SC_DR08_2026-10-13', 'S8', 3, 1),
         ('SC_DR08_2026-10-13', 'S9', 3, 1),
         ('SC_DR08_2026-10-13', 'S10', 2, 0),
         ('SC_DR08_2026-10-13', 'S11', 2, 0),
         ('SC_DR08_2026-10-13', 'S12', 3, 1),
         ('SC_DR08_2026-10-14', 'S1', 4, 1),
         ('SC_DR08_2026-10-14', 'S2', 3, 0),
         ('SC_DR08_2026-10-14', 'S3', 3, 0),
         ('SC_DR08_2026-10-14', 'S4', 4, 1),
         ('SC_DR08_2026-10-14', 'S5', 4, 1),
         ('SC_DR08_2026-10-14', 'S6', 3, 0),
         ('SC_DR08_2026-10-14', 'S7', 2, 0),
         ('SC_DR08_2026-10-14', 'S8', 2, 0),
         ('SC_DR08_2026-10-14', 'S9', 2, 0),
         ('SC_DR08_2026-10-14', 'S10', 3, 0),
         ('SC_DR08_2026-10-14', 'S11', 3, 1),
         ('SC_DR08_2026-10-14', 'S12', 4, 1),
         ('SC_DR08_2026-10-15', 'S1', 4, 1),
         ('SC_DR08_2026-10-15', 'S2', 4, 1),
         ('SC_DR08_2026-10-15', 'S3', 2, 0),
         ('SC_DR08_2026-10-15', 'S4', 3, 0),
         ('SC_DR08_2026-10-15', 'S5', 3, 0),
         ('SC_DR08_2026-10-15', 'S6', 4, 1),
         ('SC_DR08_2026-10-15', 'S7', 2, 0),
         ('SC_DR08_2026-10-15', 'S8', 2, 0),
         ('SC_DR08_2026-10-15', 'S9', 3, 0),
         ('SC_DR08_2026-10-15', 'S10', 2, 0),
         ('SC_DR08_2026-10-15', 'S11', 3, 1),
         ('SC_DR08_2026-10-15', 'S12', 2, 0),
         ('SC_DR08_2026-10-16', 'S1', 3, 0),
         ('SC_DR08_2026-10-16', 'S2', 2, 0),
         ('SC_DR08_2026-10-16', 'S3', 4, 1),
         ('SC_DR08_2026-10-16', 'S4', 3, 0),
         ('SC_DR08_2026-10-16', 'S5', 2, 0),
         ('SC_DR08_2026-10-16', 'S6', 4, 1),
         ('SC_DR08_2026-10-16', 'S7', 3, 0),
         ('SC_DR08_2026-10-16', 'S8', 3, 1),
         ('SC_DR08_2026-10-16', 'S9', 3, 0),
         ('SC_DR08_2026-10-16', 'S10', 2, 0),
         ('SC_DR08_2026-10-16', 'S11', 2, 0),
         ('SC_DR08_2026-10-16', 'S12', 3, 0),
         ('SC_DR08_2026-10-17', 'S1', 3, 0),
         ('SC_DR08_2026-10-17', 'S2', 4, 1),
         ('SC_DR08_2026-10-17', 'S3', 2, 0),
         ('SC_DR08_2026-10-17', 'S4', 3, 0),
         ('SC_DR08_2026-10-17', 'S5', 3, 0),
         ('SC_DR08_2026-10-17', 'S6', 4, 1),
         ('SC_DR08_2026-10-17', 'S7', 2, 0),
         ('SC_DR08_2026-10-17', 'S8', 3, 0),
         ('SC_DR08_2026-10-17', 'S9', 3, 0),
         ('SC_DR08_2026-10-17', 'S10', 2, 0),
         ('SC_DR08_2026-10-17', 'S11', 2, 0),
         ('SC_DR08_2026-10-17', 'S12', 3, 1),
         ('SC_DR08_2026-10-18', 'S1', 2, 0),
         ('SC_DR08_2026-10-18', 'S2', 2, 0),
         ('SC_DR08_2026-10-18', 'S3', 4, 1),
         ('SC_DR08_2026-10-18', 'S4', 3, 0),
         ('SC_DR08_2026-10-18', 'S5', 3, 0),
         ('SC_DR08_2026-10-18', 'S6', 2, 0),
         ('SC_DR08_2026-10-18', 'S7', 3, 1),
         ('SC_DR08_2026-10-18', 'S8', 2, 0),
         ('SC_DR08_2026-10-18', 'S9', 2, 0),
         ('SC_DR08_2026-10-18', 'S10', 3, 0),
         ('SC_DR08_2026-10-18', 'S11', 3, 1),
         ('SC_DR08_2026-10-18', 'S12', 2, 0),
         ('SC_DR08_2026-10-19', 'S1', 3, 0),
         ('SC_DR08_2026-10-19', 'S2', 4, 1),
         ('SC_DR08_2026-10-19', 'S3', 4, 1),
         ('SC_DR08_2026-10-19', 'S4', 3, 0),
         ('SC_DR08_2026-10-19', 'S5', 3, 0),
         ('SC_DR08_2026-10-19', 'S6', 4, 1),
         ('SC_DR08_2026-10-19', 'S7', 2, 0),
         ('SC_DR08_2026-10-19', 'S8', 3, 0),
         ('SC_DR08_2026-10-19', 'S9', 3, 0),
         ('SC_DR08_2026-10-19', 'S10', 3, 1),
         ('SC_DR08_2026-10-19', 'S11', 3, 0),
         ('SC_DR08_2026-10-19', 'S12', 2, 0),
         ('SC_DR08_2026-10-20', 'S1', 3, 0),
         ('SC_DR08_2026-10-20', 'S2', 3, 0),
         ('SC_DR08_2026-10-20', 'S3', 4, 1),
         ('SC_DR08_2026-10-20', 'S4', 2, 0),
         ('SC_DR08_2026-10-20', 'S5', 3, 0),
         ('SC_DR08_2026-10-20', 'S6', 3, 0),
         ('SC_DR08_2026-10-20', 'S7', 3, 0),
         ('SC_DR08_2026-10-20', 'S8', 2, 0),
         ('SC_DR08_2026-10-20', 'S9', 3, 0),
         ('SC_DR08_2026-10-20', 'S10', 2, 0),
         ('SC_DR08_2026-10-20', 'S11', 2, 0),
         ('SC_DR08_2026-10-20', 'S12', 3, 1),
         ('SC_DR09_2026-10-07', 'S1', 8, 7),
         ('SC_DR09_2026-10-07', 'S2', 4, 2),
         ('SC_DR09_2026-10-07', 'S3', 5, 3),
         ('SC_DR09_2026-10-07', 'S4', 6, 4),
         ('SC_DR09_2026-10-07', 'S5', 7, 6),
         ('SC_DR09_2026-10-07', 'S6', 4, 1),
         ('SC_DR09_2026-10-07', 'S7', 4, 2),
         ('SC_DR09_2026-10-07', 'S8', 6, 5),
         ('SC_DR09_2026-10-07', 'S9', 3, 1),
         ('SC_DR09_2026-10-07', 'S10', 3, 1),
         ('SC_DR09_2026-10-07', 'S11', 6, 5),
         ('SC_DR09_2026-10-07', 'S12', 5, 3),
         ('SC_DR09_2026-10-08', 'S1', 6, 3),
         ('SC_DR09_2026-10-08', 'S2', 4, 1),
         ('SC_DR09_2026-10-08', 'S3', 8, 7),
         ('SC_DR09_2026-10-08', 'S4', 6, 3),
         ('SC_DR09_2026-10-08', 'S5', 5, 2),
         ('SC_DR09_2026-10-08', 'S6', 4, 1),
         ('SC_DR09_2026-10-08', 'S7', 7, 6),
         ('SC_DR09_2026-10-08', 'S8', 6, 5),
         ('SC_DR09_2026-10-08', 'S9', 6, 4),
         ('SC_DR09_2026-10-08', 'S10', 3, 1),
         ('SC_DR09_2026-10-08', 'S11', 4, 2),
         ('SC_DR09_2026-10-08', 'S12', 5, 3),
         ('SC_DR09_2026-10-09', 'S1', 6, 3),
         ('SC_DR09_2026-10-09', 'S2', 7, 4),
         ('SC_DR09_2026-10-09', 'S3', 8, 6),
         ('SC_DR09_2026-10-09', 'S4', 4, 1),
         ('SC_DR09_2026-10-09', 'S5', 6, 3),
         ('SC_DR09_2026-10-09', 'S6', 7, 4),
         ('SC_DR09_2026-10-09', 'S7', 7, 5),
         ('SC_DR09_2026-10-09', 'S8', 3, 1),
         ('SC_DR09_2026-10-09', 'S9', 4, 1),
         ('SC_DR09_2026-10-09', 'S10', 7, 5),
         ('SC_DR09_2026-10-09', 'S11', 6, 4),
         ('SC_DR09_2026-10-09', 'S12', 5, 2),
         ('SC_DR09_2026-10-10', 'S1', 5, 2),
         ('SC_DR09_2026-10-10', 'S2', 6, 3),
         ('SC_DR09_2026-10-10', 'S3', 8, 5),
         ('SC_DR09_2026-10-10', 'S4', 8, 5),
         ('SC_DR09_2026-10-10', 'S5', 4, 1),
         ('SC_DR09_2026-10-10', 'S6', 6, 2),
         ('SC_DR09_2026-10-10', 'S7', 6, 3),
         ('SC_DR09_2026-10-10', 'S8', 6, 4),
         ('SC_DR09_2026-10-10', 'S9', 3, 1),
         ('SC_DR09_2026-10-10', 'S10', 4, 1),
         ('SC_DR09_2026-10-10', 'S11', 7, 4),
         ('SC_DR09_2026-10-10', 'S12', 6, 3),
         ('SC_DR09_2026-10-11', 'S1', 4, 1),
         ('SC_DR09_2026-10-11', 'S2', 7, 3),
         ('SC_DR09_2026-10-11', 'S3', 6, 2),
         ('SC_DR09_2026-10-11', 'S4', 5, 1),
         ('SC_DR09_2026-10-11', 'S5', 4, 1),
         ('SC_DR09_2026-10-11', 'S6', 8, 4),
         ('SC_DR09_2026-10-11', 'S7', 6, 2),
         ('SC_DR09_2026-10-11', 'S8', 5, 2),
         ('SC_DR09_2026-10-11', 'S9', 4, 1),
         ('SC_DR09_2026-10-11', 'S10', 6, 3),
         ('SC_DR09_2026-10-11', 'S11', 7, 4),
         ('SC_DR09_2026-10-11', 'S12', 4, 1),
         ('SC_DR09_2026-10-12', 'S1', 8, 3),
         ('SC_DR09_2026-10-12', 'S2', 4, 1),
         ('SC_DR09_2026-10-12', 'S3', 5, 1),
         ('SC_DR09_2026-10-12', 'S4', 8, 3),
         ('SC_DR09_2026-10-12', 'S5', 4, 0),
         ('SC_DR09_2026-10-12', 'S6', 5, 1),
         ('SC_DR09_2026-10-12', 'S7', 5, 1),
         ('SC_DR09_2026-10-12', 'S8', 5, 1),
         ('SC_DR09_2026-10-12', 'S9', 6, 2),
         ('SC_DR09_2026-10-12', 'S10', 4, 1),
         ('SC_DR09_2026-10-12', 'S11', 3, 0),
         ('SC_DR09_2026-10-12', 'S12', 6, 2),
         ('SC_DR09_2026-10-13', 'S1', 6, 1),
         ('SC_DR09_2026-10-13', 'S2', 5, 1),
         ('SC_DR09_2026-10-13', 'S3', 4, 0),
         ('SC_DR09_2026-10-13', 'S4', 8, 2),
         ('SC_DR09_2026-10-13', 'S5', 7, 2),
         ('SC_DR09_2026-10-13', 'S6', 5, 1),
         ('SC_DR09_2026-10-13', 'S7', 4, 1),
         ('SC_DR09_2026-10-13', 'S8', 7, 2),
         ('SC_DR09_2026-10-13', 'S9', 6, 2),
         ('SC_DR09_2026-10-13', 'S10', 3, 0),
         ('SC_DR09_2026-10-13', 'S11', 4, 1),
         ('SC_DR09_2026-10-13', 'S12', 5, 1),
         ('SC_DR09_2026-10-14', 'S1', 7, 1),
         ('SC_DR09_2026-10-14', 'S2', 4, 0),
         ('SC_DR09_2026-10-14', 'S3', 5, 1),
         ('SC_DR09_2026-10-14', 'S4', 7, 1),
         ('SC_DR09_2026-10-14', 'S5', 8, 2),
         ('SC_DR09_2026-10-14', 'S6', 5, 0),
         ('SC_DR09_2026-10-14', 'S7', 5, 1),
         ('SC_DR09_2026-10-14', 'S8', 6, 1),
         ('SC_DR09_2026-10-14', 'S9', 7, 2),
         ('SC_DR09_2026-10-14', 'S10', 4, 0),
         ('SC_DR09_2026-10-14', 'S11', 7, 2),
         ('SC_DR09_2026-10-14', 'S12', 6, 1),
         ('SC_DR09_2026-10-15', 'S1', 8, 2),
         ('SC_DR09_2026-10-15', 'S2', 7, 1),
         ('SC_DR09_2026-10-15', 'S3', 6, 1),
         ('SC_DR09_2026-10-15', 'S4', 4, 0),
         ('SC_DR09_2026-10-15', 'S5', 8, 1),
         ('SC_DR09_2026-10-15', 'S6', 6, 1),
         ('SC_DR09_2026-10-15', 'S7', 4, 0),
         ('SC_DR09_2026-10-15', 'S8', 5, 1),
         ('SC_DR09_2026-10-15', 'S9', 4, 0),
         ('SC_DR09_2026-10-15', 'S10', 5, 1),
         ('SC_DR09_2026-10-15', 'S11', 6, 1),
         ('SC_DR09_2026-10-15', 'S12', 3, 0),
         ('SC_DR09_2026-10-16', 'S1', 6, 1),
         ('SC_DR09_2026-10-16', 'S2', 7, 1),
         ('SC_DR09_2026-10-16', 'S3', 8, 1),
         ('SC_DR09_2026-10-16', 'S4', 4, 0),
         ('SC_DR09_2026-10-16', 'S5', 5, 0),
         ('SC_DR09_2026-10-16', 'S6', 6, 1),
         ('SC_DR09_2026-10-16', 'S7', 6, 1),
         ('SC_DR09_2026-10-16', 'S8', 7, 1),
         ('SC_DR09_2026-10-16', 'S9', 4, 0),
         ('SC_DR09_2026-10-16', 'S10', 5, 1),
         ('SC_DR09_2026-10-16', 'S11', 4, 0),
         ('SC_DR09_2026-10-16', 'S12', 6, 1),
         ('SC_DR09_2026-10-17', 'S1', 7, 1),
         ('SC_DR09_2026-10-17', 'S2', 6, 1),
         ('SC_DR09_2026-10-17', 'S3', 5, 0),
         ('SC_DR09_2026-10-17', 'S4', 7, 1),
         ('SC_DR09_2026-10-17', 'S5', 6, 1),
         ('SC_DR09_2026-10-17', 'S6', 5, 0),
         ('SC_DR09_2026-10-17', 'S7', 3, 0),
         ('SC_DR09_2026-10-17', 'S8', 3, 0),
         ('SC_DR09_2026-10-17', 'S9', 7, 1),
         ('SC_DR09_2026-10-17', 'S10', 3, 0),
         ('SC_DR09_2026-10-17', 'S11', 4, 0),
         ('SC_DR09_2026-10-17', 'S12', 5, 1),
         ('SC_DR09_2026-10-19', 'S1', 6, 1),
         ('SC_DR09_2026-10-19', 'S2', 5, 0),
         ('SC_DR09_2026-10-19', 'S3', 4, 0),
         ('SC_DR09_2026-10-19', 'S4', 8, 1),
         ('SC_DR09_2026-10-19', 'S5', 7, 1),
         ('SC_DR09_2026-10-19', 'S6', 5, 1),
         ('SC_DR09_2026-10-19', 'S7', 4, 0),
         ('SC_DR09_2026-10-19', 'S8', 6, 1),
         ('SC_DR09_2026-10-19', 'S9', 5, 1),
         ('SC_DR09_2026-10-19', 'S10', 6, 1),
         ('SC_DR09_2026-10-19', 'S11', 7, 1),
         ('SC_DR09_2026-10-19', 'S12', 4, 0),
         ('SC_DR09_2026-10-20', 'S1', 8, 1),
         ('SC_DR09_2026-10-20', 'S2', 6, 1),
         ('SC_DR09_2026-10-20', 'S3', 5, 1),
         ('SC_DR09_2026-10-20', 'S4', 5, 0),
         ('SC_DR09_2026-10-20', 'S5', 8, 2),
         ('SC_DR09_2026-10-20', 'S6', 7, 1),
         ('SC_DR09_2026-10-20', 'S7', 5, 1),
         ('SC_DR09_2026-10-20', 'S8', 7, 1),
         ('SC_DR09_2026-10-20', 'S9', 6, 1),
         ('SC_DR09_2026-10-20', 'S10', 7, 1),
         ('SC_DR09_2026-10-20', 'S11', 4, 0),
         ('SC_DR09_2026-10-20', 'S12', 5, 1),
         ('SC_DR10_2026-10-07', 'S1', 4, 3),
         ('SC_DR10_2026-10-07', 'S2', 5, 4),
         ('SC_DR10_2026-10-07', 'S3', 2, 1),
         ('SC_DR10_2026-10-07', 'S4', 3, 1),
         ('SC_DR10_2026-10-07', 'S5', 4, 2),
         ('SC_DR10_2026-10-07', 'S6', 5, 4),
         ('SC_DR10_2026-10-07', 'S7', 5, 5),
         ('SC_DR10_2026-10-07', 'S8', 4, 3),
         ('SC_DR10_2026-10-07', 'S9', 4, 3),
         ('SC_DR10_2026-10-07', 'S10', 3, 2),
         ('SC_DR10_2026-10-07', 'S11', 3, 1),
         ('SC_DR10_2026-10-07', 'S12', 5, 5),
         ('SC_DR10_2026-10-08', 'S1', 4, 2),
         ('SC_DR10_2026-10-08', 'S2', 3, 1),
         ('SC_DR10_2026-10-08', 'S3', 5, 4),
         ('SC_DR10_2026-10-08', 'S4', 5, 4),
         ('SC_DR10_2026-10-08', 'S5', 4, 2),
         ('SC_DR10_2026-10-08', 'S6', 3, 1),
         ('SC_DR10_2026-10-08', 'S7', 5, 4),
         ('SC_DR10_2026-10-08', 'S8', 4, 3),
         ('SC_DR10_2026-10-08', 'S9', 4, 2),
         ('SC_DR10_2026-10-08', 'S10', 3, 1),
         ('SC_DR10_2026-10-08', 'S11', 3, 1),
         ('SC_DR10_2026-10-08', 'S12', 4, 3),
         ('SC_DR10_2026-10-09', 'S1', 5, 3),
         ('SC_DR10_2026-10-09', 'S2', 3, 1),
         ('SC_DR10_2026-10-09', 'S3', 3, 1),
         ('SC_DR10_2026-10-09', 'S4', 4, 2),
         ('SC_DR10_2026-10-09', 'S5', 4, 2),
         ('SC_DR10_2026-10-09', 'S6', 5, 4),
         ('SC_DR10_2026-10-09', 'S7', 2, 1),
         ('SC_DR10_2026-10-09', 'S8', 3, 1),
         ('SC_DR10_2026-10-09', 'S9', 3, 1),
         ('SC_DR10_2026-10-09', 'S10', 4, 3),
         ('SC_DR10_2026-10-09', 'S11', 4, 2),
         ('SC_DR10_2026-10-09', 'S12', 3, 1),
         ('SC_DR10_2026-10-10', 'S1', 3, 1),
         ('SC_DR10_2026-10-10', 'S2', 4, 2),
         ('SC_DR10_2026-10-10', 'S3', 5, 3),
         ('SC_DR10_2026-10-10', 'S4', 3, 1),
         ('SC_DR10_2026-10-10', 'S5', 3, 1),
         ('SC_DR10_2026-10-10', 'S6', 4, 2),
         ('SC_DR10_2026-10-10', 'S7', 4, 2),
         ('SC_DR10_2026-10-10', 'S8', 3, 1),
         ('SC_DR10_2026-10-10', 'S9', 3, 1),
         ('SC_DR10_2026-10-10', 'S10', 3, 1),
         ('SC_DR10_2026-10-10', 'S11', 2, 0),
         ('SC_DR10_2026-10-10', 'S12', 4, 2),
         ('SC_DR10_2026-10-12', 'S1', 5, 2),
         ('SC_DR10_2026-10-12', 'S2', 3, 0),
         ('SC_DR10_2026-10-12', 'S3', 3, 1),
         ('SC_DR10_2026-10-12', 'S4', 4, 1),
         ('SC_DR10_2026-10-12', 'S5', 5, 2),
         ('SC_DR10_2026-10-12', 'S6', 2, 0),
         ('SC_DR10_2026-10-12', 'S7', 3, 1),
         ('SC_DR10_2026-10-12', 'S8', 4, 1),
         ('SC_DR10_2026-10-12', 'S9', 5, 2),
         ('SC_DR10_2026-10-12', 'S10', 4, 1),
         ('SC_DR10_2026-10-12', 'S11', 3, 1),
         ('SC_DR10_2026-10-12', 'S12', 3, 1),
         ('SC_DR10_2026-10-13', 'S1', 3, 0),
         ('SC_DR10_2026-10-13', 'S2', 5, 1),
         ('SC_DR10_2026-10-13', 'S3', 4, 1),
         ('SC_DR10_2026-10-13', 'S4', 4, 1),
         ('SC_DR10_2026-10-13', 'S5', 3, 0),
         ('SC_DR10_2026-10-13', 'S6', 5, 2),
         ('SC_DR10_2026-10-13', 'S7', 4, 1),
         ('SC_DR10_2026-10-13', 'S8', 2, 0),
         ('SC_DR10_2026-10-13', 'S9', 4, 1),
         ('SC_DR10_2026-10-13', 'S10', 3, 0),
         ('SC_DR10_2026-10-13', 'S11', 3, 1),
         ('SC_DR10_2026-10-13', 'S12', 4, 1),
         ('SC_DR10_2026-10-14', 'S1', 3, 0),
         ('SC_DR10_2026-10-14', 'S2', 3, 0),
         ('SC_DR10_2026-10-14', 'S3', 4, 1),
         ('SC_DR10_2026-10-14', 'S4', 5, 1),
         ('SC_DR10_2026-10-14', 'S5', 5, 1),
         ('SC_DR10_2026-10-14', 'S6', 3, 0),
         ('SC_DR10_2026-10-14', 'S7', 3, 0),
         ('SC_DR10_2026-10-14', 'S8', 2, 0),
         ('SC_DR10_2026-10-14', 'S9', 3, 0),
         ('SC_DR10_2026-10-14', 'S10', 3, 0),
         ('SC_DR10_2026-10-14', 'S11', 2, 0),
         ('SC_DR10_2026-10-14', 'S12', 3, 0),
         ('SC_DR10_2026-10-15', 'S1', 5, 1),
         ('SC_DR10_2026-10-15', 'S2', 5, 1),
         ('SC_DR10_2026-10-15', 'S3', 4, 0),
         ('SC_DR10_2026-10-15', 'S4', 2, 0),
         ('SC_DR10_2026-10-15', 'S5', 5, 1),
         ('SC_DR10_2026-10-15', 'S6', 4, 1),
         ('SC_DR10_2026-10-15', 'S7', 3, 0),
         ('SC_DR10_2026-10-15', 'S8', 4, 1),
         ('SC_DR10_2026-10-15', 'S9', 4, 1),
         ('SC_DR10_2026-10-15', 'S10', 2, 0),
         ('SC_DR10_2026-10-15', 'S11', 3, 0),
         ('SC_DR10_2026-10-15', 'S12', 3, 0),
         ('SC_DR10_2026-10-16', 'S1', 5, 1),
         ('SC_DR10_2026-10-16', 'S2', 3, 0),
         ('SC_DR10_2026-10-16', 'S3', 4, 0),
         ('SC_DR10_2026-10-16', 'S4', 5, 1),
         ('SC_DR10_2026-10-16', 'S5', 5, 1),
         ('SC_DR10_2026-10-16', 'S6', 4, 1),
         ('SC_DR10_2026-10-16', 'S7', 4, 1),
         ('SC_DR10_2026-10-16', 'S8', 3, 0),
         ('SC_DR10_2026-10-16', 'S9', 4, 1),
         ('SC_DR10_2026-10-16', 'S10', 4, 1),
         ('SC_DR10_2026-10-16', 'S11', 3, 0),
         ('SC_DR10_2026-10-16', 'S12', 2, 0),
         ('SC_DR10_2026-10-17', 'S1', 6, 1),
         ('SC_DR10_2026-10-17', 'S2', 5, 1),
         ('SC_DR10_2026-10-17', 'S3', 4, 0),
         ('SC_DR10_2026-10-17', 'S4', 3, 0),
         ('SC_DR10_2026-10-17', 'S5', 5, 1),
         ('SC_DR10_2026-10-17', 'S6', 4, 1),
         ('SC_DR10_2026-10-17', 'S7', 3, 0),
         ('SC_DR10_2026-10-17', 'S8', 5, 1),
         ('SC_DR10_2026-10-17', 'S9', 4, 1),
         ('SC_DR10_2026-10-17', 'S10', 4, 1),
         ('SC_DR10_2026-10-17', 'S11', 5, 1),
         ('SC_DR10_2026-10-17', 'S12', 3, 0),
         ('SC_DR10_2026-10-19', 'S1', 4, 0),
         ('SC_DR10_2026-10-19', 'S2', 3, 0),
         ('SC_DR10_2026-10-19', 'S3', 6, 1),
         ('SC_DR10_2026-10-19', 'S4', 5, 1),
         ('SC_DR10_2026-10-19', 'S5', 4, 1),
         ('SC_DR10_2026-10-19', 'S6', 3, 0),
         ('SC_DR10_2026-10-19', 'S7', 2, 0),
         ('SC_DR10_2026-10-19', 'S8', 4, 1),
         ('SC_DR10_2026-10-19', 'S9', 4, 1),
         ('SC_DR10_2026-10-19', 'S10', 3, 0),
         ('SC_DR10_2026-10-19', 'S11', 3, 0),
         ('SC_DR10_2026-10-19', 'S12', 4, 1),
         ('SC_DR10_2026-10-20', 'S1', 3, 0),
         ('SC_DR10_2026-10-20', 'S2', 5, 1),
         ('SC_DR10_2026-10-20', 'S3', 5, 1),
         ('SC_DR10_2026-10-20', 'S4', 3, 0),
         ('SC_DR10_2026-10-20', 'S5', 3, 0),
         ('SC_DR10_2026-10-20', 'S6', 5, 1),
         ('SC_DR10_2026-10-20', 'S7', 4, 1),
         ('SC_DR10_2026-10-20', 'S8', 2, 0),
         ('SC_DR10_2026-10-20', 'S9', 5, 1),
         ('SC_DR10_2026-10-20', 'S10', 3, 0),
         ('SC_DR10_2026-10-20', 'S11', 4, 1),
         ('SC_DR10_2026-10-20', 'S12', 4, 1)
       ) AS v(schedule_id, slot_id, total, booked)
  JOIN (VALUES
         ('S1',  '08:00-08:30', '上午'),
         ('S2',  '08:30-09:00', '上午'),
         ('S3',  '09:00-09:30', '上午'),
         ('S4',  '09:30-10:00', '上午'),
         ('S5',  '10:00-10:30', '上午'),
         ('S6',  '10:30-11:00', '上午'),
         ('S7',  '14:00-14:30', '下午'),
         ('S8',  '14:30-15:00', '下午'),
         ('S9',  '15:00-15:30', '下午'),
         ('S10', '15:30-16:00', '下午'),
         ('S11', '16:00-16:30', '下午'),
         ('S12', '16:30-17:00', '下午')
       ) AS d(slot_id, label, period) ON d.slot_id = v.slot_id;

-- ------------------------------------------------------------
-- 12.3 挂号记录表 appointments —— 共 1885 条（全部 active）
--
--      这批记录是「占位数据」：真实系统里 booked 必须由患者挂号产生，
--      为了让初始数据自洽，这里为每一个已占号源生成一条对应的挂号记录，
--      从而保证不变量 sum(booked) = count(active 挂号) 成立（当前 1885 = 1885）。
--      就诊人姓名/身份证/手机号均为程序按确定性伪随机生成的虚构数据，
--      身份证第 18 位是按 GB 11643-1999 校验位算法算出来的，能通过应用层校验。
--
--      同样只写「真正逐行不同」的字段：单号、取号序号、哪条排班、哪一格、
--      就诊人三要素。医院/科室/医生/日期/星期来自 schedules，
--      时段名称/午别来自 schedule_slots，挂号费来自 doctors —— 全部 JOIN 补齐。
--
--      注意：created_at 未显式赋值，由 DEFAULT NOW() 填充；
--      「我的挂号」列表按 created_at DESC, id DESC 排序，
--      单号 A1000~A2884 等长，字典序即数字序，因此展示顺序是确定的。
-- ------------------------------------------------------------
INSERT INTO appointments (id, seq_no, schedule_id, slot_id,
                         dept_id, doctor_id,
                         work_date, weekday, slot_label, period,
                         patient_name, id_card, phone, fee, status)
SELECT v.id,
       v.seq_no,
       v.schedule_id,
       v.slot_id,
       s.dept_id,              -- 由排班带出，避免冗余抄写
       s.doctor_id,
       s.work_date,
       s.weekday,
       sl.label,               -- 由号源字典带出
       sl.period,
       v.patient_name,
       v.id_card,
       v.phone,
       d.fee,                  -- 挂号费取自医生职称对应的定价
       'active'
  FROM (VALUES
         ('A1000', 1, 'SC_DR01_2026-10-07', 'S1', '张明', '310104197402151000', '19974186201'),
         ('A1001', 2, 'SC_DR01_2026-10-07', 'S1', '杨军', '440103200407147438', '19358146921'),
         ('A1002', 1, 'SC_DR01_2026-10-07', 'S2', '林娜', '31010419930203536X', '18914780367'),
         ('A1003', 2, 'SC_DR01_2026-10-07', 'S2', '李超', '310104195410223191', '13196320749'),
         ('A1004', 3, 'SC_DR01_2026-10-07', 'S2', '王敏', '310104198404082699', '17024713588'),
         ('A1005', 4, 'SC_DR01_2026-10-07', 'S2', '周芳', '110105200407153244', '19907531967'),
         ('A1006', 1, 'SC_DR01_2026-10-07', 'S3', '朱丽', '320102196207289842', '18642953188'),
         ('A1007', 1, 'SC_DR01_2026-10-07', 'S4', '徐涛', '310104199805115150', '19357046911'),
         ('A1008', 1, 'SC_DR01_2026-10-07', 'S5', '罗涛', '320102196009058517', '18641875298'),
         ('A1009', 2, 'SC_DR01_2026-10-07', 'S5', '黄军', '110101199602201685', '15581347028'),
         ('A1010', 1, 'SC_DR01_2026-10-07', 'S6', '张磊', '440305195408178391', '13792580365'),
         ('A1011', 2, 'SC_DR01_2026-10-07', 'S6', '高娟', '110105198011091956', '19429631856'),
         ('A1012', 3, 'SC_DR01_2026-10-07', 'S6', '黄勇', '110105199704260921', '17357024695'),
         ('A1013', 1, 'SC_DR01_2026-10-07', 'S7', '林磊', '44010319990524645X', '15208531964'),
         ('A1014', 2, 'SC_DR01_2026-10-07', 'S7', '朱明', '310104198702043241', '18368025791'),
         ('A1015', 3, 'SC_DR01_2026-10-07', 'S7', '陈平', '44030519691024589X', '15863175206'),
         ('A1016', 1, 'SC_DR01_2026-10-07', 'S8', '杨洋', '310104196307044827', '19691358028'),
         ('A1017', 1, 'SC_DR01_2026-10-07', 'S9', '徐静', '440305197409226673', '17963175206'),
         ('A1018', 1, 'SC_DR01_2026-10-07', 'S10', '何勇', '330102196608020504', '18186407533'),
         ('A1019', 1, 'SC_DR01_2026-10-07', 'S11', '林芳', '110105198011243067', '17581346023'),
         ('A1020', 2, 'SC_DR01_2026-10-07', 'S11', '赵娜', '330102198204098240', '18741985204'),
         ('A1021', 3, 'SC_DR01_2026-10-07', 'S11', '陈磊', '310104198304082499', '17681379244'),
         ('A1022', 1, 'SC_DR01_2026-10-07', 'S12', '陈伟', '320102196007278508', '18863075190'),
         ('A1023', 2, 'SC_DR01_2026-10-07', 'S12', '李强', '320102195708289029', '13793580465'),
         ('A1024', 1, 'SC_DR01_2026-10-08', 'S1', '郭伟', '440305199907165390', '19246835790'),
         ('A1025', 2, 'SC_DR01_2026-10-08', 'S1', '张超', '310104196508176148', '15420731962'),
         ('A1026', 1, 'SC_DR01_2026-10-08', 'S2', '王杰', '110105197202151689', '19075319642'),
         ('A1027', 2, 'SC_DR01_2026-10-08', 'S2', '赵军', '110101197209200628', '15913580247'),
         ('A1028', 1, 'SC_DR01_2026-10-08', 'S3', '张洋', '310104198504093926', '18258036910'),
         ('A1029', 1, 'SC_DR01_2026-10-08', 'S4', '杨伟', '330102195608017706', '17863075290'),
         ('A1030', 2, 'SC_DR01_2026-10-08', 'S4', '郭秀英', '110105197302031801', '17571368243'),
         ('A1031', 3, 'SC_DR01_2026-10-08', 'S4', '赵芳', '310104195510234461', '13319642081'),
         ('A1032', 1, 'SC_DR01_2026-10-08', 'S5', '杨艳', '110101196309208905', '15479135802'),
         ('A1033', 2, 'SC_DR01_2026-10-08', 'S5', '张超', '110101197601132439', '19530864197'),
         ('A1034', 1, 'SC_DR01_2026-10-08', 'S6', '徐敏', '310101198009043041', '19297518644'),
         ('A1035', 1, 'SC_DR01_2026-10-08', 'S7', '罗静', '310101198001013091', '17793568245'),
         ('A1036', 1, 'SC_DR01_2026-10-08', 'S8', '胡艳', '330102198104088088', '17630874193'),
         ('A1037', 2, 'SC_DR01_2026-10-08', 'S8', '周涛', '330102196407160252', '15359124801'),
         ('A1038', 1, 'SC_DR01_2026-10-08', 'S9', '张强', '310101200008051381', '17792481359'),
         ('A1039', 1, 'SC_DR01_2026-10-08', 'S10', '高娜', '330102195507167481', '13146803579'),
         ('A1040', 2, 'SC_DR01_2026-10-08', 'S10', '王杰', '310101198502173966', '13752086319'),
         ('A1041', 1, 'SC_DR01_2026-10-08', 'S11', '陈平', '110101196610069553', '18852074860'),
         ('A1042', 2, 'SC_DR01_2026-10-08', 'S11', '杨军', '440103199502145670', '18469257132'),
         ('A1043', 1, 'SC_DR01_2026-10-08', 'S12', '胡伟', '440305200105110019', '15914670356'),
         ('A1044', 1, 'SC_DR01_2026-10-09', 'S1', '马静', '320102198001038844', '17318642971'),
         ('A1045', 2, 'SC_DR01_2026-10-09', 'S1', '马超', '110105195904250877', '17246803574'),
         ('A1046', 1, 'SC_DR01_2026-10-09', 'S2', '赵军', '440305197801177482', '13913502461'),
         ('A1047', 2, 'SC_DR01_2026-10-09', 'S2', '郭洋', '11010519821109334X', '13429731866'),
         ('A1048', 3, 'SC_DR01_2026-10-09', 'S2', '赵杰', '440305196910116887', '19025891472'),
         ('A1049', 1, 'SC_DR01_2026-10-09', 'S4', '杨军', '110101199702211848', '17681457038'),
         ('A1050', 1, 'SC_DR01_2026-10-09', 'S5', '朱丽', '440305197309227695', '17641952084'),
         ('A1051', 1, 'SC_DR01_2026-10-09', 'S6', '徐涛', '110101199502200562', '15702469130'),
         ('A1052', 2, 'SC_DR01_2026-10-09', 'S6', '马平', '310104195310224090', '13319642071'),
         ('A1053', 1, 'SC_DR01_2026-10-09', 'S7', '郭军', '310104195906154126', '13640853974'),
         ('A1054', 2, 'SC_DR01_2026-10-09', 'S7', '王丽', '330102198903230554', '15147925803'),
         ('A1055', 1, 'SC_DR01_2026-10-09', 'S8', '孙明', '330102196710230655', '15570268143'),
         ('A1056', 2, 'SC_DR01_2026-10-09', 'S8', '赵秀英', '310104199201154220', '13195308423'),
         ('A1057', 1, 'SC_DR01_2026-10-09', 'S9', '胡强', '110101197512122191', '19196420853'),
         ('A1058', 2, 'SC_DR01_2026-10-09', 'S9', '李静', '320102195107146874', '13146803579'),
         ('A1059', 1, 'SC_DR01_2026-10-09', 'S10', '林艳', '310104196310224845', '15529763082'),
         ('A1060', 2, 'SC_DR01_2026-10-09', 'S10', '陈勇', '31010419851003392X', '18136892578'),
         ('A1061', 1, 'SC_DR01_2026-10-09', 'S11', '林伟', '330102199204249920', '15468157926'),
         ('A1062', 1, 'SC_DR01_2026-10-09', 'S12', '李娟', '440103196911256853', '15531964203'),
         ('A1063', 1, 'SC_DR01_2026-10-10', 'S1', '高娟', '320102195909048264', '18085319642'),
         ('A1064', 2, 'SC_DR01_2026-10-10', 'S1', '杨军', '110101199803212057', '17359124705'),
         ('A1065', 1, 'SC_DR01_2026-10-10', 'S3', '李涛', '310101199003204849', '13075318642'),
         ('A1066', 1, 'SC_DR01_2026-10-10', 'S4', '郭芳', '320102196107158589', '13135802479'),
         ('A1067', 1, 'SC_DR01_2026-10-10', 'S5', '王超', '440103198311192576', '13429631856'),
         ('A1068', 1, 'SC_DR01_2026-10-10', 'S6', '孙明', '330102196508170409', '15147903689'),
         ('A1069', 2, 'SC_DR01_2026-10-10', 'S6', '刘霞', '440305196701015588', '15974208537'),
         ('A1070', 3, 'SC_DR01_2026-10-10', 'S6', '王敏', '320102200509196579', '19913602477'),
         ('A1071', 1, 'SC_DR01_2026-10-10', 'S8', '周杰', '440305197504256862', '13702481359'),
         ('A1072', 2, 'SC_DR01_2026-10-10', 'S8', '何艳', '310104199602175997', '15308629755'),
         ('A1073', 1, 'SC_DR01_2026-10-10', 'S9', '李明', '440305197601017150', '17085219638'),
         ('A1074', 2, 'SC_DR01_2026-10-10', 'S9', '吴超', '110105197311251793', '17925780467'),
         ('A1075', 1, 'SC_DR01_2026-10-10', 'S11', '王强', '310104196210095724', '18804691570'),
         ('A1076', 2, 'SC_DR01_2026-10-10', 'S11', '陈平', '310104196508185204', '15752964182'),
         ('A1077', 1, 'SC_DR01_2026-10-10', 'S12', '徐静', '31010419651023516X', '15428653972'),
         ('A1078', 2, 'SC_DR01_2026-10-10', 'S12', '周娟', '330102195507168644', '13358124701'),
         ('A1079', 1, 'SC_DR01_2026-10-11', 'S1', '张洋', '310101195706014779', '18469135806'),
         ('A1080', 1, 'SC_DR01_2026-10-11', 'S4', '林磊', '310101195909205049', '13753086415'),
         ('A1081', 2, 'SC_DR01_2026-10-11', 'S4', '赵勇', '33010219840219855X', '13791468039'),
         ('A1082', 1, 'SC_DR01_2026-10-11', 'S5', '孙霞', '310104196302195925', '19136824703'),
         ('A1083', 1, 'SC_DR01_2026-10-11', 'S6', '林勇', '310101195308173045', '13641875294'),
         ('A1084', 1, 'SC_DR01_2026-10-11', 'S8', '陈明', '110105198011093089', '19863175200'),
         ('A1085', 1, 'SC_DR01_2026-10-11', 'S9', '黄军', '310104199302025321', '18036892578'),
         ('A1086', 1, 'SC_DR01_2026-10-11', 'S10', '胡芳', '440305200105116752', '19247013690'),
         ('A1087', 1, 'SC_DR01_2026-10-11', 'S11', '林磊', '110101196710073955', '13864175300'),
         ('A1088', 1, 'SC_DR01_2026-10-11', 'S12', '高秀英', '330102195503167484', '13579146803'),
         ('A1089', 1, 'SC_DR01_2026-10-12', 'S1', '黄平', '110105198202153355', '13207531864'),
         ('A1090', 2, 'SC_DR01_2026-10-12', 'S1', '朱霞', '310101197612271300', '17257913680'),
         ('A1091', 1, 'SC_DR01_2026-10-12', 'S4', '林娜', '320102195706138913', '13469125801'),
         ('A1092', 1, 'SC_DR01_2026-10-12', 'S5', '高勇', '440103199803186353', '15974286311'),
         ('A1093', 2, 'SC_DR01_2026-10-12', 'S5', '徐娟', '440305197701177231', '13468057916'),
         ('A1094', 1, 'SC_DR01_2026-10-12', 'S8', '林娜', '440103197111147186', '19570368147'),
         ('A1095', 1, 'SC_DR01_2026-10-12', 'S10', '黄娜', '310101197703181538', '19307541865'),
         ('A1096', 1, 'SC_DR01_2026-10-12', 'S11', '张丽', '11010519750204114X', '17368047911'),
         ('A1097', 1, 'SC_DR01_2026-10-13', 'S1', '郭芳', '440103196811125629', '19135724683'),
         ('A1098', 1, 'SC_DR01_2026-10-13', 'S2', '林洋', '320102198202049283', '17208531960'),
         ('A1099', 1, 'SC_DR01_2026-10-13', 'S3', '高静', '110105195007033434', '17258036915'),
         ('A1100', 1, 'SC_DR01_2026-10-13', 'S5', '黄勇', '330102199402190288', '15468035796'),
         ('A1101', 1, 'SC_DR01_2026-10-13', 'S6', '胡磊', '44030519771024837X', '17853174205'),
         ('A1102', 1, 'SC_DR01_2026-10-13', 'S8', '黄芳', '44010320040627630X', '17751986209'),
         ('A1103', 1, 'SC_DR01_2026-10-13', 'S9', '郭芳', '310101198803063357', '18702481355'),
         ('A1104', 1, 'SC_DR01_2026-10-13', 'S10', '黄勇', '110101199103229720', '15913570241'),
         ('A1105', 1, 'SC_DR01_2026-10-13', 'S11', '吴敏', '310101200205121748', '19307529641'),
         ('A1106', 1, 'SC_DR01_2026-10-14', 'S1', '吴静', '110105196810079954', '18318520745'),
         ('A1107', 1, 'SC_DR01_2026-10-14', 'S4', '高娜', '110101196612289533', '15025714688'),
         ('A1108', 1, 'SC_DR01_2026-10-14', 'S5', '赵秀英', '440103199206254135', '13296430754'),
         ('A1109', 1, 'SC_DR01_2026-10-14', 'S9', '李明', '440305196910245793', '15085297418'),
         ('A1110', 1, 'SC_DR01_2026-10-15', 'S3', '杨洋', '11010519730203069X', '15913602577'),
         ('A1111', 1, 'SC_DR01_2026-10-15', 'S7', '胡平', '440103199203074198', '18579246813'),
         ('A1112', 1, 'SC_DR01_2026-10-16', 'S4', '马霞', '330102195510228636', '13460257132'),
         ('A1113', 1, 'SC_DR01_2026-10-16', 'S6', '郭伟', '320102195009196632', '19914602577'),
         ('A1114', 1, 'SC_DR01_2026-10-16', 'S12', '黄平', '440305198209219254', '17753164295'),
         ('A1115', 1, 'SC_DR01_2026-10-18', 'S4', '赵勇', '110105199304240227', '15680357928'),
         ('A1116', 1, 'SC_DR01_2026-10-18', 'S5', '高娟', '110105199304080139', '18207519640'),
         ('A1117', 1, 'SC_DR01_2026-10-18', 'S9', '罗娟', '11010119661212953X', '18752986309'),
         ('A1118', 1, 'SC_DR01_2026-10-18', 'S12', '吴敏', '310101197602171373', '19863097410'),
         ('A1119', 1, 'SC_DR01_2026-10-19', 'S4', '马丽', '110105198102153323', '13319752086'),
         ('A1120', 1, 'SC_DR01_2026-10-19', 'S9', '赵娟', '310101195806025029', '18026891572'),
         ('A1121', 1, 'SC_DR01_2026-10-20', 'S4', '陈霞', '440103199005244889', '13853196420'),
         ('A1122', 1, 'SC_DR01_2026-10-20', 'S12', '李丽', '440103197209086334', '19913680251'),
         ('A1123', 1, 'SC_DR02_2026-10-07', 'S1', '李磊', '44010319670806651X', '19681457038'),
         ('A1124', 1, 'SC_DR02_2026-10-07', 'S2', '胡艳', '440103197009206047', '15963185207'),
         ('A1125', 2, 'SC_DR02_2026-10-07', 'S2', '张洋', '110101199805272168', '17248036914'),
         ('A1126', 3, 'SC_DR02_2026-10-07', 'S2', '罗军', '110105196909131046', '18641975208'),
         ('A1127', 4, 'SC_DR02_2026-10-07', 'S2', '林伟', '110101198905279469', '15135724683'),
         ('A1128', 1, 'SC_DR02_2026-10-07', 'S3', '徐娟', '310104196006024195', '18791368029'),
         ('A1129', 2, 'SC_DR02_2026-10-07', 'S3', '张超', '11010119850410983X', '18420853192'),
         ('A1130', 1, 'SC_DR02_2026-10-07', 'S4', '胡磊', '33010219890307044X', '18086419758'),
         ('A1131', 1, 'SC_DR02_2026-10-07', 'S5', '陈艳', '110101199705271950', '17036814792'),
         ('A1132', 2, 'SC_DR02_2026-10-07', 'S5', '赵秀英', '320102198211268162', '17641853074'),
         ('A1133', 3, 'SC_DR02_2026-10-07', 'S5', '刘强', '110101197410210932', '17247913580'),
         ('A1134', 4, 'SC_DR02_2026-10-07', 'S5', '李娟', '440305200105246768', '15520841977'),
         ('A1135', 5, 'SC_DR02_2026-10-07', 'S5', '赵娟', '110101200003222463', '17247903684'),
         ('A1136', 1, 'SC_DR02_2026-10-07', 'S6', '朱洋', '320102198202048125', '17317542861'),
         ('A1137', 2, 'SC_DR02_2026-10-07', 'S6', '孙霞', '440103199003064876', '18247013690'),
         ('A1138', 3, 'SC_DR02_2026-10-07', 'S6', '杨霞', '320102199312277847', '17742053194'),
         ('A1139', 1, 'SC_DR02_2026-10-07', 'S7', '何娜', '310104196109094460', '18246835704'),
         ('A1140', 2, 'SC_DR02_2026-10-07', 'S7', '林磊', '330102196608020635', '18208619744'),
         ('A1141', 1, 'SC_DR02_2026-10-07', 'S8', '孙静', '11010119771007248X', '19319620855'),
         ('A1142', 2, 'SC_DR02_2026-10-07', 'S8', '胡平', '310101195308053043', '18680379148'),
         ('A1143', 1, 'SC_DR02_2026-10-07', 'S9', '朱伟', '310101198901014727', '18681457024'),
         ('A1144', 1, 'SC_DR02_2026-10-07', 'S10', '孙明', '440305200306127175', '19025791468'),
         ('A1145', 2, 'SC_DR02_2026-10-07', 'S10', '郭军', '330102198803079252', '18085329648'),
         ('A1146', 3, 'SC_DR02_2026-10-07', 'S10', '朱霞', '440103198606146294', '19468157022'),
         ('A1147', 1, 'SC_DR02_2026-10-07', 'S11', '林洋', '310104198402157116', '15420731966'),
         ('A1148', 1, 'SC_DR02_2026-10-07', 'S12', '何娜', '310104198510222974', '18025791368'),
         ('A1149', 2, 'SC_DR02_2026-10-07', 'S12', '周芳', '440103199905246513', '15753186429'),
         ('A1150', 1, 'SC_DR02_2026-10-08', 'S1', '张超', '440305197309227679', '17964285317'),
         ('A1151', 2, 'SC_DR02_2026-10-08', 'S1', '李静', '320102195009196616', '19135824699'),
         ('A1152', 1, 'SC_DR02_2026-10-08', 'S2', '胡平', '33010219900117958X', '15146803574'),
         ('A1153', 2, 'SC_DR02_2026-10-08', 'S2', '刘明', '320102197101037238', '15075318647'),
         ('A1154', 3, 'SC_DR02_2026-10-08', 'S2', '杨军', '110105198801114585', '18803691476'),
         ('A1155', 4, 'SC_DR02_2026-10-08', 'S2', '李超', '440103196811255706', '15195320749'),
         ('A1156', 1, 'SC_DR02_2026-10-08', 'S4', '黄杰', '110105200206012736', '17469157026'),
         ('A1157', 2, 'SC_DR02_2026-10-08', 'S4', '刘霞', '330102199001029565', '18863075296'),
         ('A1158', 1, 'SC_DR02_2026-10-08', 'S5', '徐明', '110101199705111850', '19085319648'),
         ('A1159', 2, 'SC_DR02_2026-10-08', 'S5', '林伟', '440305196610105369', '19358024795'),
         ('A1160', 3, 'SC_DR02_2026-10-08', 'S5', '胡洋', '330102200504026396', '17318520645'),
         ('A1161', 1, 'SC_DR02_2026-10-08', 'S6', '杨洋', '310104196410104920', '19246835794'),
         ('A1162', 2, 'SC_DR02_2026-10-08', 'S6', '张涛', '310101198712124361', '13197408633'),
         ('A1163', 3, 'SC_DR02_2026-10-08', 'S6', '张磊', '440103196309085801', '19703569249'),
         ('A1164', 4, 'SC_DR02_2026-10-08', 'S6', '张明', '310101200105121505', '19752064195'),
         ('A1165', 1, 'SC_DR02_2026-10-08', 'S7', '陈平', '330102199104089851', '18207531860'),
         ('A1166', 1, 'SC_DR02_2026-10-08', 'S8', '胡芳', '110101197510222121', '17792458134'),
         ('A1167', 2, 'SC_DR02_2026-10-08', 'S8', '林勇', '330102197903077620', '17074218538'),
         ('A1168', 1, 'SC_DR02_2026-10-08', 'S9', '马丽', '320102196207289885', '18186407533'),
         ('A1169', 2, 'SC_DR02_2026-10-08', 'S9', '林伟', '110101199504260446', '15136824793'),
         ('A1170', 3, 'SC_DR02_2026-10-08', 'S9', '黄芳', '330102195811088155', '17641875208'),
         ('A1171', 1, 'SC_DR02_2026-10-08', 'S10', '徐丽', '110105197911081898', '19317520645'),
         ('A1172', 2, 'SC_DR02_2026-10-08', 'S10', '赵娟', '310104197604092408', '17247035910'),
         ('A1173', 1, 'SC_DR02_2026-10-08', 'S11', '朱霞', '310104199502034636', '18357024691'),
         ('A1174', 1, 'SC_DR02_2026-10-08', 'S12', '陈明', '310101198512113895', '13631252081'),
         ('A1175', 2, 'SC_DR02_2026-10-08', 'S12', '张丽', '310104196310104763', '19035714682'),
         ('A1176', 3, 'SC_DR02_2026-10-08', 'S12', '黄娜', '110105196901140052', '18529763087'),
         ('A1177', 4, 'SC_DR02_2026-10-08', 'S12', '朱平', '330102198304249392', '13914602581'),
         ('A1178', 1, 'SC_DR02_2026-10-09', 'S1', '何娜', '440103195403067357', '13924681357'),
         ('A1179', 2, 'SC_DR02_2026-10-09', 'S1', '胡磊', '330102196811080887', '18752086319'),
         ('A1180', 1, 'SC_DR02_2026-10-09', 'S2', '张涛', '320102195307288228', '17419720866'),
         ('A1181', 1, 'SC_DR02_2026-10-09', 'S3', '何敏', '110105197211241547', '15915780467'),
         ('A1182', 2, 'SC_DR02_2026-10-09', 'S3', '刘霞', '310101195708193635', '13084219538'),
         ('A1183', 3, 'SC_DR02_2026-10-09', 'S3', '王敏', '110101195412267394', '13368057911'),
         ('A1184', 4, 'SC_DR02_2026-10-09', 'S3', '周芳', '440305196612286335', '15964207537'),
         ('A1185', 5, 'SC_DR02_2026-10-09', 'S3', '张磊', '110101196312260093', '15025713687'),
         ('A1186', 1, 'SC_DR02_2026-10-09', 'S4', '李超', '310101197903191917', '19974208531'),
         ('A1187', 2, 'SC_DR02_2026-10-09', 'S4', '马平', '320102197512158034', '13681357028'),
         ('A1188', 3, 'SC_DR02_2026-10-09', 'S4', '高军', '110101197710072471', '19086497522'),
         ('A1189', 1, 'SC_DR02_2026-10-09', 'S5', '周军', '44010319900512385X', '18468057911'),
         ('A1190', 2, 'SC_DR02_2026-10-09', 'S5', '李娟', '310101199406041327', '19975386427'),
         ('A1191', 1, 'SC_DR02_2026-10-09', 'S6', '马静', '440305196408110148', '18297530864'),
         ('A1192', 1, 'SC_DR02_2026-10-09', 'S8', '李超', '310104195006152512', '13429731862'),
         ('A1193', 1, 'SC_DR02_2026-10-09', 'S9', '吴杰', '310104195106022600', '17803579140'),
         ('A1194', 1, 'SC_DR02_2026-10-09', 'S10', '陈洋', '110101197701281407', '17024613588'),
         ('A1195', 2, 'SC_DR02_2026-10-09', 'S10', '何艳', '440305197011247044', '15208619750'),
         ('A1196', 3, 'SC_DR02_2026-10-09', 'S10', '陈艳', '110101196710220804', '15136902589'),
         ('A1197', 4, 'SC_DR02_2026-10-09', 'S10', '郭勇', '320102195107276812', '17640853971'),
         ('A1198', 1, 'SC_DR02_2026-10-09', 'S11', '陈平', '110105196602179475', '18530864198'),
         ('A1199', 1, 'SC_DR02_2026-10-09', 'S12', '孙明', '110101197111261457', '15469257032'),
         ('A1200', 1, 'SC_DR02_2026-10-11', 'S1', '高娟', '320102198402058491', '18640875294'),
         ('A1201', 2, 'SC_DR02_2026-10-11', 'S1', '马平', '44030519990510640X', '19914670356'),
         ('A1202', 1, 'SC_DR02_2026-10-11', 'S2', '周娟', '320102198603210015', '15914602571'),
         ('A1203', 1, 'SC_DR02_2026-10-11', 'S3', '吴秀英', '110105200210142832', '19196420759'),
         ('A1204', 1, 'SC_DR02_2026-10-11', 'S4', '林平', '310104196207034568', '18247913684'),
         ('A1205', 1, 'SC_DR02_2026-10-11', 'S5', '胡艳', '110101200003071386', '19428631752'),
         ('A1206', 1, 'SC_DR02_2026-10-11', 'S6', '刘艳', '310104196307045838', '19136802573'),
         ('A1207', 2, 'SC_DR02_2026-10-11', 'S6', '刘平', '110105196510169405', '18196320753'),
         ('A1208', 1, 'SC_DR02_2026-10-11', 'S7', '何勇', '110101199602051680', '19429730862'),
         ('A1209', 2, 'SC_DR02_2026-10-11', 'S7', '吴杰', '440103199106123891', '18468057912'),
         ('A1210', 3, 'SC_DR02_2026-10-11', 'S7', '何军', '110105199807171120', '19863197426'),
         ('A1211', 1, 'SC_DR02_2026-10-11', 'S9', '林勇', '310101196702172889', '13641975208'),
         ('A1212', 1, 'SC_DR02_2026-10-11', 'S10', '赵芳', '320102200010066695', '15197520863'),
         ('A1213', 2, 'SC_DR02_2026-10-11', 'S10', '胡平', '440103199504084648', '18246813570'),
         ('A1214', 1, 'SC_DR02_2026-10-11', 'S11', '何敏', '310104199204085152', '18247935810'),
         ('A1215', 1, 'SC_DR02_2026-10-11', 'S12', '陈伟', '310101198803183383', '13206431754'),
         ('A1216', 1, 'SC_DR02_2026-10-12', 'S1', '刘磊', '440305200007165526', '19579168022'),
         ('A1217', 1, 'SC_DR02_2026-10-12', 'S2', '李涛', '330102195610078743', '17863197520'),
         ('A1218', 1, 'SC_DR02_2026-10-12', 'S3', '罗静', '110105197001021300', '15570368143'),
         ('A1219', 2, 'SC_DR02_2026-10-12', 'S3', '赵娜', '320102195307287209', '17973152971'),
         ('A1220', 3, 'SC_DR02_2026-10-12', 'S3', '徐涛', '11010520010323159X', '17247913584'),
         ('A1221', 1, 'SC_DR02_2026-10-12', 'S4', '李明', '440305195904228351', '18428631756'),
         ('A1222', 2, 'SC_DR02_2026-10-12', 'S4', '吴超', '110105197001011209', '15369147021'),
         ('A1223', 1, 'SC_DR02_2026-10-12', 'S5', '张丽', '320102200406136282', '19802479136'),
         ('A1224', 1, 'SC_DR02_2026-10-12', 'S6', '高军', '310101197812122756', '19197408533'),
         ('A1225', 1, 'SC_DR02_2026-10-12', 'S8', '李明', '330102198204088210', '17641875294'),
         ('A1226', 2, 'SC_DR02_2026-10-12', 'S8', '赵娟', '110105197810232714', '17359191808'),
         ('A1227', 1, 'SC_DR02_2026-10-12', 'S9', '林平', '110105195907030773', '17680279138'),
         ('A1228', 2, 'SC_DR02_2026-10-12', 'S9', '刘明', '310104198802174476', '13520841977'),
         ('A1229', 1, 'SC_DR02_2026-10-12', 'S10', '吴娟', '110105197211250531', '15257914680'),
         ('A1230', 1, 'SC_DR02_2026-10-12', 'S12', '吴超', '440103198903054732', '18581346023'),
         ('A1231', 1, 'SC_DR02_2026-10-13', 'S1', '黄伟', '330102198703060140', '18208631970'),
         ('A1232', 1, 'SC_DR02_2026-10-13', 'S2', '周杰', '110105200306021859', '17702481359'),
         ('A1233', 1, 'SC_DR02_2026-10-13', 'S3', '徐静', '330102198803079180', '18741985204'),
         ('A1234', 2, 'SC_DR02_2026-10-13', 'S3', '陈勇', '440305200306127095', '19681457024'),
         ('A1235', 1, 'SC_DR02_2026-10-13', 'S5', '李娟', '310101195706134703', '13863175206'),
         ('A1236', 1, 'SC_DR02_2026-10-13', 'S6', '王静', '110105200404252183', '17680257918'),
         ('A1237', 1, 'SC_DR02_2026-10-13', 'S7', '高杰', '110101200003071343', '19126308429'),
         ('A1238', 2, 'SC_DR02_2026-10-13', 'S7', '胡芳', '110101199705271862', '17581369247'),
         ('A1239', 1, 'SC_DR02_2026-10-13', 'S8', '杨军', '110101197412271966', '17914602577'),
         ('A1240', 2, 'SC_DR02_2026-10-13', 'S8', '吴敏', '320102195806268176', '17640853978'),
         ('A1241', 1, 'SC_DR02_2026-10-13', 'S11', '赵勇', '310104196210094641', '18579168027'),
         ('A1242', 1, 'SC_DR02_2026-10-13', 'S12', '何勇', '330102199003080639', '18075319648'),
         ('A1243', 1, 'SC_DR02_2026-10-14', 'S2', '罗涛', '310104195209212781', '13206431850'),
         ('A1244', 1, 'SC_DR02_2026-10-14', 'S3', '王静', '440305196512165229', '19913602471'),
         ('A1245', 1, 'SC_DR02_2026-10-14', 'S6', '高娟', '110105199704100864', '19207419630'),
         ('A1246', 1, 'SC_DR02_2026-10-14', 'S8', '郭洋', '110101196211109853', '18318642975'),
         ('A1247', 1, 'SC_DR02_2026-10-14', 'S12', '林平', '110105195207042773', '18791380249'),
         ('A1248', 1, 'SC_DR02_2026-10-15', 'S2', '王强', '440103196209085580', '18147903683'),
         ('A1249', 1, 'SC_DR02_2026-10-15', 'S3', '罗军', '310104195407164194', '13864175306'),
         ('A1250', 1, 'SC_DR02_2026-10-15', 'S6', '杨勇', '310104195510104341', '18136924703'),
         ('A1251', 1, 'SC_DR02_2026-10-15', 'S7', '胡强', '110101198605109943', '18086419758'),
         ('A1252', 1, 'SC_DR02_2026-10-15', 'S10', '赵芳', '320102198612280015', '18642053194'),
         ('A1253', 1, 'SC_DR02_2026-10-16', 'S3', '林娜', '440103200304077115', '19358124701'),
         ('A1254', 1, 'SC_DR02_2026-10-16', 'S6', '陈明', '440103200206256945', '15753186429'),
         ('A1255', 1, 'SC_DR02_2026-10-16', 'S7', '刘洋', '320102196310210012', '15925703687'),
         ('A1256', 1, 'SC_DR02_2026-10-16', 'S8', '林勇', '440103197009206127', '15206418530'),
         ('A1257', 1, 'SC_DR02_2026-10-16', 'S10', '胡平', '320102195109206842', '13802591366'),
         ('A1258', 1, 'SC_DR02_2026-10-16', 'S11', '孙丽', '110105197402161021', '19630875198'),
         ('A1259', 1, 'SC_DR02_2026-10-17', 'S2', '赵军', '310104195207032867', '18680357918'),
         ('A1260', 1, 'SC_DR02_2026-10-17', 'S3', '罗娟', '440305197011246041', '15207419630'),
         ('A1261', 1, 'SC_DR02_2026-10-17', 'S6', '马明', '310104195510103365', '18025713682'),
         ('A1262', 1, 'SC_DR02_2026-10-17', 'S7', '孙丽', '320102199302046797', '17530764183'),
         ('A1263', 1, 'SC_DR02_2026-10-17', 'S12', '高军', '320102195006267722', '17420831966'),
         ('A1264', 1, 'SC_DR02_2026-10-18', 'S2', '朱磊', '310104195006152520', '13318520741'),
         ('A1265', 1, 'SC_DR02_2026-10-18', 'S3', '李静', '310104195106022619', '17791368029'),
         ('A1266', 1, 'SC_DR02_2026-10-18', 'S4', '吴秀英', '110101199106130822', '18863190866'),
         ('A1267', 1, 'SC_DR02_2026-10-18', 'S6', '陈伟', '320102197302046552', '17974208537'),
         ('A1268', 1, 'SC_DR02_2026-10-18', 'S7', '黄艳', '110101199106289841', '15136824793'),
         ('A1269', 1, 'SC_DR02_2026-10-18', 'S9', '吴超', '110105197211241555', '15137902689'),
         ('A1270', 1, 'SC_DR02_2026-10-18', 'S11', '徐敏', '310101198812134436', '13420731966'),
         ('A1271', 1, 'SC_DR02_2026-10-18', 'S12', '朱霞', '310104199803055182', '19813579246'),
         ('A1272', 1, 'SC_DR02_2026-10-19', 'S1', '陈平', '440103198905243684', '13974108521'),
         ('A1273', 1, 'SC_DR02_2026-10-19', 'S4', '罗秀英', '32010219520715699X', '13791368025'),
         ('A1274', 1, 'SC_DR02_2026-10-19', 'S5', '徐静', '310101198101142253', '13862075190'),
         ('A1275', 1, 'SC_DR02_2026-10-19', 'S8', '罗秀英', '110105199306010126', '15791480259'),
         ('A1276', 1, 'SC_DR02_2026-10-19', 'S12', '马强', '320102197402046752', '17085219648'),
         ('A1277', 1, 'SC_DR02_2026-10-20', 'S1', '吴静', '310104197705221408', '15974108521'),
         ('A1278', 1, 'SC_DR02_2026-10-20', 'S2', '高静', '310101198803064544', '18792480354'),
         ('A1279', 1, 'SC_DR02_2026-10-20', 'S6', '杨勇', '110101195309201514', '13914680357'),
         ('A1280', 1, 'SC_DR02_2026-10-20', 'S7', '刘超', '310104199602176009', '15642953188'),
         ('A1281', 1, 'SC_DR02_2026-10-20', 'S9', '杨伟', '310104196410234928', '15630874194'),
         ('A1282', 1, 'SC_DR02_2026-10-20', 'S12', '郭军', '32010219830204827X', '18863197426'),
         ('A1283', 1, 'SC_DR03_2026-10-07', 'S1', '胡强', '310101195809204997', '13863197426'),
         ('A1284', 2, 'SC_DR03_2026-10-07', 'S1', '黄艳', '330102200205191770', '17802479130'),
         ('A1285', 3, 'SC_DR03_2026-10-07', 'S1', '高杰', '31010119841211281X', '13852074190'),
         ('A1286', 4, 'SC_DR03_2026-10-07', 'S1', '林芳', '440103200304077115', '19570246913'),
         ('A1287', 5, 'SC_DR03_2026-10-07', 'S1', '周芳', '310104196107165501', '15631952084'),
         ('A1288', 6, 'SC_DR03_2026-10-07', 'S1', '王敏', '330102195610237716', '13680279134'),
         ('A1289', 1, 'SC_DR03_2026-10-07', 'S2', '周杰', '110101200006281338', '17681370248'),
         ('A1290', 2, 'SC_DR03_2026-10-07', 'S2', '杨平', '440103200504217514', '17641952088'),
         ('A1291', 3, 'SC_DR03_2026-10-07', 'S2', '黄军', '310101199905262212', '17247013694'),
         ('A1292', 4, 'SC_DR03_2026-10-07', 'S2', '杨芳', '33010219800102791X', '17206419530'),
         ('A1293', 5, 'SC_DR03_2026-10-07', 'S2', '周军', '310101198001011993', '17792468135'),
         ('A1294', 6, 'SC_DR03_2026-10-07', 'S2', '王娟', '440103200406267315', '17742085319'),
         ('A1295', 7, 'SC_DR03_2026-10-07', 'S2', '周涛', '310101196512066284', '19248035914'),
         ('A1296', 8, 'SC_DR03_2026-10-07', 'S2', '徐丽', '440103196811255642', '15963108427'),
         ('A1297', 1, 'SC_DR03_2026-10-07', 'S3', '周秀英', '310101195308172990', '13751986205'),
         ('A1298', 2, 'SC_DR03_2026-10-07', 'S3', '何敏', '110105197412262061', '17025791467'),
         ('A1299', 1, 'SC_DR03_2026-10-07', 'S4', '胡芳', '440305197510107994', '13137902586'),
         ('A1300', 2, 'SC_DR03_2026-10-07', 'S4', '周秀英', '310104199204214209', '13863197420'),
         ('A1301', 3, 'SC_DR03_2026-10-07', 'S4', '刘磊', '330102197803227433', '13246835704'),
         ('A1302', 4, 'SC_DR03_2026-10-07', 'S4', '赵伟', '440103199506275739', '15752086319'),
         ('A1303', 5, 'SC_DR03_2026-10-07', 'S4', '孙明', '330102196903226855', '19369147025'),
         ('A1304', 1, 'SC_DR03_2026-10-07', 'S5', '朱丽', '330102199101020816', '18319720851'),
         ('A1305', 2, 'SC_DR03_2026-10-07', 'S5', '陈洋', '310104198604093026', '18680279133'),
         ('A1306', 3, 'SC_DR03_2026-10-07', 'S5', '胡超', '310101200008171412', '19539764083'),
         ('A1307', 4, 'SC_DR03_2026-10-07', 'S5', '林芳', '310104199505095725', '18570368143'),
         ('A1308', 5, 'SC_DR03_2026-10-07', 'S5', '马丽', '110105200306142941', '19208631970'),
         ('A1309', 6, 'SC_DR03_2026-10-07', 'S5', '朱明', '440305198209098253', '13135802473'),
         ('A1310', 7, 'SC_DR03_2026-10-07', 'S5', '孙强', '330102196508019282', '18530842977'),
         ('A1311', 1, 'SC_DR03_2026-10-07', 'S6', '高秀英', '440103197009075999', '19680357928'),
         ('A1312', 1, 'SC_DR03_2026-10-07', 'S7', '杨芳', '310101195305112925', '13630842973'),
         ('A1313', 2, 'SC_DR03_2026-10-07', 'S7', '何敏', '440103197011137028', '19136924703'),
         ('A1314', 1, 'SC_DR03_2026-10-07', 'S8', '黄军', '110101197612282301', '17137924809'),
         ('A1315', 2, 'SC_DR03_2026-10-07', 'S8', '吴静', '110105197911081783', '19530842977'),
         ('A1316', 1, 'SC_DR03_2026-10-07', 'S9', '罗杰', '310104199805246281', '15853196420'),
         ('A1317', 2, 'SC_DR03_2026-10-07', 'S9', '吴杰', '110101196610229481', '15035792468'),
         ('A1318', 3, 'SC_DR03_2026-10-07', 'S9', '周敏', '310104195006142453', '13641953074'),
         ('A1319', 1, 'SC_DR03_2026-10-07', 'S10', '马强', '320102198402058547', '18641975204'),
         ('A1320', 2, 'SC_DR03_2026-10-07', 'S10', '黄杰', '440305199905106469', '19681347023'),
         ('A1321', 3, 'SC_DR03_2026-10-07', 'S10', '何勇', '330102198101029111', '17642953084'),
         ('A1322', 1, 'SC_DR03_2026-10-07', 'S11', '徐涛', '110101199905281213', '17792480359'),
         ('A1323', 2, 'SC_DR03_2026-10-07', 'S11', '胡强', '330102196708020667', '18742063199'),
         ('A1324', 1, 'SC_DR03_2026-10-07', 'S12', '周娜', '320102198402059507', '18208531970'),
         ('A1325', 2, 'SC_DR03_2026-10-07', 'S12', '郭伟', '330102197812167452', '13247913584'),
         ('A1326', 3, 'SC_DR03_2026-10-07', 'S12', '胡艳', '320102196007278495', '18318520749'),
         ('A1327', 4, 'SC_DR03_2026-10-07', 'S12', '高静', '11010519781023279X', '17792468131'),
         ('A1328', 5, 'SC_DR03_2026-10-07', 'S12', '王杰', '110105200304082973', '19752064195'),
         ('A1329', 6, 'SC_DR03_2026-10-07', 'S12', '赵军', '310101198104072238', '17469158022'),
         ('A1330', 1, 'SC_DR03_2026-10-08', 'S1', '徐超', '440103198106123301', '17682479354'),
         ('A1331', 2, 'SC_DR03_2026-10-08', 'S1', '赵娜', '330102196909030132', '18758630759'),
         ('A1332', 3, 'SC_DR03_2026-10-08', 'S1', '胡平', '440305196910115833', '19257914685'),
         ('A1333', 4, 'SC_DR03_2026-10-08', 'S1', '胡磊', '110101199602051672', '19197508649'),
         ('A1334', 5, 'SC_DR03_2026-10-08', 'S1', '何敏', '310101198812284442', '18925781467'),
         ('A1335', 1, 'SC_DR03_2026-10-08', 'S2', '赵秀英', '310101198803193434', '13630874198'),
         ('A1336', 2, 'SC_DR03_2026-10-08', 'S2', '胡伟', '320102198612159864', '15570346927'),
         ('A1337', 3, 'SC_DR03_2026-10-08', 'S2', '赵芳', '110101196810070903', '18864175300'),
         ('A1338', 1, 'SC_DR03_2026-10-08', 'S3', '杨洋', '330102196911250070', '15680279130'),
         ('A1339', 2, 'SC_DR03_2026-10-08', 'S3', '孙静', '440305196710236550', '15085397428'),
         ('A1340', 1, 'SC_DR03_2026-10-08', 'S4', '李涛', '440305195205238032', '17631952088'),
         ('A1341', 2, 'SC_DR03_2026-10-08', 'S4', '何娜', '320102198402208592', '13570268131'),
         ('A1342', 3, 'SC_DR03_2026-10-08', 'S4', '黄娜', '330102196111108631', '18539764087'),
         ('A1343', 4, 'SC_DR03_2026-10-08', 'S4', '胡伟', '440103196111145549', '18469257036'),
         ('A1344', 5, 'SC_DR03_2026-10-08', 'S4', '马丽', '320102200006066588', '15975208641'),
         ('A1345', 6, 'SC_DR03_2026-10-08', 'S4', '李丽', '310101198101012205', '17924681357'),
         ('A1346', 7, 'SC_DR03_2026-10-08', 'S4', '罗涛', '440103196309214853', '15852074196'),
         ('A1347', 1, 'SC_DR03_2026-10-08', 'S5', '刘艳', '330102196407160279', '15814679356'),
         ('A1348', 2, 'SC_DR03_2026-10-08', 'S5', '郭勇', '330102198204088106', '17185329649'),
         ('A1349', 3, 'SC_DR03_2026-10-08', 'S5', '周杰', '110105197402030873', '17914603577'),
         ('A1350', 4, 'SC_DR03_2026-10-08', 'S5', '郭洋', '440305197612018159', '17197520869'),
         ('A1351', 5, 'SC_DR03_2026-10-08', 'S5', '徐超', '110101197601282402', '17571368243'),
         ('A1352', 1, 'SC_DR03_2026-10-08', 'S6', '徐静', '330102196407019187', '18863175201'),
         ('A1353', 2, 'SC_DR03_2026-10-08', 'S6', '朱伟', '31010419940409562X', '18258036910'),
         ('A1354', 1, 'SC_DR03_2026-10-08', 'S7', '徐娟', '110105198111252171', '17579146803'),
         ('A1355', 1, 'SC_DR03_2026-10-08', 'S8', '陈霞', '310104196410235998', '15975318647'),
         ('A1356', 2, 'SC_DR03_2026-10-08', 'S8', '吴娟', '310104195207032787', '18924681355'),
         ('A1357', 3, 'SC_DR03_2026-10-08', 'S8', '周敏', '310101199001143819', '13085297412'),
         ('A1358', 4, 'SC_DR03_2026-10-08', 'S8', '徐超', '440305195104097795', '13581347020'),
         ('A1359', 5, 'SC_DR03_2026-10-08', 'S8', '杨霞', '440103197009207138', '15429731862'),
         ('A1360', 1, 'SC_DR03_2026-10-08', 'S9', '胡伟', '440103197212147505', '19025713682'),
         ('A1361', 2, 'SC_DR03_2026-10-08', 'S9', '何杰', '440305197510233712', '13530842963'),
         ('A1362', 3, 'SC_DR03_2026-10-08', 'S9', '朱明', '440103200504096484', '19579136802'),
         ('A1363', 1, 'SC_DR03_2026-10-08', 'S10', '王丽', '110105197901022974', '17804691576'),
         ('A1364', 1, 'SC_DR03_2026-10-08', 'S11', '吴超', '310101198803194509', '13853196420'),
         ('A1365', 2, 'SC_DR03_2026-10-08', 'S11', '徐涛', '110101196409219185', '15579146803'),
         ('A1366', 3, 'SC_DR03_2026-10-08', 'S11', '周秀英', '440305196509225104', '15317520641'),
         ('A1367', 1, 'SC_DR03_2026-10-08', 'S12', '郭伟', '44030519550817753X', '13680279134'),
         ('A1368', 2, 'SC_DR03_2026-10-08', 'S12', '高勇', '110105199704101912', '19197408539'),
         ('A1369', 3, 'SC_DR03_2026-10-08', 'S12', '王强', '33010219590818926X', '13136892578'),
         ('A1370', 4, 'SC_DR03_2026-10-08', 'S12', '刘平', '440305199604214968', '15207419634'),
         ('A1371', 1, 'SC_DR03_2026-10-09', 'S1', '李超', '320102196307288994', '18084297312'),
         ('A1372', 2, 'SC_DR03_2026-10-09', 'S1', '何敏', '320102196009209514', '13681409684'),
         ('A1373', 3, 'SC_DR03_2026-10-09', 'S1', '李涛', '320102198603060002', '18631975204'),
         ('A1374', 4, 'SC_DR03_2026-10-09', 'S1', '王静', '110101196612279466', '15802491356'),
         ('A1375', 1, 'SC_DR03_2026-10-09', 'S2', '孙霞', '110105198311263545', '17793568245'),
         ('A1376', 1, 'SC_DR03_2026-10-09', 'S3', '胡强', '440305195004227724', '17308629755'),
         ('A1377', 2, 'SC_DR03_2026-10-09', 'S3', '马超', '110105200306021867', '17702481359'),
         ('A1378', 1, 'SC_DR03_2026-10-09', 'S4', '周军', '110101197412271018', '17468057911'),
         ('A1379', 2, 'SC_DR03_2026-10-09', 'S4', '何艳', '440103196109205397', '15974286317'),
         ('A1380', 3, 'SC_DR03_2026-10-09', 'S4', '罗静', '310101197812282741', '17247913680'),
         ('A1381', 1, 'SC_DR03_2026-10-09', 'S5', '杨芳', '110101197701131417', '19641875298'),
         ('A1382', 2, 'SC_DR03_2026-10-09', 'S5', '马平', '310104195906025201', '18914780361'),
         ('A1383', 3, 'SC_DR03_2026-10-09', 'S5', '李娟', '440305200005236554', '15319620755'),
         ('A1384', 4, 'SC_DR03_2026-10-09', 'S5', '黄艳', '11010519791124188X', '17035791468'),
         ('A1385', 5, 'SC_DR03_2026-10-09', 'S5', '胡洋', '110101199903061217', '19429731862'),
         ('A1386', 1, 'SC_DR03_2026-10-09', 'S6', '罗静', '440103199905126458', '19682479354'),
         ('A1387', 1, 'SC_DR03_2026-10-09', 'S7', '张涛', '440305195207287989', '17631974208'),
         ('A1388', 2, 'SC_DR03_2026-10-09', 'S7', '吴杰', '310104198402032663', '17680357924'),
         ('A1389', 1, 'SC_DR03_2026-10-09', 'S8', '高秀英', '440103197209086350', '19913580241'),
         ('A1390', 1, 'SC_DR03_2026-10-09', 'S9', '陈伟', '33010219920103991X', '18185397428'),
         ('A1391', 2, 'SC_DR03_2026-10-09', 'S9', '周娟', '440103196610116355', '19681479358'),
         ('A1392', 1, 'SC_DR03_2026-10-09', 'S10', '周娜', '440103199803186337', '15429731866'),
         ('A1393', 2, 'SC_DR03_2026-10-09', 'S10', '孙超', '440305197512166891', '13479158026'),
         ('A1394', 1, 'SC_DR03_2026-10-09', 'S11', '何秀英', '440305195505128580', '13792458134'),
         ('A1395', 1, 'SC_DR03_2026-10-09', 'S12', '高娟', '110101197409050863', '19318620755'),
         ('A1396', 2, 'SC_DR03_2026-10-09', 'S12', '林娜', '310101198903064656', '18682479354'),
         ('A1397', 3, 'SC_DR03_2026-10-09', 'S12', '林磊', '110105200306153050', '19308641971'),
         ('A1398', 4, 'SC_DR03_2026-10-09', 'S12', '胡霞', '310104198605103126', '18025714688'),
         ('A1399', 5, 'SC_DR03_2026-10-09', 'S12', '李明', '110105199406140358', '19296430750'),
         ('A1400', 1, 'SC_DR03_2026-10-10', 'S1', '徐敏', '320102197502058056', '17642085314'),
         ('A1401', 1, 'SC_DR03_2026-10-10', 'S2', '王静', '310101200108051581', '17792480359'),
         ('A1402', 2, 'SC_DR03_2026-10-10', 'S2', '赵娟', '440305200105246768', '15429730866'),
         ('A1403', 1, 'SC_DR03_2026-10-10', 'S3', '罗涛', '110101198705119145', '18085219638'),
         ('A1404', 2, 'SC_DR03_2026-10-10', 'S3', '赵娟', '310101198512273960', '18248013790'),
         ('A1405', 3, 'SC_DR03_2026-10-10', 'S3', '刘超', '330102199101030870', '18631952084'),
         ('A1406', 4, 'SC_DR03_2026-10-10', 'S3', '高秀英', '440305198410108636', '13802479130'),
         ('A1407', 1, 'SC_DR03_2026-10-10', 'S4', '李强', '110105199604251681', '15036892572'),
         ('A1408', 2, 'SC_DR03_2026-10-10', 'S4', '黄芳', '110105197302160849', '19318652976'),
         ('A1409', 3, 'SC_DR03_2026-10-10', 'S4', '李丽', '11010520050703228X', '17914602571'),
         ('A1410', 4, 'SC_DR03_2026-10-10', 'S4', '高军', '330102195107097947', '17964207531'),
         ('A1411', 5, 'SC_DR03_2026-10-10', 'S4', '朱平', '440305196901176909', '19803591460'),
         ('A1412', 1, 'SC_DR03_2026-10-10', 'S5', '胡强', '320102197111257226', '15086397528'),
         ('A1413', 1, 'SC_DR03_2026-10-10', 'S6', '徐娟', '310101200406012150', '17924680351'),
         ('A1414', 2, 'SC_DR03_2026-10-10', 'S6', '吴秀英', '330102196903066847', '15186429759'),
         ('A1415', 1, 'SC_DR03_2026-10-10', 'S7', '黄芳', '320102197412276818', '17085297418'),
         ('A1416', 2, 'SC_DR03_2026-10-10', 'S7', '孙霞', '31010120040807307X', '17358146925'),
         ('A1417', 1, 'SC_DR03_2026-10-10', 'S8', '王杰', '310101198104073281', '17703581465'),
         ('A1418', 2, 'SC_DR03_2026-10-10', 'S8', '林勇', '110101196409059177', '18185397423'),
         ('A1419', 3, 'SC_DR03_2026-10-10', 'S8', '孙超', '110105195105262724', '18135802473'),
         ('A1420', 1, 'SC_DR03_2026-10-10', 'S9', '高勇', '440305199907016539', '15208531964'),
         ('A1421', 1, 'SC_DR03_2026-10-10', 'S10', '王超', '320102199302056899', '18539764183'),
         ('A1422', 2, 'SC_DR03_2026-10-10', 'S10', '周娟', '320102195806139067', '13358024791'),
         ('A1423', 3, 'SC_DR03_2026-10-10', 'S10', '李娟', '330102199001020739', '18419730862'),
         ('A1424', 1, 'SC_DR03_2026-10-10', 'S11', '张丽', '310104195610113464', '18024713682'),
         ('A1425', 2, 'SC_DR03_2026-10-10', 'S11', '周芳', '330102196005229499', '18864175300'),
         ('A1426', 1, 'SC_DR03_2026-10-10', 'S12', '杨平', '110105199306141169', '18752086315'),
         ('A1427', 1, 'SC_DR03_2026-10-11', 'S1', '徐娟', '310101198703063341', '18691370244'),
         ('A1428', 1, 'SC_DR03_2026-10-11', 'S2', '何艳', '330102196510070319', '18864297531'),
         ('A1429', 2, 'SC_DR03_2026-10-11', 'S2', '陈磊', '330102195908188267', '13680257913'),
         ('A1430', 3, 'SC_DR03_2026-10-11', 'S2', '张明', '11010519970410091X', '19428630752'),
         ('A1431', 4, 'SC_DR03_2026-10-11', 'S2', '张洋', '440103196008075212', '18469135806'),
         ('A1432', 1, 'SC_DR03_2026-10-11', 'S3', '胡伟', '440305195608188789', '13914702587'),
         ('A1433', 2, 'SC_DR03_2026-10-11', 'S3', '徐丽', '440103198211102342', '13530742967'),
         ('A1434', 1, 'SC_DR03_2026-10-11', 'S4', '郭勇', '110101197610071316', '19317520645'),
         ('A1435', 1, 'SC_DR03_2026-10-11', 'S5', '高秀英', '310104199101024066', '18024691358'),
         ('A1436', 2, 'SC_DR03_2026-10-11', 'S5', '孙敏', '44010319920625512X', '13085319642'),
         ('A1437', 3, 'SC_DR03_2026-10-11', 'S5', '刘艳', '440103196702216564', '19804692570'),
         ('A1438', 4, 'SC_DR03_2026-10-11', 'S5', '马强', '310101198903193597', '13207531864'),
         ('A1439', 1, 'SC_DR03_2026-10-11', 'S6', '吴娜', '110105198111093318', '13631952088'),
         ('A1440', 2, 'SC_DR03_2026-10-11', 'S6', '赵军', '310104196009084193', '18791480359'),
         ('A1441', 3, 'SC_DR03_2026-10-11', 'S6', '孙强', '310104198404212756', '13196420753'),
         ('A1442', 1, 'SC_DR03_2026-10-11', 'S7', '朱平', '310104199602045877', '19026891578'),
         ('A1443', 2, 'SC_DR03_2026-10-11', 'S7', '杨伟', '110105199807161053', '19863097416'),
         ('A1444', 1, 'SC_DR03_2026-10-11', 'S8', '刘平', '110105195107162620', '13530874193'),
         ('A1445', 2, 'SC_DR03_2026-10-11', 'S8', '孙霞', '110101196610220532', '15804679256'),
         ('A1446', 1, 'SC_DR03_2026-10-11', 'S9', '徐涛', '440103196811125602', '19681379248'),
         ('A1447', 1, 'SC_DR03_2026-10-11', 'S10', '张强', '310101198801283460', '18802469135'),
         ('A1448', 2, 'SC_DR03_2026-10-11', 'S10', '林磊', '110105197001141257', '18853197420'),
         ('A1449', 3, 'SC_DR03_2026-10-11', 'S10', '赵娟', '310104196410105966', '19682479358'),
         ('A1450', 1, 'SC_DR03_2026-10-11', 'S11', '王涛', '440305195405247443', '17752064190'),
         ('A1451', 2, 'SC_DR03_2026-10-11', 'S11', '郭秀英', '330102197011251232', '15792480355'),
         ('A1452', 3, 'SC_DR03_2026-10-11', 'S11', '王娟', '440305197801028460', '17742085314'),
         ('A1453', 4, 'SC_DR03_2026-10-11', 'S11', '罗敏', '310101197502041184', '17913502466'),
         ('A1454', 1, 'SC_DR03_2026-10-11', 'S12', '徐明', '110101197410212006', '17570346913'),
         ('A1455', 1, 'SC_DR03_2026-10-12', 'S1', '吴静', '440103196011254203', '13074218537'),
         ('A1456', 2, 'SC_DR03_2026-10-12', 'S1', '何敏', '320102195706139027', '13247913689'),
         ('A1457', 1, 'SC_DR03_2026-10-12', 'S2', '郭娜', '31010120000805243X', '17581369247'),
         ('A1458', 2, 'SC_DR03_2026-10-12', 'S2', '朱磊', '440103195908194060', '13530742963'),
         ('A1459', 3, 'SC_DR03_2026-10-12', 'S2', '林伟', '31010119770827141X', '17035791468'),
         ('A1460', 1, 'SC_DR03_2026-10-12', 'S3', '李娟', '310101200408193119', '19641975204'),
         ('A1461', 1, 'SC_DR03_2026-10-12', 'S4', '王敏', '320102197712157204', '13246913584'),
         ('A1462', 1, 'SC_DR03_2026-10-12', 'S5', '郭勇', '33010220030204860X', '18074286317'),
         ('A1463', 2, 'SC_DR03_2026-10-12', 'S5', '李磊', '320102197602218133', '13248035914'),
         ('A1464', 1, 'SC_DR03_2026-10-12', 'S6', '孙霞', '440305196810116732', '19025791462'),
         ('A1465', 2, 'SC_DR03_2026-10-12', 'S6', '张霞', '310104198304212636', '13317542865'),
         ('A1466', 3, 'SC_DR03_2026-10-12', 'S6', '高秀英', '440305197701177346', '13246835794'),
         ('A1467', 1, 'SC_DR03_2026-10-12', 'S7', '徐敏', '310101199905112281', '19975386427'),
         ('A1468', 1, 'SC_DR03_2026-10-12', 'S8', '杨艳', '440305200208186024', '19702491355'),
         ('A1469', 1, 'SC_DR03_2026-10-12', 'S9', '张明', '110105197001140203', '18963107421'),
         ('A1470', 2, 'SC_DR03_2026-10-12', 'S9', '李磊', '310104195307033998', '18469135806'),
         ('A1471', 1, 'SC_DR03_2026-10-12', 'S10', '赵芳', '310104198204203484', '13752086419'),
         ('A1472', 2, 'SC_DR03_2026-10-12', 'S10', '李丽', '440103198203062424', '19680357924'),
         ('A1473', 1, 'SC_DR03_2026-10-12', 'S11', '郭秀英', '11010119641227023X', '15570268133'),
         ('A1474', 1, 'SC_DR03_2026-10-12', 'S12', '吴静', '310104198504212833', '13862097310'),
         ('A1475', 1, 'SC_DR03_2026-10-13', 'S1', '何敏', '310101199101025019', '18692458134'),
         ('A1476', 2, 'SC_DR03_2026-10-13', 'S1', '刘霞', '310104195209212845', '13318542971'),
         ('A1477', 1, 'SC_DR03_2026-10-13', 'S2', '赵娜', '110101197109040452', '19751964089'),
         ('A1478', 1, 'SC_DR03_2026-10-13', 'S4', '杨平', '310101199003204849', '13196420753'),
         ('A1479', 2, 'SC_DR03_2026-10-13', 'S4', '李静', '110105197111240467', '15469135802'),
         ('A1480', 1, 'SC_DR03_2026-10-13', 'S5', '杨勇', '440305195107167912', '13358146921'),
         ('A1481', 1, 'SC_DR03_2026-10-13', 'S6', '孙强', '330102200210075934', '18429763087'),
         ('A1482', 1, 'SC_DR03_2026-10-13', 'S9', '罗军', '110101199803222167', '17914680351'),
         ('A1483', 2, 'SC_DR03_2026-10-13', 'S9', '黄芳', '320102196009048378', '18074218532'),
         ('A1484', 1, 'SC_DR03_2026-10-13', 'S11', '徐敏', '440103197508188015', '17319620851'),
         ('A1485', 1, 'SC_DR03_2026-10-13', 'S12', '何芳', '330102197901167649', '13246813574'),
         ('A1486', 2, 'SC_DR03_2026-10-13', 'S12', '杨平', '310101195308184131', '13964207866'),
         ('A1487', 1, 'SC_DR03_2026-10-14', 'S1', '李涛', '440305197510238046', '17197508649'),
         ('A1488', 2, 'SC_DR03_2026-10-14', 'S1', '朱明', '110105197001020252', '15146825799'),
         ('A1489', 1, 'SC_DR03_2026-10-14', 'S3', '高娟', '440305198011257749', '17863175206'),
         ('A1490', 1, 'SC_DR03_2026-10-14', 'S4', '孙霞', '440103196610116371', '19692470358'),
         ('A1491', 1, 'SC_DR03_2026-10-14', 'S5', '朱强', '320102198202049195', '17531964203'),
         ('A1492', 2, 'SC_DR03_2026-10-14', 'S5', '胡霞', '440103196109084492', '18468135706'),
         ('A1493', 1, 'SC_DR03_2026-10-14', 'S7', '张明', '310104196310224853', '15418652972'),
         ('A1494', 1, 'SC_DR03_2026-10-14', 'S8', '孙霞', '440305195205108107', '13571346023'),
         ('A1495', 1, 'SC_DR03_2026-10-14', 'S9', '胡强', '310104199402165540', '15086497533'),
         ('A1496', 1, 'SC_DR03_2026-10-14', 'S12', '朱强', '440103199903186545', '15531942087'),
         ('A1497', 1, 'SC_DR03_2026-10-15', 'S3', '马平', '440103199604095926', '19137902589'),
         ('A1498', 1, 'SC_DR03_2026-10-15', 'S4', '王超', '110101196712129633', '18974218532'),
         ('A1499', 1, 'SC_DR03_2026-10-15', 'S5', '陈洋', '440305199707155040', '19803591466'),
         ('A1500', 1, 'SC_DR03_2026-10-15', 'S7', '李强', '440305200208187043', '19359146021'),
         ('A1501', 1, 'SC_DR03_2026-10-15', 'S8', '胡艳', '31010119990511130X', '19862075196'),
         ('A1502', 1, 'SC_DR03_2026-10-15', 'S9', '杨艳', '110101198803219289', '15468135706'),
         ('A1503', 1, 'SC_DR03_2026-10-15', 'S11', '高娟', '320102196209068816', '18974218532'),
         ('A1504', 1, 'SC_DR03_2026-10-15', 'S12', '王强', '320102195809199102', '13804691576'),
         ('A1505', 1, 'SC_DR03_2026-10-16', 'S1', '林勇', '31010119520511291X', '13418630752'),
         ('A1506', 1, 'SC_DR03_2026-10-16', 'S2', '张磊', '110105200504253386', '17136902583'),
         ('A1507', 1, 'SC_DR03_2026-10-16', 'S3', '高勇', '310104196307175886', '15863175206'),
         ('A1508', 2, 'SC_DR03_2026-10-16', 'S3', '马超', '330102196011248418', '13580269133'),
         ('A1509', 1, 'SC_DR03_2026-10-16', 'S6', '陈勇', '440305198001188823', '13581369247'),
         ('A1510', 1, 'SC_DR03_2026-10-16', 'S7', '林磊', '440103197111267313', '17531864200'),
         ('A1511', 1, 'SC_DR03_2026-10-16', 'S8', '赵军', '330102197009190223', '15792468135'),
         ('A1512', 1, 'SC_DR03_2026-10-16', 'S10', '徐秀英', '440305196409226089', '15197408539'),
         ('A1513', 1, 'SC_DR03_2026-10-16', 'S12', '周敏', '110101198602048903', '18640853974'),
         ('A1514', 1, 'SC_DR03_2026-10-17', 'S2', '罗涛', '440305195612283631', '13752086315'),
         ('A1515', 2, 'SC_DR03_2026-10-17', 'S2', '何敏', '11010119651021037X', '15359124801'),
         ('A1516', 1, 'SC_DR03_2026-10-17', 'S3', '陈磊', '330102199204249963', '15691370248'),
         ('A1517', 1, 'SC_DR03_2026-10-17', 'S4', '陈明', '440305197410227788', '17753164205'),
         ('A1518', 1, 'SC_DR03_2026-10-17', 'S5', '赵娟', '110101199803212014', '17793568249'),
         ('A1519', 1, 'SC_DR03_2026-10-17', 'S7', '郭伟', '33010219900118969X', '15802579140'),
         ('A1520', 1, 'SC_DR03_2026-10-17', 'S8', '罗杰', '31010119890319459X', '13319752086'),
         ('A1521', 1, 'SC_DR03_2026-10-17', 'S9', '朱平', '440103198102123259', '17804692576'),
         ('A1522', 1, 'SC_DR03_2026-10-17', 'S10', '罗丽', '310101200509073271', '17803691470'),
         ('A1523', 1, 'SC_DR03_2026-10-17', 'S11', '徐秀英', '330102198404099600', '18530864193'),
         ('A1524', 1, 'SC_DR03_2026-10-19', 'S3', '周娟', '330102199104240849', '15570368147'),
         ('A1525', 1, 'SC_DR03_2026-10-19', 'S4', '马磊', '110101199903071271', '19418630752'),
         ('A1526', 1, 'SC_DR03_2026-10-19', 'S6', '林洋', '440305197510227910', '17186407539'),
         ('A1527', 2, 'SC_DR03_2026-10-19', 'S6', '赵勇', '110105196901010119', '15135724688'),
         ('A1528', 1, 'SC_DR03_2026-10-19', 'S7', '李强', '320102198311149419', '13469235819'),
         ('A1529', 1, 'SC_DR03_2026-10-19', 'S10', '周杰', '330102197901177708', '13803579240'),
         ('A1530', 1, 'SC_DR03_2026-10-19', 'S11', '王涛', '110105199704100880', '19529731862'),
         ('A1531', 1, 'SC_DR03_2026-10-19', 'S12', '张磊', '310101200105282683', '17026891572'),
         ('A1532', 1, 'SC_DR03_2026-10-20', 'S3', '杨军', '310101195706014787', '18915780461'),
         ('A1533', 1, 'SC_DR03_2026-10-20', 'S4', '高娟', '310101195308173053', '13539764183'),
         ('A1534', 1, 'SC_DR03_2026-10-20', 'S5', '马明', '320102198202198131', '13479158026'),
         ('A1535', 1, 'SC_DR03_2026-10-20', 'S7', '李强', '310104196410105931', '19682479358'),
         ('A1536', 1, 'SC_DR03_2026-10-20', 'S10', '周军', '440305197901187733', '13357046915'),
         ('A1537', 1, 'SC_DR03_2026-10-20', 'S12', '胡伟', '440305197801178493', '13247935804'),
         ('A1538', 1, 'SC_DR04_2026-10-07', 'S1', '郭伟', '320102198312148434', '13802579140'),
         ('A1539', 2, 'SC_DR04_2026-10-07', 'S1', '张涛', '310104195309224077', '13641975204'),
         ('A1540', 3, 'SC_DR04_2026-10-07', 'S1', '陈勇', '320102195209218146', '13460257132'),
         ('A1541', 4, 'SC_DR04_2026-10-07', 'S1', '黄芳', '110105195007162535', '13752986305'),
         ('A1542', 1, 'SC_DR04_2026-10-07', 'S2', '陈明', '440103196708183257', '19853174205'),
         ('A1543', 2, 'SC_DR04_2026-10-07', 'S2', '何娜', '440305200108175782', '19246835700'),
         ('A1544', 3, 'SC_DR04_2026-10-07', 'S2', '李超', '31010120010818152X', '19207431850'),
         ('A1545', 1, 'SC_DR04_2026-10-07', 'S3', '周娟', '330102199101180756', '15793568249'),
         ('A1546', 2, 'SC_DR04_2026-10-07', 'S3', '周秀英', '310104199304214310', '15741985209'),
         ('A1547', 1, 'SC_DR04_2026-10-07', 'S4', '罗涛', '110105200507162367', '13752086315'),
         ('A1548', 1, 'SC_DR04_2026-10-07', 'S5', '陈磊', '320102198502218704', '13691370249'),
         ('A1549', 2, 'SC_DR04_2026-10-07', 'S5', '李娟', '310101199001144870', '13419730866'),
         ('A1550', 3, 'SC_DR04_2026-10-07', 'S5', '黄军', '33010219820118926X', '13803679250'),
         ('A1551', 4, 'SC_DR04_2026-10-07', 'S5', '黄芳', '440305196409214969', '15630852974'),
         ('A1552', 1, 'SC_DR04_2026-10-07', 'S6', '李娟', '310101195708194689', '13297530860'),
         ('A1553', 2, 'SC_DR04_2026-10-07', 'S6', '黄勇', '330102200001188203', '13246803574'),
         ('A1554', 1, 'SC_DR04_2026-10-07', 'S7', '徐明', '310104196510116195', '19247935814'),
         ('A1555', 1, 'SC_DR04_2026-10-07', 'S8', '黄娜', '320102195706257875', '17185307423'),
         ('A1556', 2, 'SC_DR04_2026-10-07', 'S8', '徐超', '330102196911241043', '15470258132'),
         ('A1557', 3, 'SC_DR04_2026-10-07', 'S8', '刘超', '320102198703060069', '18753196425'),
         ('A1558', 1, 'SC_DR04_2026-10-07', 'S9', '黄勇', '110101195505217599', '13791468025'),
         ('A1559', 2, 'SC_DR04_2026-10-07', 'S9', '朱丽', '330102195510078658', '17753086419'),
         ('A1560', 1, 'SC_DR04_2026-10-07', 'S10', '孙超', '310104196410104891', '19702481350'),
         ('A1561', 2, 'SC_DR04_2026-10-07', 'S10', '林洋', '310101198712124345', '13752064199'),
         ('A1562', 3, 'SC_DR04_2026-10-07', 'S10', '吴涛', '440103196309085772', '19359124805'),
         ('A1563', 1, 'SC_DR04_2026-10-07', 'S11', '孙丽', '330102199104089827', '18863097416'),
         ('A1564', 1, 'SC_DR04_2026-10-07', 'S12', '朱伟', '110105200106012704', '17925703681'),
         ('A1565', 1, 'SC_DR04_2026-10-08', 'S1', '高杰', '11010520030614199X', '19085329648'),
         ('A1566', 2, 'SC_DR04_2026-10-08', 'S1', '马平', '110101196209209900', '15359124701'),
         ('A1567', 3, 'SC_DR04_2026-10-08', 'S1', '刘明', '310101200105122559', '19319720861'),
         ('A1568', 4, 'SC_DR04_2026-10-08', 'S1', '周军', '320102198011137889', '13468035796'),
         ('A1569', 1, 'SC_DR04_2026-10-08', 'S2', '周娟', '330102198903230458', '15925703681'),
         ('A1570', 1, 'SC_DR04_2026-10-08', 'S3', '胡磊', '11010520030614295X', '19642075314'),
         ('A1571', 2, 'SC_DR04_2026-10-08', 'S3', '李丽', '110105199704260905', '17681357028'),
         ('A1572', 1, 'SC_DR04_2026-10-08', 'S4', '林平', '310104196407044998', '19357024695'),
         ('A1573', 2, 'SC_DR04_2026-10-08', 'S4', '林磊', '320102197602058213', '17420853192'),
         ('A1574', 1, 'SC_DR04_2026-10-08', 'S5', '黄芳', '310104199706150882', '19863175296'),
         ('A1575', 2, 'SC_DR04_2026-10-08', 'S5', '张洋', '310101195608074671', '18358046915'),
         ('A1576', 3, 'SC_DR04_2026-10-08', 'S5', '周芳', '440103198905244716', '13531964207'),
         ('A1577', 1, 'SC_DR04_2026-10-08', 'S6', '胡芳', '320102198111139013', '13814670351'),
         ('A1578', 1, 'SC_DR04_2026-10-08', 'S7', '吴娜', '440103197209217517', '17531842073'),
         ('A1579', 1, 'SC_DR04_2026-10-08', 'S8', '赵勇', '310104199505104724', '19246935700'),
         ('A1580', 2, 'SC_DR04_2026-10-08', 'S8', '朱丽', '11010119880306036X', '18420831972'),
         ('A1581', 1, 'SC_DR04_2026-10-08', 'S9', '黄娜', '440103198406262792', '13429653086'),
         ('A1582', 2, 'SC_DR04_2026-10-08', 'S9', '王丽', '32010219821113923X', '13804679350'),
         ('A1583', 1, 'SC_DR04_2026-10-08', 'S10', '朱丽', '110101197212101575', '19419752086'),
         ('A1584', 1, 'SC_DR04_2026-10-08', 'S11', '黄军', '11010119711125138X', '15681479254'),
         ('A1585', 2, 'SC_DR04_2026-10-08', 'S11', '郭勇', '110101197409050863', '19318520745'),
         ('A1586', 1, 'SC_DR04_2026-10-08', 'S12', '高娟', '110105198402162678', '13752086310'),
         ('A1587', 2, 'SC_DR04_2026-10-08', 'S12', '马平', '320102198111139101', '13137902683'),
         ('A1588', 1, 'SC_DR04_2026-10-09', 'S1', '马霞', '330102195608168694', '13469135802'),
         ('A1589', 1, 'SC_DR04_2026-10-09', 'S2', '林勇', '330102195908038226', '17974286315'),
         ('A1590', 1, 'SC_DR04_2026-10-09', 'S3', '郭伟', '11010119651021942X', '15791368024'),
         ('A1591', 2, 'SC_DR04_2026-10-09', 'S3', '高勇', '11010519780113264X', '19207531964'),
         ('A1592', 3, 'SC_DR04_2026-10-09', 'S3', '马平', '110105199507021606', '15130957136'),
         ('A1593', 1, 'SC_DR04_2026-10-09', 'S4', '林洋', '110105197302161892', '19752086319'),
         ('A1594', 2, 'SC_DR04_2026-10-09', 'S4', '刘强', '110101197309210831', '17791368025'),
         ('A1595', 3, 'SC_DR04_2026-10-09', 'S4', '张霞', '110105195004109229', '18751963085'),
         ('A1596', 1, 'SC_DR04_2026-10-09', 'S5', '朱平', '310104198805104457', '18469157032'),
         ('A1597', 2, 'SC_DR04_2026-10-09', 'S5', '李超', '11010519711109034X', '19529731867'),
         ('A1598', 1, 'SC_DR04_2026-10-09', 'S6', '林勇', '110101196312119065', '18317542865'),
         ('A1599', 1, 'SC_DR04_2026-10-09', 'S8', '罗军', '11010519940409145X', '19208619750'),
         ('A1600', 2, 'SC_DR04_2026-10-09', 'S8', '朱明', '330102196410229089', '15024613578'),
         ('A1601', 1, 'SC_DR04_2026-10-09', 'S9', '马平', '440103195908065058', '18248013794'),
         ('A1602', 2, 'SC_DR04_2026-10-09', 'S9', '马磊', '330102196111108615', '18863197420'),
         ('A1603', 1, 'SC_DR04_2026-10-09', 'S10', '孙霞', '310104196508056197', '19025891472'),
         ('A1604', 1, 'SC_DR04_2026-10-09', 'S11', '刘超', '320102198111259015', '17208519740'),
         ('A1605', 1, 'SC_DR04_2026-10-09', 'S12', '林平', '310104196006024195', '18579246817'),
         ('A1606', 2, 'SC_DR04_2026-10-09', 'S12', '刘明', '330102197803068575', '17319642071'),
         ('A1607', 1, 'SC_DR04_2026-10-10', 'S1', '何芳', '33010219890323941X', '15146825794'),
         ('A1608', 1, 'SC_DR04_2026-10-10', 'S2', '林磊', '330102199104080769', '18631974204'),
         ('A1609', 1, 'SC_DR04_2026-10-10', 'S4', '罗涛', '33010219880101931X', '18963185207'),
         ('A1610', 2, 'SC_DR04_2026-10-10', 'S4', '刘洋', '110101200006282488', '17460257136'),
         ('A1611', 1, 'SC_DR04_2026-10-10', 'S5', '朱霞', '11010519500425248X', '17025791462'),
         ('A1612', 1, 'SC_DR04_2026-10-10', 'S6', '郭洋', '320102198412279618', '18207519646'),
         ('A1613', 1, 'SC_DR04_2026-10-10', 'S9', '徐娟', '440305195307167140', '13579268133'),
         ('A1614', 2, 'SC_DR04_2026-10-10', 'S9', '高军', '44010319570818479X', '13086497538'),
         ('A1615', 1, 'SC_DR04_2026-10-10', 'S10', '黄艳', '440305196510105169', '19579146807'),
         ('A1616', 1, 'SC_DR04_2026-10-10', 'S11', '何杰', '330102198301038354', '18196308429'),
         ('A1617', 1, 'SC_DR04_2026-10-10', 'S12', '马平', '440103196309095866', '19915780461'),
         ('A1618', 2, 'SC_DR04_2026-10-10', 'S12', '黄芳', '310104198404212692', '13530864197'),
         ('A1619', 1, 'SC_DR04_2026-10-11', 'S1', '胡强', '110105197801142725', '19752086319'),
         ('A1620', 1, 'SC_DR04_2026-10-11', 'S2', '吴娟', '320102195809198150', '13802491366'),
         ('A1621', 1, 'SC_DR04_2026-10-11', 'S3', '高娟', '110101197701131513', '19195320643'),
         ('A1622', 2, 'SC_DR04_2026-10-11', 'S3', '高静', '440305197510107951', '13026891572'),
         ('A1623', 1, 'SC_DR04_2026-10-11', 'S5', '杨平', '310104199702176129', '15197408533'),
         ('A1624', 1, 'SC_DR04_2026-10-11', 'S6', '李静', '330102197009190258', '15024791368'),
         ('A1625', 1, 'SC_DR04_2026-10-11', 'S7', '李超', '440305195305237272', '17428631756'),
         ('A1626', 1, 'SC_DR04_2026-10-11', 'S10', '刘平', '110105196901139983', '18752986319'),
         ('A1627', 2, 'SC_DR04_2026-10-11', 'S10', '刘艳', '110101195103220509', '15248013794'),
         ('A1628', 1, 'SC_DR04_2026-10-11', 'S11', '赵勇', '440305200108175803', '19924603577'),
         ('A1629', 1, 'SC_DR04_2026-10-11', 'S12', '徐秀英', '110105197101141369', '19319642075'),
         ('A1630', 1, 'SC_DR04_2026-10-12', 'S1', '吴超', '110105200404243092', '17571346027'),
         ('A1631', 1, 'SC_DR04_2026-10-12', 'S3', '胡平', '110105200204248550', '13791368029'),
         ('A1632', 2, 'SC_DR04_2026-10-12', 'S3', '吴秀英', '440103196011255353', '15631974204'),
         ('A1633', 1, 'SC_DR04_2026-10-12', 'S4', '郭洋', '330102198703060095', '18531964203'),
         ('A1634', 1, 'SC_DR04_2026-10-12', 'S5', '赵娟', '310101195307054001', '18359146025'),
         ('A1635', 1, 'SC_DR04_2026-10-12', 'S7', '孙超', '32010219670221547X', '19136824793'),
         ('A1636', 1, 'SC_DR04_2026-10-12', 'S8', '徐秀英', '110105198111093182', '19186407533'),
         ('A1637', 2, 'SC_DR04_2026-10-12', 'S8', '周军', '44030519770117732X', '13587969137'),
         ('A1638', 1, 'SC_DR04_2026-10-12', 'S9', '赵娟', '320102195706139019', '13571346023'),
         ('A1639', 1, 'SC_DR04_2026-10-12', 'S11', '陈霞', '33010219610904961X', '18419730866'),
         ('A1640', 1, 'SC_DR04_2026-10-12', 'S12', '李静', '310104198602043148', '18791468035'),
         ('A1641', 1, 'SC_DR04_2026-10-13', 'S2', '何敏', '440103199905216453', '19136924709'),
         ('A1642', 1, 'SC_DR04_2026-10-13', 'S3', '陈明', '440305195007287781', '17642975308'),
         ('A1643', 1, 'SC_DR04_2026-10-13', 'S4', '何娜', '440103199803055310', '19924681357'),
         ('A1644', 1, 'SC_DR04_2026-10-13', 'S6', '陈勇', '11010519821125342X', '17358124701'),
         ('A1645', 1, 'SC_DR04_2026-10-13', 'S7', '张涛', '330102196909031186', '18086497532'),
         ('A1646', 1, 'SC_DR04_2026-10-13', 'S10', '李涛', '110101199805122071', '19197520869'),
         ('A1647', 1, 'SC_DR04_2026-10-14', 'S1', '徐涛', '31010120020528167X', '17357924685'),
         ('A1648', 1, 'SC_DR04_2026-10-14', 'S2', '刘明', '110105199805102041', '19420731962'),
         ('A1649', 1, 'SC_DR04_2026-10-14', 'S6', '高军', '110101198604109888', '18429753182'),
         ('A1650', 1, 'SC_DR04_2026-10-14', 'S7', '周涛', '440305196901176829', '19792580369'),
         ('A1651', 1, 'SC_DR04_2026-10-14', 'S12', '徐明', '440305196901176917', '19581369247'),
         ('A1652', 1, 'SC_DR04_2026-10-15', 'S3', '林勇', '310101197712121553', '19641853078'),
         ('A1653', 1, 'SC_DR04_2026-10-15', 'S6', '孙涛', '310101198003061994', '17791480255'),
         ('A1654', 1, 'SC_DR04_2026-10-15', 'S7', '林勇', '310101198204202394', '13641975208'),
         ('A1655', 1, 'SC_DR04_2026-10-15', 'S8', '马平', '320102197712168384', '13914780361'),
         ('A1656', 1, 'SC_DR04_2026-10-15', 'S10', '周敏', '110101199103079857', '18641953084'),
         ('A1657', 1, 'SC_DR04_2026-10-16', 'S3', '吴娟', '110101196412279189', '15468057911'),
         ('A1658', 1, 'SC_DR04_2026-10-16', 'S4', '罗杰', '440305200306257148', '15863174200'),
         ('A1659', 1, 'SC_DR04_2026-10-16', 'S8', '朱强', '440305197101037219', '15530864193'),
         ('A1660', 1, 'SC_DR04_2026-10-16', 'S12', '张丽', '330102196011248389', '13247935800'),
         ('A1661', 1, 'SC_DR04_2026-10-17', 'S4', '杨洋', '310101197602051339', '17791380241'),
         ('A1662', 1, 'SC_DR04_2026-10-17', 'S5', '徐静', '31010119780318172X', '19641875298'),
         ('A1663', 1, 'SC_DR04_2026-10-17', 'S9', '马强', '320102197512276938', '17085397428'),
         ('A1664', 1, 'SC_DR04_2026-10-17', 'S10', '林洋', '310104198710174399', '13641952088'),
         ('A1665', 1, 'SC_DR04_2026-10-18', 'S12', '赵娟', '440103200204077046', '19258014790'),
         ('A1666', 1, 'SC_DR04_2026-10-19', 'S2', '林平', '440305196901185936', '19681370248'),
         ('A1667', 1, 'SC_DR04_2026-10-19', 'S3', '赵秀英', '310104195610233490', '13974208537'),
         ('A1668', 1, 'SC_DR04_2026-10-19', 'S7', '朱磊', '310101200105121572', '19074296317'),
         ('A1669', 1, 'SC_DR04_2026-10-19', 'S12', '刘超', '330102197903078631', '17319742081'),
         ('A1670', 1, 'SC_DR04_2026-10-20', 'S3', '徐静', '330102196608029576', '18429631756'),
         ('A1671', 1, 'SC_DR04_2026-10-20', 'S7', '胡艳', '320102199709045059', '15206431754'),
         ('A1672', 1, 'SC_DR04_2026-10-20', 'S8', '张洋', '330102199302191283', '15682457038'),
         ('A1673', 1, 'SC_DR05_2026-10-07', 'S1', '张霞', '440305196612015383', '15752086315'),
         ('A1674', 2, 'SC_DR05_2026-10-07', 'S1', '徐明', '330102196407160201', '15925781467'),
         ('A1675', 3, 'SC_DR05_2026-10-07', 'S1', '杨平', '330102197001207115', '15318629751'),
         ('A1676', 4, 'SC_DR05_2026-10-07', 'S1', '李静', '440103196309094871', '19579146807'),
         ('A1677', 5, 'SC_DR05_2026-10-07', 'S1', '王涛', '440103200203205907', '15974186301'),
         ('A1678', 6, 'SC_DR05_2026-10-07', 'S1', '郭秀英', '320102196109219699', '13804692576'),
         ('A1679', 1, 'SC_DR05_2026-10-07', 'S2', '张洋', '31010419510908361X', '17359146025'),
         ('A1680', 1, 'SC_DR05_2026-10-07', 'S3', '朱强', '310104195410234296', '13752086315'),
         ('A1681', 2, 'SC_DR05_2026-10-07', 'S3', '陈洋', '330102199201189918', '15913580241'),
         ('A1682', 3, 'SC_DR05_2026-10-07', 'S3', '赵秀英', '440305200005235527', '15207519644'),
         ('A1683', 1, 'SC_DR05_2026-10-07', 'S4', '朱明', '330102198301198390', '13024691352'),
         ('A1684', 2, 'SC_DR05_2026-10-07', 'S4', '马丽', '440103196610246352', '15197420859'),
         ('A1685', 3, 'SC_DR05_2026-10-07', 'S4', '周娟', '310104199605105855', '19369157021'),
         ('A1686', 4, 'SC_DR05_2026-10-07', 'S4', '胡艳', '440103196312274822', '15085312648'),
         ('A1687', 5, 'SC_DR05_2026-10-07', 'S4', '陈洋', '310104198605103169', '18469158022'),
         ('A1688', 1, 'SC_DR05_2026-10-07', 'S5', '周敏', '310104195307163055', '13752064195'),
         ('A1689', 2, 'SC_DR05_2026-10-07', 'S5', '胡伟', '33010219820424931X', '13025813792'),
         ('A1690', 3, 'SC_DR05_2026-10-07', 'S5', '罗杰', '110105198302163614', '13964207531'),
         ('A1691', 4, 'SC_DR05_2026-10-07', 'S5', '郭伟', '44010319661011531X', '19146825793'),
         ('A1692', 5, 'SC_DR05_2026-10-07', 'S5', '吴静', '110105197402160926', '19084219532'),
         ('A1693', 6, 'SC_DR05_2026-10-07', 'S5', '王强', '440305197011127042', '19985757132'),
         ('A1694', 7, 'SC_DR05_2026-10-07', 'S5', '朱丽', '11010119710904148X', '19196408533'),
         ('A1695', 1, 'SC_DR05_2026-10-07', 'S6', '陈艳', '320102197512147925', '13803569240'),
         ('A1696', 2, 'SC_DR05_2026-10-07', 'S6', '吴敏', '32010219520905708X', '17185329643'),
         ('A1697', 1, 'SC_DR05_2026-10-07', 'S7', '郭艳', '310101195006143465', '13753164295'),
         ('A1698', 2, 'SC_DR05_2026-10-07', 'S7', '林平', '440305195007156650', '19136824799'),
         ('A1699', 3, 'SC_DR05_2026-10-07', 'S7', '高杰', '310101195207172895', '13852096315'),
         ('A1700', 1, 'SC_DR05_2026-10-07', 'S8', '高娜', '320102195309217204', '13913502466'),
         ('A1701', 2, 'SC_DR05_2026-10-07', 'S8', '王杰', '44030519771023826X', '17531942083'),
         ('A1702', 3, 'SC_DR05_2026-10-07', 'S8', '陈勇', '32010219570613893X', '13469135801'),
         ('A1703', 4, 'SC_DR05_2026-10-07', 'S8', '郭军', '310104199602174943', '15296418534'),
         ('A1704', 5, 'SC_DR05_2026-10-07', 'S8', '陈洋', '44010319580806391X', '18135802463'),
         ('A1705', 1, 'SC_DR05_2026-10-07', 'S9', '周秀英', '310101197603171383', '19641985209'),
         ('A1706', 2, 'SC_DR05_2026-10-07', 'S9', '周娟', '440103195908075176', '18147903684'),
         ('A1707', 3, 'SC_DR05_2026-10-07', 'S9', '刘超', '33010219670802078X', '18753164299'),
         ('A1708', 4, 'SC_DR05_2026-10-07', 'S9', '徐娟', '440305199604098223', '13136802479'),
         ('A1709', 5, 'SC_DR05_2026-10-07', 'S9', '赵秀英', '110105199704100872', '19974186307'),
         ('A1710', 6, 'SC_DR05_2026-10-07', 'S9', '张磊', '320102199506021575', '15581369247'),
         ('A1711', 7, 'SC_DR05_2026-10-07', 'S9', '胡强', '11010519770113260X', '19853196420'),
         ('A1712', 1, 'SC_DR05_2026-10-07', 'S10', '刘明', '440305200007016571', '15086319742'),
         ('A1713', 1, 'SC_DR05_2026-10-07', 'S11', '马平', '310101198104073329', '17803691476'),
         ('A1714', 2, 'SC_DR05_2026-10-07', 'S11', '陈伟', '320102195307287209', '17863075290'),
         ('A1715', 3, 'SC_DR05_2026-10-07', 'S11', '何芳', '110105195205262764', '18146802573'),
         ('A1716', 4, 'SC_DR05_2026-10-07', 'S11', '马静', '320102197211257434', '17197408639'),
         ('A1717', 5, 'SC_DR05_2026-10-07', 'S11', '李磊', '110105197111241507', '15136802579'),
         ('A1718', 1, 'SC_DR05_2026-10-07', 'S12', '杨伟', '110101196412119193', '18429653086'),
         ('A1719', 2, 'SC_DR05_2026-10-07', 'S12', '孙霞', '310101200005272357', '17804679350'),
         ('A1720', 3, 'SC_DR05_2026-10-07', 'S12', '孙静', '330102196808030926', '18207519644'),
         ('A1721', 1, 'SC_DR05_2026-10-08', 'S1', '林伟', '44010319610907442X', '18924681351'),
         ('A1722', 2, 'SC_DR05_2026-10-08', 'S1', '陈明', '440305197312277642', '17975318647'),
         ('A1723', 3, 'SC_DR05_2026-10-08', 'S1', '陈勇', '320102195909199249', '13358146921'),
         ('A1724', 1, 'SC_DR05_2026-10-08', 'S2', '赵芳', '32010219761227813X', '17531842073'),
         ('A1725', 2, 'SC_DR05_2026-10-08', 'S2', '高秀英', '110101197111070482', '15024613578'),
         ('A1726', 1, 'SC_DR05_2026-10-08', 'S3', '吴超', '330102198301189419', '13147902683'),
         ('A1727', 1, 'SC_DR05_2026-10-08', 'S4', '罗娟', '330102198304098360', '18207431850'),
         ('A1728', 2, 'SC_DR05_2026-10-08', 'S4', '黄杰', '330102196608170537', '15025791468'),
         ('A1729', 3, 'SC_DR05_2026-10-08', 'S4', '王杰', '320102198011258920', '17853164205'),
         ('A1730', 4, 'SC_DR05_2026-10-08', 'S4', '何娜', '310101200306281927', '17357924685'),
         ('A1731', 5, 'SC_DR05_2026-10-08', 'S4', '吴静', '440103200404206228', '15307529645'),
         ('A1732', 6, 'SC_DR05_2026-10-08', 'S4', '朱平', '320102195909209398', '13692480354'),
         ('A1733', 1, 'SC_DR05_2026-10-08', 'S5', '王静', '310101200108061659', '17792480359'),
         ('A1734', 2, 'SC_DR05_2026-10-08', 'S5', '赵伟', '320102195006267685', '17531942077'),
         ('A1735', 3, 'SC_DR05_2026-10-08', 'S5', '朱伟', '110105200504253386', '17248013794'),
         ('A1736', 4, 'SC_DR05_2026-10-08', 'S5', '赵娜', '330102198712289086', '18741963085'),
         ('A1737', 1, 'SC_DR05_2026-10-08', 'S6', '陈明', '310101200108182637', '19429753082'),
         ('A1738', 2, 'SC_DR05_2026-10-08', 'S6', '吴杰', '440103196908075832', '19579246817'),
         ('A1739', 1, 'SC_DR05_2026-10-08', 'S7', '赵杰', '310104195109083652', '17369147025'),
         ('A1740', 1, 'SC_DR05_2026-10-08', 'S8', '吴静', '330102195708027979', '17529741867'),
         ('A1741', 2, 'SC_DR05_2026-10-08', 'S8', '李磊', '110105197502042089', '17247935809'),
         ('A1742', 3, 'SC_DR05_2026-10-08', 'S8', '杨平', '440103195710244739', '13075319648'),
         ('A1743', 1, 'SC_DR05_2026-10-08', 'S9', '陈磊', '440305196405129177', '15135802469'),
         ('A1744', 2, 'SC_DR05_2026-10-08', 'S9', '李娟', '110105197801142709', '19197520863'),
         ('A1745', 1, 'SC_DR05_2026-10-08', 'S10', '林伟', '33010219800323789X', '13257936804'),
         ('A1746', 2, 'SC_DR05_2026-10-08', 'S10', '林磊', '310104198502163927', '13086497533'),
         ('A1747', 3, 'SC_DR05_2026-10-08', 'S10', '张磊', '110105200204242896', '17136802573'),
         ('A1748', 1, 'SC_DR05_2026-10-08', 'S11', '胡洋', '440103196211264596', '15185329648'),
         ('A1749', 2, 'SC_DR05_2026-10-08', 'S11', '李磊', '440103200103076765', '19570346923'),
         ('A1750', 3, 'SC_DR05_2026-10-08', 'S11', '周芳', '310104195906155161', '13642953084'),
         ('A1751', 4, 'SC_DR05_2026-10-08', 'S11', '黄艳', '330102198201188160', '13802579140'),
         ('A1752', 1, 'SC_DR05_2026-10-08', 'S12', '李磊', '11010119860426989X', '15247035814'),
         ('A1753', 1, 'SC_DR05_2026-10-09', 'S1', '赵伟', '310101198101143205', '19641953088'),
         ('A1754', 2, 'SC_DR05_2026-10-09', 'S1', '马明', '310104195209092767', '18791480359'),
         ('A1755', 3, 'SC_DR05_2026-10-09', 'S1', '胡洋', '320102196009048378', '18751986209'),
         ('A1756', 1, 'SC_DR05_2026-10-09', 'S2', '张强', '11010119630920906X', '15246913580'),
         ('A1757', 2, 'SC_DR05_2026-10-09', 'S2', '罗丽', '310104199605225865', '15975208631'),
         ('A1758', 3, 'SC_DR05_2026-10-09', 'S2', '胡伟', '110105199506021567', '15036824793'),
         ('A1759', 4, 'SC_DR05_2026-10-09', 'S2', '吴敏', '310104198605223160', '13082319642'),
         ('A1760', 1, 'SC_DR05_2026-10-09', 'S3', '李明', '11010519751211113X', '19207519645'),
         ('A1761', 2, 'SC_DR05_2026-10-09', 'S3', '朱伟', '440103199206135232', '18925703687'),
         ('A1762', 3, 'SC_DR05_2026-10-09', 'S3', '陈明', '32010219740205789X', '17853196425'),
         ('A1763', 4, 'SC_DR05_2026-10-09', 'S3', '郭芳', '310104199605104879', '19025757988'),
         ('A1764', 5, 'SC_DR05_2026-10-09', 'S3', '徐丽', '440305197801027521', '17207531860'),
         ('A1765', 6, 'SC_DR05_2026-10-09', 'S3', '高静', '44010319930407543X', '18570346923'),
         ('A1766', 1, 'SC_DR05_2026-10-09', 'S4', '罗静', '320102200408197353', '19792480355'),
         ('A1767', 2, 'SC_DR05_2026-10-09', 'S4', '孙丽', '310101197612111235', '19752964189'),
         ('A1768', 3, 'SC_DR05_2026-10-09', 'S4', '周军', '110105200508252356', '17468025796'),
         ('A1769', 1, 'SC_DR05_2026-10-09', 'S5', '何艳', '110105197302161841', '19420753186'),
         ('A1770', 2, 'SC_DR05_2026-10-09', 'S5', '高娜', '310104199101024058', '18357024691'),
         ('A1771', 3, 'SC_DR05_2026-10-09', 'S5', '黄芳', '330102199302030113', '18752964085'),
         ('A1772', 4, 'SC_DR05_2026-10-09', 'S5', '陈勇', '310101195305274107', '18147903684'),
         ('A1773', 1, 'SC_DR05_2026-10-09', 'S6', '朱明', '11010119621126882X', '15680379144'),
         ('A1774', 2, 'SC_DR05_2026-10-09', 'S6', '罗军', '310104196608186300', '15207519640'),
         ('A1775', 3, 'SC_DR05_2026-10-09', 'S6', '陈艳', '320102195906149385', '13814670356'),
         ('A1776', 4, 'SC_DR05_2026-10-09', 'S6', '朱洋', '310104199702175089', '15863075290'),
         ('A1777', 5, 'SC_DR05_2026-10-09', 'S6', '李丽', '110105199704250782', '17468035796'),
         ('A1778', 6, 'SC_DR05_2026-10-09', 'S6', '胡强', '310104196410236106', '15429753082'),
         ('A1779', 1, 'SC_DR05_2026-10-09', 'S7', '罗涛', '320102195109056899', '17863197420'),
         ('A1780', 1, 'SC_DR05_2026-10-09', 'S8', '李磊', '310101200105272565', '17915780461'),
         ('A1781', 2, 'SC_DR05_2026-10-09', 'S8', '周秀英', '110101196211108770', '18429653076'),
         ('A1782', 1, 'SC_DR05_2026-10-09', 'S9', '罗军', '110105199404081294', '19318620751'),
         ('A1783', 2, 'SC_DR05_2026-10-09', 'S9', '何芳', '310101198903073640', '18702491355'),
         ('A1784', 3, 'SC_DR05_2026-10-09', 'S9', '高杰', '330102199003089561', '18074218538'),
         ('A1785', 4, 'SC_DR05_2026-10-09', 'S9', '郭秀英', '440103199206125173', '18369147021'),
         ('A1786', 1, 'SC_DR05_2026-10-09', 'S10', '马磊', '320102199312270143', '18862075196'),
         ('A1787', 2, 'SC_DR05_2026-10-09', 'S10', '林娜', '440103196011135247', '18804691570'),
         ('A1788', 3, 'SC_DR05_2026-10-09', 'S10', '赵伟', '320102196009059544', '18308641975'),
         ('A1789', 4, 'SC_DR05_2026-10-09', 'S10', '林平', '110101199404250304', '15247935804'),
         ('A1790', 1, 'SC_DR05_2026-10-09', 'S11', '李静', '320102197512156960', '13246813574'),
         ('A1791', 2, 'SC_DR05_2026-10-09', 'S11', '吴娜', '330102198703060183', '18297531860'),
         ('A1792', 3, 'SC_DR05_2026-10-09', 'S11', '吴超', '110101197312261787', '17571368243'),
         ('A1793', 1, 'SC_DR05_2026-10-09', 'S12', '马丽', '110101199003070687', '18753164205'),
         ('A1794', 1, 'SC_DR05_2026-10-10', 'S1', '周敏', '320102197411266749', '17207519640'),
         ('A1795', 2, 'SC_DR05_2026-10-10', 'S1', '胡伟', '440305196512166272', '19814692571'),
         ('A1796', 1, 'SC_DR05_2026-10-10', 'S2', '林娜', '310104195407044141', '18804679350'),
         ('A1797', 2, 'SC_DR05_2026-10-10', 'S2', '陈伟', '330102195810088022', '17963107421'),
         ('A1798', 3, 'SC_DR05_2026-10-10', 'S2', '陈洋', '110105195007032415', '17368047915'),
         ('A1799', 4, 'SC_DR05_2026-10-10', 'S2', '周芳', '330102196711080724', '18186429753'),
         ('A1800', 1, 'SC_DR05_2026-10-10', 'S3', '胡磊', '330102198301039488', '18297518640'),
         ('A1801', 2, 'SC_DR05_2026-10-10', 'S3', '李丽', '440103200406146265', '19702481355'),
         ('A1802', 3, 'SC_DR05_2026-10-10', 'S3', '林勇', '32010219860306891X', '18074218538'),
         ('A1803', 4, 'SC_DR05_2026-10-10', 'S3', '高静', '440305200008176630', '19792480354'),
         ('A1804', 5, 'SC_DR05_2026-10-10', 'S3', '吴娜', '330102198204089280', '17520864193'),
         ('A1805', 1, 'SC_DR05_2026-10-10', 'S4', '徐涛', '11010519610704109X', '17914602571'),
         ('A1806', 1, 'SC_DR05_2026-10-10', 'S5', '吴静', '310101200308191933', '19207431860'),
         ('A1807', 2, 'SC_DR05_2026-10-10', 'S5', '徐明', '330102196708180839', '15581347023'),
         ('A1808', 1, 'SC_DR05_2026-10-10', 'S6', '王丽', '330102198404259635', '13803591460'),
         ('A1809', 2, 'SC_DR05_2026-10-10', 'S6', '杨芳', '310101200506142200', '19196408539'),
         ('A1810', 3, 'SC_DR05_2026-10-10', 'S6', '周军', '320102200406136282', '19368024791'),
         ('A1811', 4, 'SC_DR05_2026-10-10', 'S6', '赵芳', '110101197510062113', '19975386422'),
         ('A1812', 1, 'SC_DR05_2026-10-10', 'S7', '吴娜', '440103196011255230', '13429753082'),
         ('A1813', 2, 'SC_DR05_2026-10-10', 'S7', '郭芳', '310101195205272876', '18924681351'),
         ('A1814', 3, 'SC_DR05_2026-10-10', 'S7', '罗涛', '330102196009038489', '18317520645'),
         ('A1815', 4, 'SC_DR05_2026-10-10', 'S7', '郭秀英', '310101197812282784', '17147903689'),
         ('A1816', 5, 'SC_DR05_2026-10-10', 'S7', '胡强', '330102197901018707', '17207518640'),
         ('A1817', 1, 'SC_DR05_2026-10-10', 'S8', '郭芳', '440103199303074304', '18357924681'),
         ('A1818', 1, 'SC_DR05_2026-10-10', 'S9', '郭军', '440103199203194173', '13530842978'),
         ('A1819', 2, 'SC_DR05_2026-10-10', 'S9', '陈勇', '110101196412270280', '15571368243'),
         ('A1820', 1, 'SC_DR05_2026-10-10', 'S10', '胡磊', '440103197309217565', '17197508649'),
         ('A1821', 2, 'SC_DR05_2026-10-10', 'S10', '朱明', '110101196701289770', '15468057912'),
         ('A1822', 1, 'SC_DR05_2026-10-10', 'S11', '刘洋', '310101195706014744', '18258080795'),
         ('A1823', 1, 'SC_DR05_2026-10-10', 'S12', '胡洋', '33010219900102967X', '18418630752'),
         ('A1824', 1, 'SC_DR05_2026-10-12', 'S1', '胡磊', '440103195908195135', '13531842973'),
         ('A1825', 2, 'SC_DR05_2026-10-12', 'S1', '杨艳', '110101195512260755', '17024613578'),
         ('A1826', 3, 'SC_DR05_2026-10-12', 'S1', '赵娜', '310101195508183408', '13206431750'),
         ('A1827', 4, 'SC_DR05_2026-10-12', 'S1', '杨勇', '330102195710239014', '13581369243'),
         ('A1828', 1, 'SC_DR05_2026-10-12', 'S2', '张强', '310101200005271426', '17924681351'),
         ('A1829', 1, 'SC_DR05_2026-10-12', 'S3', '胡艳', '31010119620511133X', '19630852974'),
         ('A1830', 2, 'SC_DR05_2026-10-12', 'S3', '徐明', '330102198504259691', '13681479258'),
         ('A1831', 1, 'SC_DR05_2026-10-12', 'S4', '胡伟', '110101199005280653', '15359146025'),
         ('A1832', 2, 'SC_DR05_2026-10-12', 'S4', '周敏', '110105199805111124', '19185307428'),
         ('A1833', 1, 'SC_DR05_2026-10-12', 'S5', '孙敏', '330102198404099627', '18429753082'),
         ('A1834', 2, 'SC_DR05_2026-10-12', 'S5', '郭伟', '31010119520526282X', '18579246807'),
         ('A1835', 3, 'SC_DR05_2026-10-12', 'S5', '刘平', '11010519721109054X', '19206418534'),
         ('A1836', 1, 'SC_DR05_2026-10-12', 'S6', '赵军', '330102198504258656', '13791480259'),
         ('A1837', 1, 'SC_DR05_2026-10-12', 'S7', '黄芳', '440305196612285359', '15206431750'),
         ('A1838', 1, 'SC_DR05_2026-10-12', 'S8', '孙明', '110101196510210361', '15469135802'),
         ('A1839', 1, 'SC_DR05_2026-10-12', 'S9', '郭洋', '110101196506060313', '18864175300'),
         ('A1840', 2, 'SC_DR05_2026-10-12', 'S9', '赵军', '320102197302196606', '19914602571'),
         ('A1841', 1, 'SC_DR05_2026-10-12', 'S10', '罗涛', '440103199103194061', '13752964189'),
         ('A1842', 2, 'SC_DR05_2026-10-12', 'S10', '孙霞', '320102195309218178', '13692470354'),
         ('A1843', 1, 'SC_DR05_2026-10-12', 'S11', '张丽', '110101196209208801', '15680357924'),
         ('A1844', 2, 'SC_DR05_2026-10-12', 'S11', '朱丽', '440103198105246457', '19308641975'),
         ('A1845', 1, 'SC_DR05_2026-10-12', 'S12', '马静', '440103199203195272', '13975386421'),
         ('A1846', 1, 'SC_DR05_2026-10-13', 'S1', '刘强', '310101198712283231', '18792468135'),
         ('A1847', 1, 'SC_DR05_2026-10-13', 'S2', '吴娜', '330102196407010166', '18429730866'),
         ('A1848', 2, 'SC_DR05_2026-10-13', 'S2', '孙超', '110101199605260728', '17469158026'),
         ('A1849', 3, 'SC_DR05_2026-10-13', 'S2', '孙强', '320102196608039596', '18074218532'),
         ('A1850', 1, 'SC_DR05_2026-10-13', 'S3', '孙明', '110101197610222401', '17692458134'),
         ('A1851', 2, 'SC_DR05_2026-10-13', 'S3', '徐静', '110105199306140238', '18318542971'),
         ('A1852', 1, 'SC_DR05_2026-10-13', 'S4', '陈伟', '440305195007276599', '17529763087'),
         ('A1853', 1, 'SC_DR05_2026-10-13', 'S6', '罗军', '110101197512122239', '19420753186'),
         ('A1854', 2, 'SC_DR05_2026-10-13', 'S6', '胡平', '330102195708177854', '13479135802'),
         ('A1855', 1, 'SC_DR05_2026-10-13', 'S7', '孙霞', '310104199304085301', '18682479351'),
         ('A1856', 2, 'SC_DR05_2026-10-13', 'S7', '张明', '110101197710071516', '19085297412'),
         ('A1857', 1, 'SC_DR05_2026-10-13', 'S8', '孙丽', '310104196207164688', '15963185206'),
         ('A1858', 2, 'SC_DR05_2026-10-13', 'S8', '赵娟', '31010419590908520X', '18358146925'),
         ('A1859', 1, 'SC_DR05_2026-10-13', 'S9', '朱明', '440103196708065533', '19024791362'),
         ('A1860', 1, 'SC_DR05_2026-10-13', 'S11', '高杰', '330102196111098584', '18195320643'),
         ('A1861', 1, 'SC_DR05_2026-10-13', 'S12', '王丽', '440305200008176710', '19248035910'),
         ('A1862', 1, 'SC_DR05_2026-10-14', 'S1', '朱洋', '310101195712013780', '13317542861'),
         ('A1863', 2, 'SC_DR05_2026-10-14', 'S1', '赵娟', '11010519721125169X', '15248013790'),
         ('A1864', 1, 'SC_DR05_2026-10-14', 'S3', '陈霞', '110101199404101392', '19420853192'),
         ('A1865', 1, 'SC_DR05_2026-10-14', 'S4', '徐娟', '330102199101189857', '15913680251'),
         ('A1866', 1, 'SC_DR05_2026-10-14', 'S5', '吴静', '440305197409226673', '17752064195'),
         ('A1867', 1, 'SC_DR05_2026-10-14', 'S8', '罗敏', '440305195608187778', '13468057922'),
         ('A1868', 1, 'SC_DR05_2026-10-14', 'S9', '徐丽', '320102195809048179', '17318542965'),
         ('A1869', 1, 'SC_DR05_2026-10-14', 'S10', '胡磊', '31010119870318424X', '13642075318'),
         ('A1870', 1, 'SC_DR05_2026-10-15', 'S1', '张洋', '310101198101013195', '17804679356'),
         ('A1871', 1, 'SC_DR05_2026-10-15', 'S4', '刘明', '110105197310161788', '19753186429'),
         ('A1872', 2, 'SC_DR05_2026-10-15', 'S4', '陈洋', '110101197309210727', '17924681357'),
         ('A1873', 1, 'SC_DR05_2026-10-15', 'S5', '杨军', '310104198504094021', '18359146021'),
         ('A1874', 1, 'SC_DR05_2026-10-15', 'S6', '黄芳', '310104198905233563', '13539764087'),
         ('A1875', 1, 'SC_DR05_2026-10-15', 'S9', '周娟', '330102198201189235', '13258014794'),
         ('A1876', 1, 'SC_DR05_2026-10-15', 'S11', '高勇', '320102198111258987', '17975386427'),
         ('A1877', 1, 'SC_DR05_2026-10-15', 'S12', '刘磊', '110101199702210896', '17358024695'),
         ('A1878', 1, 'SC_DR05_2026-10-16', 'S1', '李涛', '440305197901028708', '17675308644'),
         ('A1879', 1, 'SC_DR05_2026-10-16', 'S2', '刘磊', '440305197601167140', '13469157026'),
         ('A1880', 1, 'SC_DR05_2026-10-16', 'S3', '杨芳', '440305196101034478', '15085219638'),
         ('A1881', 2, 'SC_DR05_2026-10-16', 'S3', '罗丽', '310101197612272389', '17358024790'),
         ('A1882', 1, 'SC_DR05_2026-10-16', 'S4', '李磊', '310101195706014760', '18804679350'),
         ('A1883', 1, 'SC_DR05_2026-10-16', 'S5', '郭洋', '110105200504093263', '19530841973'),
         ('A1884', 1, 'SC_DR05_2026-10-16', 'S6', '林伟', '440305197810117473', '13257914685'),
         ('A1885', 1, 'SC_DR05_2026-10-16', 'S10', '吴静', '440103196911255869', '15185329649'),
         ('A1886', 1, 'SC_DR05_2026-10-16', 'S11', '胡霞', '110105200407032194', '17024613572'),
         ('A1887', 1, 'SC_DR05_2026-10-17', 'S2', '郭艳', '310104198504224033', '13530864197'),
         ('A1888', 1, 'SC_DR05_2026-10-17', 'S3', '胡伟', '440305200008169860', '15247935800'),
         ('A1889', 1, 'SC_DR05_2026-10-17', 'S4', '郭军', '310104198903183646', '13752064199'),
         ('A1890', 1, 'SC_DR05_2026-10-17', 'S6', '朱强', '320102195207278030', '17863175200'),
         ('A1891', 2, 'SC_DR05_2026-10-17', 'S6', '赵军', '310101196612075276', '19024613572'),
         ('A1892', 1, 'SC_DR05_2026-10-17', 'S7', '朱平', '110101196810224108', '18814679356'),
         ('A1893', 1, 'SC_DR05_2026-10-17', 'S8', '何军', '320102197402046779', '17317542861'),
         ('A1894', 1, 'SC_DR05_2026-10-17', 'S10', '刘强', '330102195808188091', '13702469135'),
         ('A1895', 1, 'SC_DR05_2026-10-17', 'S11', '张霞', '320102195107276898', '17196408523'),
         ('A1896', 1, 'SC_DR05_2026-10-17', 'S12', '郭秀英', '310101197612262287', '17036892578'),
         ('A1897', 1, 'SC_DR05_2026-10-19', 'S1', '孙霞', '440103200106126748', '19026813798'),
         ('A1898', 1, 'SC_DR05_2026-10-19', 'S4', '赵伟', '440305195205238008', '17742063199'),
         ('A1899', 1, 'SC_DR05_2026-10-19', 'S5', '陈勇', '310101196612263832', '18137902689'),
         ('A1900', 1, 'SC_DR05_2026-10-19', 'S7', '郭芳', '110105198011242021', '17135702469'),
         ('A1901', 1, 'SC_DR05_2026-10-19', 'S8', '马丽', '31010119580920492X', '13197520869'),
         ('A1902', 1, 'SC_DR05_2026-10-19', 'S9', '陈勇', '440305198001188831', '13915702681'),
         ('A1903', 1, 'SC_DR05_2026-10-19', 'S11', '高军', '310104197604222356', '19086419752'),
         ('A1904', 1, 'SC_DR05_2026-10-19', 'S12', '朱霞', '320102196009208407', '13680279134'),
         ('A1905', 1, 'SC_DR05_2026-10-20', 'S1', '吴涛', '110105197801012728', '17026813798'),
         ('A1906', 1, 'SC_DR05_2026-10-20', 'S4', '黄平', '440103200504217573', '17853174200'),
         ('A1907', 1, 'SC_DR05_2026-10-20', 'S5', '周娟', '320102196207159810', '15036892578'),
         ('A1908', 1, 'SC_DR05_2026-10-20', 'S7', '王静', '110101197209200652', '15136802479'),
         ('A1909', 1, 'SC_DR05_2026-10-20', 'S8', '郭秀英', '330102199104090908', '18186429759'),
         ('A1910', 1, 'SC_DR05_2026-10-20', 'S9', '刘艳', '440305197701178402', '13469157026'),
         ('A1911', 1, 'SC_DR05_2026-10-20', 'S10', '赵娟', '320102196310219965', '15803591466'),
         ('A1912', 1, 'SC_DR05_2026-10-20', 'S11', '王杰', '440305195207288033', '17318642975'),
         ('A1913', 1, 'SC_DR06_2026-10-07', 'S1', '陈艳', '310101198003073143', '17251079240'),
         ('A1914', 2, 'SC_DR06_2026-10-07', 'S1', '张霞', '32010219520727702X', '17641853978'),
         ('A1915', 3, 'SC_DR06_2026-10-07', 'S1', '王敏', '11010120000322141X', '17914680351'),
         ('A1916', 4, 'SC_DR06_2026-10-07', 'S1', '何勇', '310104195307163979', '13975386417'),
         ('A1917', 1, 'SC_DR06_2026-10-07', 'S2', '孙丽', '310104198404212676', '13752086319'),
         ('A1918', 2, 'SC_DR06_2026-10-07', 'S2', '张磊', '330102198001178793', '13792568149'),
         ('A1919', 1, 'SC_DR06_2026-10-07', 'S3', '高娜', '440103199506144616', '18246835790'),
         ('A1920', 1, 'SC_DR06_2026-10-07', 'S4', '马静', '33010219570802898X', '17530842977'),
         ('A1921', 1, 'SC_DR06_2026-10-07', 'S5', '赵娟', '310101197608272300', '17036892578'),
         ('A1922', 2, 'SC_DR06_2026-10-07', 'S5', '朱磊', '310104196109214397', '15862097316'),
         ('A1923', 3, 'SC_DR06_2026-10-07', 'S5', '徐娟', '320102195809288156', '13246835799'),
         ('A1924', 4, 'SC_DR06_2026-10-07', 'S5', '高勇', '440305197001027099', '15086319748'),
         ('A1925', 1, 'SC_DR06_2026-10-07', 'S6', '朱磊', '320102195107276919', '17196408533'),
         ('A1926', 2, 'SC_DR06_2026-10-07', 'S6', '高静', '110105196901011023', '15804692576'),
         ('A1927', 1, 'SC_DR06_2026-10-07', 'S7', '赵军', '440103199604094843', '19802469135'),
         ('A1928', 1, 'SC_DR06_2026-10-07', 'S8', '赵芳', '110105199507151574', '19753186425'),
         ('A1929', 2, 'SC_DR06_2026-10-07', 'S8', '马明', '310104196307044771', '19246813574'),
         ('A1930', 1, 'SC_DR06_2026-10-07', 'S9', '徐明', '310101200108052592', '17026813792'),
         ('A1931', 1, 'SC_DR06_2026-10-07', 'S10', '高静', '320102195209211403', '15915703687'),
         ('A1932', 2, 'SC_DR06_2026-10-07', 'S10', '徐丽', '440305199805225284', '15074296312'),
         ('A1933', 1, 'SC_DR06_2026-10-07', 'S11', '吴秀英', '31010419890524465X', '13297530864'),
         ('A1934', 2, 'SC_DR06_2026-10-07', 'S11', '刘强', '310101198901013599', '18035792468'),
         ('A1935', 3, 'SC_DR06_2026-10-07', 'S11', '赵秀英', '310104195906144083', '13429731862'),
         ('A1936', 1, 'SC_DR06_2026-10-07', 'S12', '张丽', '11010119651227940X', '15469158022'),
         ('A1937', 2, 'SC_DR06_2026-10-07', 'S12', '刘明', '440103197109207194', '15197408639'),
         ('A1938', 3, 'SC_DR06_2026-10-07', 'S12', '何秀英', '440305195606128803', '13359124801'),
         ('A1939', 4, 'SC_DR06_2026-10-07', 'S12', '王涛', '310104199402164492', '15641853078'),
         ('A1940', 5, 'SC_DR06_2026-10-07', 'S12', '李丽', '110105199304240198', '15681357028'),
         ('A1941', 1, 'SC_DR06_2026-10-08', 'S1', '罗杰', '110101199106130865', '18531864200'),
         ('A1942', 1, 'SC_DR06_2026-10-08', 'S2', '张强', '110101199206019881', '15570268137'),
         ('A1943', 2, 'SC_DR06_2026-10-08', 'S2', '张超', '440103199604215924', '15742063199'),
         ('A1944', 1, 'SC_DR06_2026-10-08', 'S3', '胡艳', '320102197302046595', '17318642971'),
         ('A1945', 2, 'SC_DR06_2026-10-08', 'S3', '张磊', '440305195606128766', '13137902689'),
         ('A1946', 3, 'SC_DR06_2026-10-08', 'S3', '林洋', '440103197009207154', '15974286317'),
         ('A1947', 1, 'SC_DR06_2026-10-08', 'S4', '杨勇', '320102197311147646', '19358081795'),
         ('A1948', 2, 'SC_DR06_2026-10-08', 'S4', '杨伟', '440103199005243851', '13429753080'),
         ('A1949', 3, 'SC_DR06_2026-10-08', 'S4', '刘强', '440305197612167082', '13802591360'),
         ('A1950', 4, 'SC_DR06_2026-10-08', 'S4', '孙敏', '310101199104205074', '13964208531'),
         ('A1951', 1, 'SC_DR06_2026-10-08', 'S5', '刘超', '440305196610226371', '15642053194'),
         ('A1952', 1, 'SC_DR06_2026-10-08', 'S6', '孙涛', '310104195107022653', '17135702463'),
         ('A1953', 1, 'SC_DR06_2026-10-08', 'S7', '张霞', '310104195106152579', '13752964185'),
         ('A1954', 2, 'SC_DR06_2026-10-08', 'S7', '杨军', '110101199206010932', '15793580469'),
         ('A1955', 1, 'SC_DR06_2026-10-08', 'S8', '张洋', '31010119760305243X', '17026814798'),
         ('A1956', 2, 'SC_DR06_2026-10-08', 'S8', '胡艳', '320102200406256313', '17185307423'),
         ('A1957', 3, 'SC_DR06_2026-10-08', 'S8', '马超', '110101199602200703', '15792435799'),
         ('A1958', 1, 'SC_DR06_2026-10-08', 'S9', '王娟', '110101196412110199', '18853196420'),
         ('A1959', 2, 'SC_DR06_2026-10-08', 'S9', '李丽', '330102196407169134', '15791358024'),
         ('A1960', 3, 'SC_DR06_2026-10-08', 'S9', '吴静', '310104196512185194', '15185307429'),
         ('A1961', 4, 'SC_DR06_2026-10-08', 'S9', '周娟', '110101198203139189', '13247013697'),
         ('A1962', 1, 'SC_DR06_2026-10-08', 'S10', '王超', '320102197302046501', '17195320649'),
         ('A1963', 1, 'SC_DR06_2026-10-08', 'S11', '李丽', '110101198605268944', '15802491360'),
         ('A1964', 2, 'SC_DR06_2026-10-08', 'S11', '马丽', '110101196610060532', '18208619755'),
         ('A1965', 3, 'SC_DR06_2026-10-08', 'S11', '朱平', '320102198412149506', '13792568142'),
         ('A1966', 1, 'SC_DR06_2026-10-08', 'S12', '王杰', '31010120040819308X', '19208641970'),
         ('A1967', 2, 'SC_DR06_2026-10-08', 'S12', '赵军', '440305197810117449', '13802579140'),
         ('A1968', 1, 'SC_DR06_2026-10-09', 'S1', '陈洋', '330102196911249985', '15246935700'),
         ('A1969', 2, 'SC_DR06_2026-10-09', 'S1', '徐敏', '310101200406143193', '19642953184'),
         ('A1970', 3, 'SC_DR06_2026-10-09', 'S1', '黄杰', '110101196610220540', '15792468135'),
         ('A1971', 1, 'SC_DR06_2026-10-09', 'S2', '张涛', '330102197011101277', '18196420753'),
         ('A1972', 2, 'SC_DR06_2026-10-09', 'S2', '王静', '33010219580418806X', '13257913680'),
         ('A1973', 1, 'SC_DR06_2026-10-09', 'S3', '吴超', '11010519810102321X', '17681379244'),
         ('A1974', 1, 'SC_DR06_2026-10-09', 'S4', '吴静', '440103200103195828', '15862075190'),
         ('A1975', 2, 'SC_DR06_2026-10-09', 'S4', '马平', '110101197512282259', '17247035810'),
         ('A1976', 3, 'SC_DR06_2026-10-09', 'S4', '杨平', '440305197512288004', '17530864193'),
         ('A1977', 4, 'SC_DR06_2026-10-09', 'S4', '孙涛', '110105197302030729', '17680979241'),
         ('A1978', 1, 'SC_DR06_2026-10-09', 'S5', '吴娟', '320102196207158818', '15469135802'),
         ('A1979', 2, 'SC_DR06_2026-10-09', 'S5', '林洋', '11010119621110987X', '18420853196'),
         ('A1980', 1, 'SC_DR06_2026-10-09', 'S6', '王娟', '310101198901134673', '13207519647'),
         ('A1981', 2, 'SC_DR06_2026-10-09', 'S6', '何芳', '320102196502205226', '19579168027'),
         ('A1982', 1, 'SC_DR06_2026-10-09', 'S7', '张洋', '440103200203076914', '19803679246'),
         ('A1983', 1, 'SC_DR06_2026-10-09', 'S8', '张霞', '310101195608193582', '13196430759'),
         ('A1984', 1, 'SC_DR06_2026-10-09', 'S9', '黄勇', '440305197312156648', '19468057926'),
         ('A1985', 2, 'SC_DR06_2026-10-09', 'S9', '陈明', '310104199702176081', '15196408533'),
         ('A1986', 3, 'SC_DR06_2026-10-09', 'S9', '周涛', '44030519711112720X', '19571346027'),
         ('A1987', 4, 'SC_DR06_2026-10-09', 'S9', '周敏', '310104195207162901', '13317520641'),
         ('A1988', 1, 'SC_DR06_2026-10-09', 'S10', '周军', '310101198512272853', '18681357024'),
         ('A1989', 1, 'SC_DR06_2026-10-09', 'S11', '周秀英', '330102196808039875', '18084297312'),
         ('A1990', 2, 'SC_DR06_2026-10-09', 'S11', '杨勇', '310104199805116305', '19469257032'),
         ('A1991', 1, 'SC_DR06_2026-10-09', 'S12', '林芳', '330102196808180967', '15025891468'),
         ('A1992', 2, 'SC_DR06_2026-10-09', 'S12', '赵秀英', '110101200404108792', '19530864193'),
         ('A1993', 3, 'SC_DR06_2026-10-09', 'S12', '王敏', '310101197703051565', '17135724699'),
         ('A1994', 4, 'SC_DR06_2026-10-09', 'S12', '胡强', '320102198001038844', '17318642971'),
         ('A1995', 1, 'SC_DR06_2026-10-10', 'S1', '林娜', '310104199705106062', '19570368243'),
         ('A1996', 1, 'SC_DR06_2026-10-10', 'S2', '周秀英', '440305195408017352', '17741985209'),
         ('A1997', 1, 'SC_DR06_2026-10-10', 'S3', '周杰', '330102196510229289', '15135824699'),
         ('A1998', 2, 'SC_DR06_2026-10-10', 'S3', '李娟', '110105199604091657', '19419730861'),
         ('A1999', 3, 'SC_DR06_2026-10-10', 'S3', '李磊', '330102195507168687', '13914780367'),
         ('A2000', 1, 'SC_DR06_2026-10-10', 'S4', '马静', '330102196808030918', '18308629755'),
         ('A2001', 2, 'SC_DR06_2026-10-10', 'S4', '林平', '110101200006281477', '17358046915'),
         ('A2002', 1, 'SC_DR06_2026-10-10', 'S5', '胡芳', '110105198111243152', '17814646323'),
         ('A2003', 1, 'SC_DR06_2026-10-10', 'S6', '刘平', '320102196107278599', '18630852978'),
         ('A2004', 2, 'SC_DR06_2026-10-10', 'S6', '赵杰', '310101199104085033', '18814692576'),
         ('A2005', 3, 'SC_DR06_2026-10-10', 'S6', '孙敏', '110101199905122263', '19308641970'),
         ('A2006', 1, 'SC_DR06_2026-10-10', 'S7', '黄勇', '440305195305117254', '13680357924'),
         ('A2007', 2, 'SC_DR06_2026-10-10', 'S7', '黄平', '440103199106255042', '13753086419'),
         ('A2008', 1, 'SC_DR06_2026-10-10', 'S8', '张超', '440103197212277510', '17531208533'),
         ('A2009', 1, 'SC_DR06_2026-10-10', 'S10', '何秀英', '110105198001023060', '17036824798'),
         ('A2010', 2, 'SC_DR06_2026-10-10', 'S10', '朱洋', '440305195004226625', '17862075190'),
         ('A2011', 1, 'SC_DR06_2026-10-10', 'S11', '徐秀英', '330102196911091137', '18631975208'),
         ('A2012', 2, 'SC_DR06_2026-10-10', 'S11', '周军', '330102195708177918', '13792468035'),
         ('A2013', 3, 'SC_DR06_2026-10-10', 'S11', '罗娟', '110105199504090569', '19203185207'),
         ('A2014', 1, 'SC_DR06_2026-10-10', 'S12', '杨艳', '330102196811249830', '15791380245'),
         ('A2015', 1, 'SC_DR06_2026-10-12', 'S1', '郭芳', '110105200304241954', '17570246917'),
         ('A2016', 1, 'SC_DR06_2026-10-12', 'S3', '周娟', '310101195405284265', '18570236917'),
         ('A2017', 2, 'SC_DR06_2026-10-12', 'S3', '胡艳', '110101195712121100', '19185329643'),
         ('A2018', 1, 'SC_DR06_2026-10-12', 'S4', '黄娜', '330102198703075887', '15196420759'),
         ('A2019', 1, 'SC_DR06_2026-10-12', 'S5', '陈洋', '110105200507032212', '17035714683'),
         ('A2020', 1, 'SC_DR06_2026-10-12', 'S6', '李娟', '440305197601018209', '17974208537'),
         ('A2021', 2, 'SC_DR06_2026-10-12', 'S6', '朱明', '440305196409094987', '19913680241'),
         ('A2022', 1, 'SC_DR06_2026-10-12', 'S7', '徐秀英', '320102198502219707', '13915702681'),
         ('A2023', 1, 'SC_DR06_2026-10-12', 'S8', '朱洋', '110101197710071399', '19862075190'),
         ('A2024', 1, 'SC_DR06_2026-10-12', 'S10', '黄艳', '320102198202208264', '13802491350'),
         ('A2025', 1, 'SC_DR06_2026-10-12', 'S11', '杨芳', '330102199204099926', '18863097426'),
         ('A2026', 1, 'SC_DR06_2026-10-12', 'S12', '周娟', '31010419641010607X', '19358146925'),
         ('A2027', 2, 'SC_DR06_2026-10-12', 'S12', '陈伟', '330102199001029637', '18752064185'),
         ('A2028', 1, 'SC_DR06_2026-10-13', 'S1', '马丽', '440305195405238344', '17531942088'),
         ('A2029', 2, 'SC_DR06_2026-10-13', 'S1', '林伟', '110105200407022164', '17813592460'),
         ('A2030', 1, 'SC_DR06_2026-10-13', 'S3', '周秀英', '11010519660811949X', '18863175200'),
         ('A2031', 1, 'SC_DR06_2026-10-13', 'S4', '周娟', '440103200106136882', '19682479354'),
         ('A2032', 1, 'SC_DR06_2026-10-13', 'S5', '李磊', '310101199104204944', '13197520863'),
         ('A2033', 2, 'SC_DR06_2026-10-13', 'S5', '罗秀英', '310101197812281730', '17357924681'),
         ('A2034', 1, 'SC_DR06_2026-10-13', 'S7', '杨芳', '440305195207017006', '17530864197'),
         ('A2035', 1, 'SC_DR06_2026-10-13', 'S8', '张洋', '310104196207035632', '18804679350'),
         ('A2036', 2, 'SC_DR06_2026-10-13', 'S8', '吴敏', '330102196410079201', '18429753086'),
         ('A2037', 1, 'SC_DR06_2026-10-13', 'S10', '杨芳', '440305197810247438', '17640853974'),
         ('A2038', 1, 'SC_DR06_2026-10-13', 'S11', '高娜', '110101199502207246', '13024691352'),
         ('A2039', 1, 'SC_DR06_2026-10-14', 'S1', '朱平', '440305196910126946', '19247013684'),
         ('A2040', 1, 'SC_DR06_2026-10-14', 'S3', '黄勇', '320102197111136248', '19035792463'),
         ('A2041', 1, 'SC_DR06_2026-10-14', 'S5', '陈勇', '320102197602218125', '13570268137'),
         ('A2042', 1, 'SC_DR06_2026-10-14', 'S6', '郭勇', '310104195410233242', '13529763082'),
         ('A2043', 1, 'SC_DR06_2026-10-14', 'S10', '徐明', '440103200003066586', '19581347023'),
         ('A2044', 1, 'SC_DR06_2026-10-14', 'S11', '周娜', '310101198712124345', '13308629755'),
         ('A2045', 1, 'SC_DR06_2026-10-15', 'S1', '王涛', '440305200308026079', '15752986309'),
         ('A2046', 1, 'SC_DR06_2026-10-15', 'S5', '张明', '44030519980522517X', '15963185201'),
         ('A2047', 1, 'SC_DR06_2026-10-15', 'S8', '张强', '310101200408072106', '17247936804'),
         ('A2048', 1, 'SC_DR06_2026-10-15', 'S12', '吴敏', '310101200008171420', '19974108527'),
         ('A2049', 1, 'SC_DR06_2026-10-16', 'S1', '李丽', '320102197302196497', '19914602571'),
         ('A2050', 1, 'SC_DR06_2026-10-16', 'S5', '郭芳', '110101198802219260', '15579146807'),
         ('A2051', 1, 'SC_DR06_2026-10-16', 'S6', '周芳', '310101200306132980', '19086497538'),
         ('A2052', 1, 'SC_DR06_2026-10-16', 'S8', '周秀英', '330102196111098576', '18640875198'),
         ('A2053', 1, 'SC_DR06_2026-10-16', 'S10', '张丽', '320102198712169023', '15357924685'),
         ('A2054', 1, 'SC_DR06_2026-10-17', 'S1', '孙敏', '330102196011099571', '18297530864'),
         ('A2055', 1, 'SC_DR06_2026-10-17', 'S2', '周军', '44010319910612400X', '18802491356'),
         ('A2056', 1, 'SC_DR06_2026-10-17', 'S4', '吴超', '110105197311251822', '17681457034'),
         ('A2057', 1, 'SC_DR06_2026-10-17', 'S5', '刘超', '320102195107277962', '17075396422'),
         ('A2058', 1, 'SC_DR06_2026-10-17', 'S8', '马平', '110101198905270413', '15258036914'),
         ('A2059', 1, 'SC_DR06_2026-10-17', 'S9', '刘明', '11010519920614109X', '18642975304'),
         ('A2060', 1, 'SC_DR06_2026-10-17', 'S11', '罗敏', '440305200507156562', '19146825799'),
         ('A2061', 1, 'SC_DR06_2026-10-17', 'S12', '朱丽', '110105198302163542', '13319742085'),
         ('A2062', 1, 'SC_DR06_2026-10-18', 'S1', '陈艳', '110105199707031948', '17329147025'),
         ('A2063', 1, 'SC_DR06_2026-10-18', 'S2', '陈伟', '440103195710243728', '13852096315'),
         ('A2064', 1, 'SC_DR06_2026-10-18', 'S4', '高军', '110105199604101798', '19753164205'),
         ('A2065', 1, 'SC_DR06_2026-10-18', 'S5', '黄军', '44030519651010625X', '19803579240'),
         ('A2066', 1, 'SC_DR06_2026-10-18', 'S10', '张磊', '440103196911136915', '19792480369'),
         ('A2067', 1, 'SC_DR06_2026-10-18', 'S11', '黄平', '310104196109215402', '15742085315'),
         ('A2068', 1, 'SC_DR06_2026-10-19', 'S2', '高静', '110105199504241566', '15469135806'),
         ('A2069', 1, 'SC_DR06_2026-10-19', 'S3', '孙敏', '310104197007153831', '13319720861'),
         ('A2070', 1, 'SC_DR06_2026-10-19', 'S6', '何秀英', '310104195309093986', '18915703681'),
         ('A2071', 1, 'SC_DR06_2026-10-19', 'S7', '李涛', '320102197502057942', '17318642071'),
         ('A2072', 1, 'SC_DR06_2026-10-19', 'S11', '马平', '310101195806014928', '18581347027'),
         ('A2073', 1, 'SC_DR06_2026-10-19', 'S12', '罗涛', '440305196111254458', '15863175296'),
         ('A2074', 1, 'SC_DR06_2026-10-20', 'S1', '胡艳', '310104195507173354', '13752064195'),
         ('A2075', 1, 'SC_DR06_2026-10-20', 'S4', '郭芳', '330102197903227705', '13468157026'),
         ('A2076', 1, 'SC_DR06_2026-10-20', 'S7', '林磊', '110105199707161849', '19208531960'),
         ('A2077', 1, 'SC_DR06_2026-10-20', 'S8', '张强', '330102195507167641', '13802479135'),
         ('A2078', 1, 'SC_DR06_2026-10-20', 'S10', '孙敏', '330102199001020667', '18197408539'),
         ('A2079', 1, 'SC_DR06_2026-10-20', 'S11', '朱平', '44030519741010784X', '13248013694'),
         ('A2080', 1, 'SC_DR07_2026-10-07', 'S1', '赵伟', '110101198502049781', '18308619750'),
         ('A2081', 2, 'SC_DR07_2026-10-07', 'S1', '李静', '310104199204174147', '18024713588'),
         ('A2082', 1, 'SC_DR07_2026-10-07', 'S2', '朱霞', '110101195103219428', '15136802573'),
         ('A2083', 2, 'SC_DR07_2026-10-07', 'S2', '周娜', '310104196310235907', '15863197526'),
         ('A2084', 3, 'SC_DR07_2026-10-07', 'S2', '林娜', '330102196410220164', '15570368143'),
         ('A2085', 4, 'SC_DR07_2026-10-07', 'S2', '张明', '440305196901025852', '15085329648'),
         ('A2086', 1, 'SC_DR07_2026-10-07', 'S3', '马强', '310104195106152608', '13752064195'),
         ('A2087', 2, 'SC_DR07_2026-10-07', 'S3', '罗丽', '310101200509073300', '17469157026'),
         ('A2088', 3, 'SC_DR07_2026-10-07', 'S3', '高勇', '310101198703184338', '13641975208'),
         ('A2089', 4, 'SC_DR07_2026-10-07', 'S3', '徐娟', '440103197212146342', '19579268137'),
         ('A2090', 5, 'SC_DR07_2026-10-07', 'S3', '马磊', '310104200405036387', '17539764087'),
         ('A2091', 6, 'SC_DR07_2026-10-07', 'S3', '马霞', '440305196910116908', '19025791462'),
         ('A2092', 1, 'SC_DR07_2026-10-07', 'S4', '高静', '310104195610114571', '18571369247'),
         ('A2093', 2, 'SC_DR07_2026-10-07', 'S4', '朱磊', '440305196409225043', '15307529641'),
         ('A2094', 3, 'SC_DR07_2026-10-07', 'S4', '黄勇', '310101198001012072', '17791368025'),
         ('A2095', 4, 'SC_DR07_2026-10-07', 'S4', '何勇', '440103200103196740', '15642953188'),
         ('A2096', 5, 'SC_DR07_2026-10-07', 'S4', '陈勇', '330102198101179021', '13147903684'),
         ('A2097', 6, 'SC_DR07_2026-10-07', 'S4', '朱洋', '310104198504222900', '13236464187'),
         ('A2098', 7, 'SC_DR07_2026-10-07', 'S4', '王静', '440305197701177290', '13791380249'),
         ('A2099', 8, 'SC_DR07_2026-10-07', 'S4', '高勇', '310101200408193135', '19319752081'),
         ('A2100', 1, 'SC_DR07_2026-10-07', 'S5', '周娜', '320102199102040905', '17208631970'),
         ('A2101', 2, 'SC_DR07_2026-10-07', 'S5', '吴杰', '310104196107034413', '18802479130'),
         ('A2102', 1, 'SC_DR07_2026-10-07', 'S6', '郭芳', '310101200509072252', '17579168037'),
         ('A2103', 2, 'SC_DR07_2026-10-07', 'S6', '杨霞', '440103199604215959', '15419730866'),
         ('A2104', 3, 'SC_DR07_2026-10-07', 'S6', '孙霞', '110101199602201650', '15469235806'),
         ('A2105', 1, 'SC_DR07_2026-10-07', 'S7', '刘平', '110101199006139694', '18530764193'),
         ('A2106', 2, 'SC_DR07_2026-10-07', 'S7', '吴涛', '310101198612274194', '18914780367'),
         ('A2107', 3, 'SC_DR07_2026-10-07', 'S7', '陈明', '330102198812010257', '18186407539'),
         ('A2108', 4, 'SC_DR07_2026-10-07', 'S7', '周杰', '440305196910125900', '19681357028'),
         ('A2109', 5, 'SC_DR07_2026-10-07', 'S7', '赵秀英', '330102197009040209', '18751964089'),
         ('A2110', 1, 'SC_DR07_2026-10-07', 'S8', '罗丽', '440305200206127020', '19469235812'),
         ('A2111', 2, 'SC_DR07_2026-10-07', 'S8', '孙强', '330102198703069110', '18196420759'),
         ('A2112', 3, 'SC_DR07_2026-10-07', 'S8', '何娜', '440103198707146461', '19914602577'),
         ('A2113', 4, 'SC_DR07_2026-10-07', 'S8', '杨霞', '330102198304099486', '18642075314'),
         ('A2114', 5, 'SC_DR07_2026-10-07', 'S8', '胡芳', '310104198304083563', '17814692576'),
         ('A2115', 6, 'SC_DR07_2026-10-07', 'S8', '张霞', '310104198402152729', '13196408533'),
         ('A2116', 1, 'SC_DR07_2026-10-07', 'S9', '王杰', '110101196810070962', '18086397522'),
         ('A2117', 1, 'SC_DR07_2026-10-07', 'S10', '胡洋', '320102195107276900', '17196408523'),
         ('A2118', 1, 'SC_DR07_2026-10-07', 'S11', '胡霞', '320102195207157044', '13580246913'),
         ('A2119', 2, 'SC_DR07_2026-10-07', 'S11', '黄伟', '110101197612132362', '19864197520'),
         ('A2120', 3, 'SC_DR07_2026-10-07', 'S11', '胡芳', '320102197502218056', '13469157026'),
         ('A2121', 4, 'SC_DR07_2026-10-07', 'S11', '马强', '110105197302160830', '19074218532'),
         ('A2122', 5, 'SC_DR07_2026-10-07', 'S11', '胡平', '310101195412143110', '18802491350'),
         ('A2123', 6, 'SC_DR07_2026-10-07', 'S11', '高军', '110101197710072551', '19753064299'),
         ('A2124', 1, 'SC_DR07_2026-10-07', 'S12', '黄平', '110105196910081189', '18308629755'),
         ('A2125', 2, 'SC_DR07_2026-10-07', 'S12', '黄艳', '440305198801189269', '15680379148'),
         ('A2126', 3, 'SC_DR07_2026-10-07', 'S12', '徐丽', '440103200306266040', '15307545868'),
         ('A2127', 1, 'SC_DR07_2026-10-08', 'S1', '王强', '440103196209085628', '18914680351'),
         ('A2128', 2, 'SC_DR07_2026-10-08', 'S1', '胡洋', '110101196412119193', '18539764087'),
         ('A2129', 3, 'SC_DR07_2026-10-08', 'S1', '刘强', '310104196310104747', '19024613572'),
         ('A2130', 1, 'SC_DR07_2026-10-08', 'S2', '杨芳', '440103198209218119', '17085397428'),
         ('A2131', 1, 'SC_DR07_2026-10-08', 'S3', '胡霞', '440305196409094936', '19469135706'),
         ('A2132', 2, 'SC_DR07_2026-10-08', 'S3', '张涛', '440305197612018140', '17420753182'),
         ('A2133', 3, 'SC_DR07_2026-10-08', 'S3', '郭娜', '110101197601282402', '17803691476'),
         ('A2134', 4, 'SC_DR07_2026-10-08', 'S3', '张明', '330102200004088099', '17318642971'),
         ('A2135', 5, 'SC_DR07_2026-10-08', 'S3', '胡平', '110105197402030873', '17247935800'),
         ('A2136', 6, 'SC_DR07_2026-10-08', 'S3', '郭洋', '110101199702061931', '19208519740'),
         ('A2137', 7, 'SC_DR07_2026-10-08', 'S3', '吴超', '330102196407160260', '15137902689'),
         ('A2138', 1, 'SC_DR07_2026-10-08', 'S4', '周娜', '310101200408193143', '19864207533'),
         ('A2139', 2, 'SC_DR07_2026-10-08', 'S4', '张强', '440305197309096656', '19468135796'),
         ('A2140', 3, 'SC_DR07_2026-10-08', 'S4', '黄芳', '320102200406256380', '17318620756'),
         ('A2141', 4, 'SC_DR07_2026-10-08', 'S4', '刘洋', '110101196710220687', '15358024791'),
         ('A2142', 5, 'SC_DR07_2026-10-08', 'S4', '胡强', '310101200506143334', '13531942083'),
         ('A2143', 6, 'SC_DR07_2026-10-08', 'S4', '李静', '330102196911250126', '15136824799'),
         ('A2144', 1, 'SC_DR07_2026-10-08', 'S5', '高静', '440305196801176813', '19147935804'),
         ('A2145', 2, 'SC_DR07_2026-10-08', 'S5', '朱磊', '320102197712287287', '17630842973'),
         ('A2146', 3, 'SC_DR07_2026-10-08', 'S5', '赵勇', '440103199304074314', '18024691357'),
         ('A2147', 4, 'SC_DR07_2026-10-08', 'S5', '何勇', '320102195706258982', '17208619754'),
         ('A2148', 1, 'SC_DR07_2026-10-08', 'S6', '刘平', '310101200308191933', '19863097416'),
         ('A2149', 2, 'SC_DR07_2026-10-08', 'S6', '吴涛', '440103199903066439', '19571346023'),
         ('A2150', 1, 'SC_DR07_2026-10-08', 'S7', '何芳', '440103196111134495', '18802491350'),
         ('A2151', 1, 'SC_DR07_2026-10-08', 'S8', '王杰', '440305199905236474', '15642053198'),
         ('A2152', 2, 'SC_DR07_2026-10-08', 'S8', '王静', '110105199506020441', '15579268037'),
         ('A2153', 3, 'SC_DR07_2026-10-08', 'S8', '王超', '320102200110065737', '15428653976'),
         ('A2154', 1, 'SC_DR07_2026-10-08', 'S9', '罗丽', '33010219590818926X', '13792568145'),
         ('A2155', 2, 'SC_DR07_2026-10-08', 'S9', '马强', '110101200006131356', '19852096312'),
         ('A2156', 1, 'SC_DR07_2026-10-08', 'S10', '高敏', '330102196508170337', '15025891478'),
         ('A2157', 2, 'SC_DR07_2026-10-08', 'S10', '刘平', '330102198204088165', '17741985205'),
         ('A2158', 1, 'SC_DR07_2026-10-08', 'S11', '郭洋', '440305195205238091', '17753064299'),
         ('A2159', 2, 'SC_DR07_2026-10-08', 'S11', '高秀英', '320102198502218640', '13802491350'),
         ('A2160', 3, 'SC_DR07_2026-10-08', 'S11', '高娟', '330102195510077524', '17317542965'),
         ('A2161', 1, 'SC_DR07_2026-10-08', 'S12', '何芳', '110101197510221161', '17135792468'),
         ('A2162', 2, 'SC_DR07_2026-10-08', 'S12', '吴秀英', '310101197502172221', '19297530864'),
         ('A2163', 3, 'SC_DR07_2026-10-08', 'S12', '黄杰', '110105200511033349', '17804691570'),
         ('A2164', 4, 'SC_DR07_2026-10-08', 'S12', '徐丽', '110101197312110698', '19318542965'),
         ('A2165', 5, 'SC_DR07_2026-10-08', 'S12', '黄艳', '440103195811123928', '18791380249'),
         ('A2166', 6, 'SC_DR07_2026-10-08', 'S12', '杨平', '440103199604215836', '15319720855'),
         ('A2167', 1, 'SC_DR07_2026-10-09', 'S1', '胡洋', '440103195807278038', '17185329643'),
         ('A2168', 2, 'SC_DR07_2026-10-09', 'S1', '胡伟', '110105199304231208', '15470236917'),
         ('A2169', 3, 'SC_DR07_2026-10-09', 'S1', '王娟', '320102196207279767', '18864275310'),
         ('A2170', 4, 'SC_DR07_2026-10-09', 'S1', '郭伟', '440103199203074243', '18691358024'),
         ('A2171', 5, 'SC_DR07_2026-10-09', 'S1', '胡洋', '320102197512276890', '17529741862'),
         ('A2172', 1, 'SC_DR07_2026-10-09', 'S2', '胡芳', '110105197502042169', '17703591465'),
         ('A2173', 1, 'SC_DR07_2026-10-09', 'S3', '杨平', '440103199306265413', '15085319642'),
         ('A2174', 2, 'SC_DR07_2026-10-09', 'S3', '罗敏', '440305195506127627', '13913580247'),
         ('A2175', 1, 'SC_DR07_2026-10-09', 'S4', '郭伟', '440103199103063985', '18924681357'),
         ('A2176', 2, 'SC_DR07_2026-10-09', 'S4', '吴娜', '310104199705236043', '15208631974'),
         ('A2177', 3, 'SC_DR07_2026-10-09', 'S4', '徐超', '44010319581112500X', '18473291470'),
         ('A2178', 1, 'SC_DR07_2026-10-09', 'S5', '吴静', '440103199003183859', '13530842978'),
         ('A2179', 2, 'SC_DR07_2026-10-09', 'S5', '何敏', '440305200008179970', '19571368240'),
         ('A2180', 3, 'SC_DR07_2026-10-09', 'S5', '林磊', '310101200108182629', '19742086315'),
         ('A2181', 4, 'SC_DR07_2026-10-09', 'S5', '高娜', '32010219600920844X', '13680379144'),
         ('A2182', 1, 'SC_DR07_2026-10-09', 'S6', '黄军', '110105196910231052', '15248013790'),
         ('A2183', 2, 'SC_DR07_2026-10-09', 'S6', '郭勇', '310104196610245242', '15974218537'),
         ('A2184', 3, 'SC_DR07_2026-10-09', 'S6', '林平', '330102196510229326', '15792481355'),
         ('A2185', 4, 'SC_DR07_2026-10-09', 'S6', '高军', '310104195009203506', '13530864193'),
         ('A2186', 5, 'SC_DR07_2026-10-09', 'S6', '李强', '110101196801280853', '15359146021'),
         ('A2187', 6, 'SC_DR07_2026-10-09', 'S6', '吴敏', '320102195006266746', '17428631756'),
         ('A2188', 1, 'SC_DR07_2026-10-09', 'S7', '周芳', '320102195207278129', '17742063199'),
         ('A2189', 1, 'SC_DR07_2026-10-09', 'S8', '徐娟', '110105199707030785', '17680379148'),
         ('A2190', 2, 'SC_DR07_2026-10-09', 'S8', '胡磊', '44010319940420565X', '15186407533'),
         ('A2191', 3, 'SC_DR07_2026-10-09', 'S8', '李强', '310101195606011343', '15814670350'),
         ('A2192', 4, 'SC_DR07_2026-10-09', 'S8', '赵秀英', '110101197602047041', '17530742963'),
         ('A2193', 1, 'SC_DR07_2026-10-09', 'S9', '张霞', '330102198304098344', '18973108427'),
         ('A2194', 2, 'SC_DR07_2026-10-09', 'S9', '刘艳', '330102196608170510', '15248013790'),
         ('A2195', 3, 'SC_DR07_2026-10-09', 'S9', '王强', '330102199201031010', '18753164205'),
         ('A2196', 4, 'SC_DR07_2026-10-09', 'S9', '李静', '440305196510105185', '19570246917'),
         ('A2197', 5, 'SC_DR07_2026-10-09', 'S9', '朱磊', '44010320040420621X', '15074286312'),
         ('A2198', 1, 'SC_DR07_2026-10-09', 'S10', '李娟', '330102198304099443', '18531964203'),
         ('A2199', 2, 'SC_DR07_2026-10-09', 'S10', '黄艳', '440103196909075914', '19024691352'),
         ('A2200', 1, 'SC_DR07_2026-10-09', 'S11', '陈艳', '110101195109273732', '17804691570'),
         ('A2201', 1, 'SC_DR07_2026-10-09', 'S12', '郭勇', '440305196512285175', '15751986205'),
         ('A2202', 1, 'SC_DR07_2026-10-10', 'S1', '马丽', '310104198502163927', '13308629755'),
         ('A2203', 2, 'SC_DR07_2026-10-10', 'S1', '马明', '110101198504258747', '15681379248'),
         ('A2204', 3, 'SC_DR07_2026-10-10', 'S1', '何军', '320102196209068787', '18640875198'),
         ('A2205', 4, 'SC_DR07_2026-10-10', 'S1', '朱伟', '110101199404251446', '15803591460'),
         ('A2206', 5, 'SC_DR07_2026-10-10', 'S1', '郭洋', '110101196508110329', '18197420853'),
         ('A2207', 1, 'SC_DR07_2026-10-10', 'S2', '王静', '110101196810229785', '15913580247'),
         ('A2208', 1, 'SC_DR07_2026-10-10', 'S3', '胡洋', '110101196710079652', '18196408534'),
         ('A2209', 2, 'SC_DR07_2026-10-10', 'S3', '张磊', '440103199507145776', '19137924809'),
         ('A2210', 1, 'SC_DR07_2026-10-10', 'S4', '罗静', '320102195109207968', '13469157021'),
         ('A2211', 2, 'SC_DR07_2026-10-10', 'S4', '孙丽', '310101197901131849', '19428631756'),
         ('A2212', 3, 'SC_DR07_2026-10-10', 'S4', '刘磊', '440305197810117406', '13791468039'),
         ('A2213', 4, 'SC_DR07_2026-10-10', 'S4', '罗军', '110105199805102076', '19752064195'),
         ('A2214', 5, 'SC_DR07_2026-10-10', 'S4', '周娟', '440305199704096145', '19692458134'),
         ('A2215', 1, 'SC_DR07_2026-10-10', 'S5', '徐秀英', '110105197001141214', '18641975208'),
         ('A2216', 1, 'SC_DR07_2026-10-10', 'S6', '张强', '440305200208185961', '19913502466'),
         ('A2217', 2, 'SC_DR07_2026-10-10', 'S6', '陈霞', '440103197009207023', '15964285317'),
         ('A2218', 1, 'SC_DR07_2026-10-10', 'S7', '马强', '440103199005243835', '13084219532'),
         ('A2219', 2, 'SC_DR07_2026-10-10', 'S7', '高静', '440305196910126997', '19469235806'),
         ('A2220', 1, 'SC_DR07_2026-10-10', 'S8', '朱平', '330102198402199632', '13460235916'),
         ('A2221', 2, 'SC_DR07_2026-10-10', 'S8', '张明', '310104198805233515', '13529763087'),
         ('A2222', 1, 'SC_DR07_2026-10-10', 'S9', '马静', '440103195808194960', '13853174206'),
         ('A2223', 2, 'SC_DR07_2026-10-10', 'S9', '杨艳', '110105197801011741', '17368047911'),
         ('A2224', 3, 'SC_DR07_2026-10-10', 'S9', '朱磊', '31010419610921440X', '15630874193'),
         ('A2225', 1, 'SC_DR07_2026-10-10', 'S10', '罗娟', '320102197411266706', '17640853974'),
         ('A2226', 2, 'SC_DR07_2026-10-10', 'S10', '陈勇', '440305196512156234', '19814602571'),
         ('A2227', 1, 'SC_DR07_2026-10-10', 'S11', '徐娟', '440103196209084684', '18813570241'),
         ('A2228', 1, 'SC_DR07_2026-10-10', 'S12', '杨霞', '330102198301039445', '18531842973'),
         ('A2229', 2, 'SC_DR07_2026-10-10', 'S12', '马明', '440103200406146222', '19135724699'),
         ('A2230', 3, 'SC_DR07_2026-10-10', 'S12', '黄娜', '320102198603068872', '18074219538'),
         ('A2231', 4, 'SC_DR07_2026-10-10', 'S12', '吴涛', '310101198104073329', '17792480355'),
         ('A2232', 5, 'SC_DR07_2026-10-10', 'S12', '朱强', '330102198204089248', '17530864193'),
         ('A2233', 1, 'SC_DR07_2026-10-11', 'S1', '黄勇', '440103195808063899', '18803579140'),
         ('A2234', 1, 'SC_DR07_2026-10-11', 'S2', '李涛', '330102197912018657', '17197508649'),
         ('A2235', 1, 'SC_DR07_2026-10-11', 'S3', '张洋', '110101198702200044', '15803679250'),
         ('A2236', 2, 'SC_DR07_2026-10-11', 'S3', '孙强', '320102195306067191', '17863097420'),
         ('A2237', 3, 'SC_DR07_2026-10-11', 'S3', '孙超', '320102198302208325', '13357046815'),
         ('A2238', 4, 'SC_DR07_2026-10-11', 'S3', '林磊', '440103200006256625', '15086419752'),
         ('A2239', 1, 'SC_DR07_2026-10-11', 'S4', '郭军', '330102198003077830', '17206431750'),
         ('A2240', 2, 'SC_DR07_2026-10-11', 'S4', '何敏', '32010219630716000X', '15571346023'),
         ('A2241', 3, 'SC_DR07_2026-10-11', 'S4', '周芳', '440103197109207231', '15086497538'),
         ('A2242', 1, 'SC_DR07_2026-10-11', 'S5', '何娜', '110105199406020276', '15913602471'),
         ('A2243', 2, 'SC_DR07_2026-10-11', 'S5', '张涛', '440103199203195133', '13419720866'),
         ('A2244', 1, 'SC_DR07_2026-10-11', 'S6', '郭秀英', '310104195510234410', '13419752081'),
         ('A2245', 1, 'SC_DR07_2026-10-11', 'S7', '赵杰', '330102198003238809', '13793581469'),
         ('A2246', 2, 'SC_DR07_2026-10-11', 'S7', '马磊', '330102198201028108', '17196308529'),
         ('A2247', 3, 'SC_DR07_2026-10-11', 'S7', '林平', '440305199905105458', '19357024691'),
         ('A2248', 4, 'SC_DR07_2026-10-11', 'S7', '周芳', '330102197009041287', '19975286411'),
         ('A2249', 1, 'SC_DR07_2026-10-11', 'S8', '刘平', '31010419871008334X', '13530742967'),
         ('A2250', 2, 'SC_DR07_2026-10-11', 'S8', '孙霞', '440305199707156190', '19570268143'),
         ('A2251', 3, 'SC_DR07_2026-10-11', 'S8', '吴娜', '11010519980716211X', '19075318644'),
         ('A2252', 1, 'SC_DR07_2026-10-11', 'S9', '刘磊', '110105197011243476', '18257914680'),
         ('A2253', 2, 'SC_DR07_2026-10-11', 'S9', '郭洋', '310104199404215521', '15531864207'),
         ('A2254', 1, 'SC_DR07_2026-10-11', 'S10', '胡霞', '440305196712165450', '19802591360'),
         ('A2255', 1, 'SC_DR07_2026-10-11', 'S11', '黄芳', '310104195309223015', '13196320749'),
         ('A2256', 2, 'SC_DR07_2026-10-11', 'S11', '赵杰', '310104199201025189', '18460235912'),
         ('A2257', 1, 'SC_DR07_2026-10-11', 'S12', '郭秀英', '310104195309093986', '18692470358'),
         ('A2258', 2, 'SC_DR07_2026-10-11', 'S12', '张霞', '310104195507173290', '13085397418'),
         ('A2259', 3, 'SC_DR07_2026-10-11', 'S12', '陈洋', '110105197211250638', '15247913680'),
         ('A2260', 1, 'SC_DR07_2026-10-12', 'S1', '郭勇', '31010419830115256X', '13307529645'),
         ('A2261', 1, 'SC_DR07_2026-10-12', 'S2', '黄军', '310101198009013029', '17358024791'),
         ('A2262', 2, 'SC_DR07_2026-10-12', 'S2', '刘霞', '310101195809203951', '13741985205'),
         ('A2263', 1, 'SC_DR07_2026-10-12', 'S3', '周芳', '44030520010524683X', '15429731866'),
         ('A2264', 2, 'SC_DR07_2026-10-12', 'S3', '周杰', '310101200108061640', '17702481359'),
         ('A2265', 3, 'SC_DR07_2026-10-12', 'S3', '马磊', '110105197801141693', '19752986309'),
         ('A2266', 1, 'SC_DR07_2026-10-12', 'S4', '高秀英', '110101196211268870', '15024613578'),
         ('A2267', 1, 'SC_DR07_2026-10-12', 'S5', '胡洋', '320102195009046730', '17196320743'),
         ('A2268', 1, 'SC_DR07_2026-10-12', 'S6', '林芳', '11010119680128087X', '15570268143'),
         ('A2269', 2, 'SC_DR07_2026-10-12', 'S6', '赵娜', '440103199504214756', '15530742967'),
         ('A2270', 1, 'SC_DR07_2026-10-12', 'S7', '黄平', '310104198605224120', '13752086419'),
         ('A2271', 2, 'SC_DR07_2026-10-12', 'S7', '罗敏', '440103200404086334', '19914680357'),
         ('A2272', 1, 'SC_DR07_2026-10-12', 'S8', '罗秀英', '310104197207043119', '18257913688'),
         ('A2273', 2, 'SC_DR07_2026-10-12', 'S8', '马静', '440305197801028436', '17631975204'),
         ('A2274', 3, 'SC_DR07_2026-10-12', 'S8', '胡芳', '330102197011251208', '15681479254'),
         ('A2275', 1, 'SC_DR07_2026-10-12', 'S9', '周秀英', '440305196510225136', '15074296318'),
         ('A2276', 1, 'SC_DR07_2026-10-12', 'S11', '徐明', '310101198001013104', '17792468135'),
         ('A2277', 2, 'SC_DR07_2026-10-12', 'S11', '张霞', '310104196510235194', '15752086312'),
         ('A2278', 3, 'SC_DR07_2026-10-12', 'S11', '周杰', '110105196502032548', '17570268133'),
         ('A2279', 1, 'SC_DR07_2026-10-12', 'S12', '王超', '310104198402152649', '13640852978'),
         ('A2280', 2, 'SC_DR07_2026-10-12', 'S12', '周涛', '33010219561023876X', '13581369243'),
         ('A2281', 1, 'SC_DR07_2026-10-13', 'S2', '高娟', '310101197602171365', '19195320643'),
         ('A2282', 2, 'SC_DR07_2026-10-13', 'S2', '吴超', '320102197211137483', '19036892573'),
         ('A2283', 1, 'SC_DR07_2026-10-13', 'S3', '杨艳', '310104198705103297', '18813502466'),
         ('A2284', 1, 'SC_DR07_2026-10-13', 'S4', '王杰', '320102195006267677', '17864275311'),
         ('A2285', 1, 'SC_DR07_2026-10-13', 'S5', '林芳', '110105196810230992', '15460235912'),
         ('A2286', 1, 'SC_DR07_2026-10-13', 'S6', '王超', '440305200005235607', '15539742867'),
         ('A2287', 2, 'SC_DR07_2026-10-13', 'S6', '马平', '330102196111259712', '13247035810'),
         ('A2288', 1, 'SC_DR07_2026-10-13', 'S7', '林平', '310104195103056805', '13479136802'),
         ('A2289', 1, 'SC_DR07_2026-10-13', 'S8', '林磊', '110101198805110260', '18420753182'),
         ('A2290', 1, 'SC_DR07_2026-10-13', 'S9', '高敏', '11010519930602128X', '15469157026'),
         ('A2291', 1, 'SC_DR07_2026-10-13', 'S10', '杨军', '440103199206125157', '18469157032'),
         ('A2292', 2, 'SC_DR07_2026-10-13', 'S10', '何杰', '110101196309059030', '18429631856'),
         ('A2293', 1, 'SC_DR07_2026-10-13', 'S12', '吴杰', '310104198605103142', '18913502467'),
         ('A2294', 1, 'SC_DR07_2026-10-14', 'S1', '黄伟', '310104199605235967', '15197520863'),
         ('A2295', 2, 'SC_DR07_2026-10-14', 'S1', '朱霞', '110105197211250638', '15813570246'),
         ('A2296', 1, 'SC_DR07_2026-10-14', 'S3', '徐丽', '330102196510079380', '18206431754'),
         ('A2297', 1, 'SC_DR07_2026-10-14', 'S4', '郭娜', '110101197109201527', '15359124701'),
         ('A2298', 1, 'SC_DR07_2026-10-14', 'S5', '高军', '310104199502165695', '15864275311'),
         ('A2299', 2, 'SC_DR07_2026-10-14', 'S5', '何芳', '330102199104249835', '15024713585'),
         ('A2300', 1, 'SC_DR07_2026-10-14', 'S8', '郭娜', '440103196710126518', '19136924803'),
         ('A2301', 1, 'SC_DR07_2026-10-14', 'S9', '陈霞', '11010520010613260X', '19319742081'),
         ('A2302', 1, 'SC_DR07_2026-10-14', 'S12', '杨平', '310104198805234550', '13420853197'),
         ('A2303', 1, 'SC_DR07_2026-10-15', 'S2', '张超', '110101199705111885', '19864297536'),
         ('A2304', 1, 'SC_DR07_2026-10-15', 'S3', '高静', '310104196410106037', '19247035814'),
         ('A2305', 1, 'SC_DR07_2026-10-15', 'S6', '李涛', '440305197309227708', '17753064295'),
         ('A2306', 1, 'SC_DR07_2026-10-15', 'S7', '徐超', '310101199506011619', '15570346917'),
         ('A2307', 1, 'SC_DR07_2026-10-15', 'S8', '朱磊', '440103200006255630', '15641975209'),
         ('A2308', 1, 'SC_DR07_2026-10-15', 'S10', '罗秀英', '310104195407043181', '18691358028'),
         ('A2309', 1, 'SC_DR07_2026-10-16', 'S2', '马霞', '110105197801012648', '17025713688'),
         ('A2310', 1, 'SC_DR07_2026-10-16', 'S3', '张涛', '310101198603184170', '13975208631'),
         ('A2311', 1, 'SC_DR07_2026-10-16', 'S6', '孙霞', '320102196107159733', '13136902589'),
         ('A2312', 1, 'SC_DR07_2026-10-16', 'S7', '胡强', '440103200304207186', '15642053198'),
         ('A2313', 1, 'SC_DR07_2026-10-16', 'S9', '李明', '440103197212276489', '17641875204'),
         ('A2314', 1, 'SC_DR07_2026-10-16', 'S10', '徐秀英', '440305197312277669', '17641975204'),
         ('A2315', 1, 'SC_DR07_2026-10-16', 'S11', '罗丽', '320102198202199177', '13682479358'),
         ('A2316', 1, 'SC_DR07_2026-10-17', 'S1', '张洋', '440103197209087388', '19359124805'),
         ('A2317', 1, 'SC_DR07_2026-10-17', 'S2', '朱洋', '110105200504092308', '13429731852'),
         ('A2318', 1, 'SC_DR07_2026-10-17', 'S4', '张涛', '31010119550818438X', '13742085314'),
         ('A2319', 1, 'SC_DR07_2026-10-17', 'S5', '高敏', '440305197801178530', '13792580369'),
         ('A2320', 1, 'SC_DR07_2026-10-17', 'S9', '黄平', '440305195105107924', '13025891478'),
         ('A2321', 1, 'SC_DR07_2026-10-17', 'S10', '朱伟', '440305200205120206', '19025791468'),
         ('A2322', 1, 'SC_DR07_2026-10-17', 'S11', '胡强', '310104198602164134', '13641953088'),
         ('A2323', 1, 'SC_DR07_2026-10-17', 'S12', '何娜', '330102195608177662', '13357924680'),
         ('A2324', 1, 'SC_DR07_2026-10-19', 'S1', '马超', '110105196910239994', '15136802479'),
         ('A2325', 1, 'SC_DR07_2026-10-19', 'S4', '孙强', '110101196712129625', '18752086319'),
         ('A2326', 1, 'SC_DR07_2026-10-19', 'S5', '赵勇', '110101196412279234', '15579168023'),
         ('A2327', 1, 'SC_DR07_2026-10-19', 'S6', '孙敏', '310101197703172463', '19197520863'),
         ('A2328', 1, 'SC_DR07_2026-10-19', 'S8', '朱洋', '440103198209214839', '15296418530'),
         ('A2329', 1, 'SC_DR07_2026-10-19', 'S10', '郭伟', '310104199705115065', '19570268133'),
         ('A2330', 1, 'SC_DR07_2026-10-20', 'S3', '徐超', '32010219740220778X', '13681479258'),
         ('A2331', 1, 'SC_DR07_2026-10-20', 'S4', '徐静', '320102197712287228', '17084297318'),
         ('A2332', 1, 'SC_DR07_2026-10-20', 'S6', '陈霞', '32010219731126763X', '17085397428'),
         ('A2333', 2, 'SC_DR07_2026-10-20', 'S6', '郭芳', '310104199204084109', '18468057922'),
         ('A2334', 1, 'SC_DR07_2026-10-20', 'S7', '杨军', '440103196009075361', '18026891572'),
         ('A2335', 1, 'SC_DR07_2026-10-20', 'S8', '郭勇', '440305200008015562', '18640875198'),
         ('A2336', 1, 'SC_DR07_2026-10-20', 'S9', '罗敏', '31010119760205138X', '17802591466'),
         ('A2337', 1, 'SC_DR07_2026-10-20', 'S10', '朱明', '440103196608065392', '19257914684'),
         ('A2338', 1, 'SC_DR08_2026-10-07', 'S1', '黄艳', '320102195909208272', '13025713688'),
         ('A2339', 1, 'SC_DR08_2026-10-07', 'S2', '罗杰', '310104199204215244', '13208531964'),
         ('A2340', 1, 'SC_DR08_2026-10-07', 'S3', '徐超', '110105198402043716', '17358046910'),
         ('A2341', 2, 'SC_DR08_2026-10-07', 'S3', '赵娜', '440305195305237272', '17963185201'),
         ('A2342', 3, 'SC_DR08_2026-10-07', 'S3', '周军', '320102197111136248', '19913580241'),
         ('A2343', 1, 'SC_DR08_2026-10-07', 'S4', '高娟', '44010320040421624X', '17318520745'),
         ('A2344', 2, 'SC_DR08_2026-10-07', 'S4', '周涛', '320102196310220034', '15258036910'),
         ('A2345', 1, 'SC_DR08_2026-10-07', 'S5', '林平', '320102196307168992', '15358024791'),
         ('A2346', 2, 'SC_DR08_2026-10-07', 'S5', '赵芳', '110101196312110052', '18319742085'),
         ('A2347', 1, 'SC_DR08_2026-10-07', 'S6', '孙静', '440305195305238240', '17641953088'),
         ('A2348', 1, 'SC_DR08_2026-10-07', 'S7', '吴涛', '330102196708180804', '15036892578'),
         ('A2349', 2, 'SC_DR08_2026-10-07', 'S7', '李明', '440305197001025990', '15296430750'),
         ('A2350', 3, 'SC_DR08_2026-10-07', 'S7', '高娜', '110105197001020244', '15136825799'),
         ('A2351', 1, 'SC_DR08_2026-10-07', 'S8', '罗涛', '440305197801027556', '17974108527'),
         ('A2352', 2, 'SC_DR08_2026-10-07', 'S8', '赵娟', '440103199304075464', '18247913689'),
         ('A2353', 1, 'SC_DR08_2026-10-07', 'S9', '朱明', '110101199505260544', '15691370249'),
         ('A2354', 1, 'SC_DR08_2026-10-07', 'S10', '刘磊', '110101197710231495', '17024681357'),
         ('A2355', 2, 'SC_DR08_2026-10-07', 'S10', '张超', '330102195911089286', '17318642075'),
         ('A2356', 3, 'SC_DR08_2026-10-07', 'S10', '林芳', '31010119530705399X', '18147925803'),
         ('A2357', 1, 'SC_DR08_2026-10-07', 'S11', '赵娜', '440103199903185470', '15307529645'),
         ('A2358', 1, 'SC_DR08_2026-10-07', 'S12', '何敏', '320102196307160034', '15026891478'),
         ('A2359', 1, 'SC_DR08_2026-10-08', 'S1', '马磊', '110105197411100941', '19529741867'),
         ('A2360', 2, 'SC_DR08_2026-10-08', 'S1', '何敏', '440103199106125053', '18247935809'),
         ('A2361', 3, 'SC_DR08_2026-10-08', 'S1', '周娜', '320102197302047707', '17075319648'),
         ('A2362', 1, 'SC_DR08_2026-10-08', 'S2', '黄杰', '440305199805106330', '19469235802'),
         ('A2363', 1, 'SC_DR08_2026-10-08', 'S3', '孙静', '440305199805226287', '15864175300'),
         ('A2364', 1, 'SC_DR08_2026-10-08', 'S4', '何芳', '330102196111258648', '13803591466'),
         ('A2365', 2, 'SC_DR08_2026-10-08', 'S4', '徐秀英', '320102198311269381', '18420731862'),
         ('A2366', 1, 'SC_DR08_2026-10-08', 'S5', '徐静', '320102195009046706', '17428653976'),
         ('A2367', 2, 'SC_DR08_2026-10-08', 'S5', '林芳', '310101200205282824', '17026891572'),
         ('A2368', 3, 'SC_DR08_2026-10-08', 'S5', '赵芳', '330102196608020547', '18530842977'),
         ('A2369', 1, 'SC_DR08_2026-10-08', 'S6', '刘艳', '440305200308187171', '19914702587'),
         ('A2370', 1, 'SC_DR08_2026-10-08', 'S7', '李娟', '440103199006244936', '13642075318'),
         ('A2371', 1, 'SC_DR08_2026-10-08', 'S8', '马超', '320102197812167397', '13357924685'),
         ('A2372', 1, 'SC_DR08_2026-10-08', 'S9', '徐静', '320102199512280573', '19974186207'),
         ('A2373', 2, 'SC_DR08_2026-10-08', 'S9', '黄杰', '440103196211145677', '18681479258'),
         ('A2374', 1, 'SC_DR08_2026-10-08', 'S10', '罗杰', '310104198502164022', '13086397522'),
         ('A2375', 2, 'SC_DR08_2026-10-08', 'S10', '王敏', '110101198604268846', '15368057916'),
         ('A2376', 1, 'SC_DR08_2026-10-08', 'S11', '何敏', '44030520020512694X', '19681357023'),
         ('A2377', 2, 'SC_DR08_2026-10-08', 'S11', '周秀英', '110101199905121148', '19317542861'),
         ('A2378', 1, 'SC_DR08_2026-10-08', 'S12', '李超', '110101196710079759', '18973186201'),
         ('A2379', 1, 'SC_DR08_2026-10-09', 'S1', '胡芳', '11010519690101104X', '15248035910'),
         ('A2380', 1, 'SC_DR08_2026-10-09', 'S2', '罗涛', '310104198504222900', '13429653076'),
         ('A2381', 2, 'SC_DR08_2026-10-09', 'S2', '罗静', '440305196810116695', '19915780361'),
         ('A2382', 3, 'SC_DR08_2026-10-09', 'S2', '胡磊', '110101197610072300', '19530842977'),
         ('A2383', 1, 'SC_DR08_2026-10-09', 'S3', '刘强', '110101196211258728', '15681379241'),
         ('A2384', 2, 'SC_DR08_2026-10-09', 'S3', '陈霞', '440103196708186511', '15318620751'),
         ('A2385', 1, 'SC_DR08_2026-10-09', 'S4', '高勇', '310101197812122684', '19530842977'),
         ('A2386', 1, 'SC_DR08_2026-10-09', 'S5', '陈勇', '440305200005106549', '19470236912'),
         ('A2387', 1, 'SC_DR08_2026-10-09', 'S6', '杨芳', '310101197712121473', '19307529645'),
         ('A2388', 2, 'SC_DR08_2026-10-09', 'S6', '何敏', '440103199406145582', '18247035910'),
         ('A2389', 3, 'SC_DR08_2026-10-09', 'S6', '林洋', '32010219950606150X', '19752086315'),
         ('A2390', 1, 'SC_DR08_2026-10-09', 'S7', '胡平', '32010220040612621X', '19246813579'),
         ('A2391', 2, 'SC_DR08_2026-10-09', 'S7', '罗军', '310101198402173862', '13864197520'),
         ('A2392', 1, 'SC_DR08_2026-10-09', 'S8', '高勇', '440103196312275817', '15420853192'),
         ('A2393', 1, 'SC_DR08_2026-10-09', 'S10', '罗丽', '440305200108170113', '15914702587'),
         ('A2394', 1, 'SC_DR08_2026-10-09', 'S11', '徐敏', '310104198905234603', '13642075318'),
         ('A2395', 2, 'SC_DR08_2026-10-09', 'S11', '高娜', '440305195105106817', '13570246913'),
         ('A2396', 1, 'SC_DR08_2026-10-09', 'S12', '黄勇', '310101197803051589', '17803591466'),
         ('A2397', 2, 'SC_DR08_2026-10-09', 'S12', '罗杰', '320102198111259066', '17186407539'),
         ('A2398', 1, 'SC_DR08_2026-10-10', 'S2', '王杰', '440305195205238139', '17964275311'),
         ('A2399', 2, 'SC_DR08_2026-10-10', 'S2', '郭伟', '320102198502218691', '13913602571'),
         ('A2400', 1, 'SC_DR08_2026-10-10', 'S3', '张磊', '33010219650817037X', '15137902689'),
         ('A2401', 1, 'SC_DR08_2026-10-10', 'S4', '李明', '310101199004203856', '13307541865'),
         ('A2402', 1, 'SC_DR08_2026-10-10', 'S6', '刘超', '440305195207018121', '17853196420'),
         ('A2403', 2, 'SC_DR08_2026-10-10', 'S6', '黄艳', '440103199404084595', '18035792468'),
         ('A2404', 1, 'SC_DR08_2026-10-10', 'S7', '刘洋', '440103200407147411', '19130268139'),
         ('A2405', 2, 'SC_DR08_2026-10-10', 'S7', '黄娜', '31010119890113362X', '13530842978'),
         ('A2406', 1, 'SC_DR08_2026-10-10', 'S8', '张霞', '320102198111268026', '17630852973'),
         ('A2407', 1, 'SC_DR08_2026-10-10', 'S9', '张丽', '110101199803221105', '17924680351'),
         ('A2408', 1, 'SC_DR08_2026-10-10', 'S10', '胡霞', '440103199607154872', '19357046811'),
         ('A2409', 1, 'SC_DR08_2026-10-10', 'S11', '王超', '310104198504222943', '13963107421'),
         ('A2410', 2, 'SC_DR08_2026-10-10', 'S11', '马霞', '330102198101179056', '13570346927'),
         ('A2411', 1, 'SC_DR08_2026-10-11', 'S1', '赵芳', '440103196008205312', '15085397428'),
         ('A2412', 1, 'SC_DR08_2026-10-11', 'S2', '罗秀英', '110105199504250569', '15368025799'),
         ('A2413', 2, 'SC_DR08_2026-10-11', 'S2', '马静', '110105200110132610', '19752086315'),
         ('A2414', 1, 'SC_DR08_2026-10-11', 'S4', '朱伟', '440103196111135463', '18681479258'),
         ('A2415', 1, 'SC_DR08_2026-10-11', 'S5', '张涛', '110105199206141073', '18208531970'),
         ('A2416', 2, 'SC_DR08_2026-10-11', 'S5', '吴娟', '440103196708065437', '19802479130'),
         ('A2417', 1, 'SC_DR08_2026-10-11', 'S9', '周芳', '110105196810071004', '18531842077'),
         ('A2418', 1, 'SC_DR08_2026-10-11', 'S10', '林艳', '440103199612214796', '15641853078'),
         ('A2419', 2, 'SC_DR08_2026-10-11', 'S10', '黄杰', '440103199406145638', '18359146021'),
         ('A2420', 1, 'SC_DR08_2026-10-11', 'S11', '林伟', '310104198402032727', '18680257914'),
         ('A2421', 1, 'SC_DR08_2026-10-11', 'S12', '王娟', '440305200105246864', '15075396422'),
         ('A2422', 1, 'SC_DR08_2026-10-12', 'S1', '马霞', '440305198701170149', '19804691570'),
         ('A2423', 1, 'SC_DR08_2026-10-12', 'S3', '何芳', '330102198003237822', '13802491350'),
         ('A2424', 2, 'SC_DR08_2026-10-12', 'S3', '杨平', '320102195307288252', '17742063199'),
         ('A2425', 1, 'SC_DR08_2026-10-12', 'S4', '赵芳', '440103196009205357', '15531942083'),
         ('A2426', 2, 'SC_DR08_2026-10-12', 'S4', '林平', '330102196711249729', '15357946801'),
         ('A2427', 1, 'SC_DR08_2026-10-12', 'S5', '李强', '440103198009088962', '13571346027'),
         ('A2428', 1, 'SC_DR08_2026-10-12', 'S8', '刘明', '310101197703182530', '19085319642'),
         ('A2429', 1, 'SC_DR08_2026-10-12', 'S9', '李强', '440103199106125088', '18792580365'),
         ('A2430', 1, 'SC_DR08_2026-10-12', 'S10', '王强', '310101195608064588', '18681379248'),
         ('A2431', 1, 'SC_DR08_2026-10-12', 'S11', '张超', '440103197212277414', '17863197426'),
         ('A2432', 1, 'SC_DR08_2026-10-13', 'S2', '马霞', '320102197211137424', '19358121705'),
         ('A2433', 1, 'SC_DR08_2026-10-13', 'S3', '罗军', '310104195207153829', '13085397428'),
         ('A2434', 1, 'SC_DR08_2026-10-13', 'S4', '周杰', '320102197101196298', '19247935804'),
         ('A2435', 1, 'SC_DR08_2026-10-13', 'S5', '林艳', '440103195710243736', '13307541860'),
         ('A2436', 1, 'SC_DR08_2026-10-13', 'S6', '刘艳', '33010219790322861X', '13681479258'),
         ('A2437', 1, 'SC_DR08_2026-10-13', 'S7', '胡强', '110105199607151678', '19075318648'),
         ('A2438', 1, 'SC_DR08_2026-10-13', 'S8', '林伟', '330102196009198538', '13469135802'),
         ('A2439', 1, 'SC_DR08_2026-10-13', 'S9', '林艳', '110105197211090603', '19085397412'),
         ('A2440', 1, 'SC_DR08_2026-10-13', 'S12', '何杰', '320102198512278719', '18296418539'),
         ('A2441', 1, 'SC_DR08_2026-10-14', 'S1', '刘磊', '320102195009196616', '19024713588'),
         ('A2442', 1, 'SC_DR08_2026-10-14', 'S4', '黄芳', '310104198301152631', '13084296312'),
         ('A2443', 1, 'SC_DR08_2026-10-14', 'S5', '林平', '320102195407167378', '13580247913'),
         ('A2444', 1, 'SC_DR08_2026-10-14', 'S11', '孙丽', '330102195708027987', '17530742967'),
         ('A2445', 1, 'SC_DR08_2026-10-14', 'S12', '赵娟', '320102195407168442', '13571346023'),
         ('A2446', 1, 'SC_DR08_2026-10-15', 'S1', '徐秀英', '320102198603069920', '18864197526'),
         ('A2447', 1, 'SC_DR08_2026-10-15', 'S2', '陈洋', '440103197111146263', '19024713582'),
         ('A2448', 1, 'SC_DR08_2026-10-15', 'S6', '李静', '110101199703210927', '17024691352'),
         ('A2449', 1, 'SC_DR08_2026-10-15', 'S11', '何娜', '330102198803229249', '15914602571'),
         ('A2450', 1, 'SC_DR08_2026-10-16', 'S3', '黄艳', '440305200306126121', '19135702469'),
         ('A2451', 1, 'SC_DR08_2026-10-16', 'S6', '高杰', '110105197001140174', '18206431754'),
         ('A2452', 1, 'SC_DR08_2026-10-16', 'S8', '陈明', '110105199404081307', '19075396427'),
         ('A2453', 1, 'SC_DR08_2026-10-17', 'S2', '周涛', '320102198001188906', '13682479358'),
         ('A2454', 1, 'SC_DR08_2026-10-17', 'S6', '罗军', '110105195004253466', '17570346927'),
         ('A2455', 1, 'SC_DR08_2026-10-17', 'S12', '高娟', '310104197705224772', '15207531865'),
         ('A2456', 1, 'SC_DR08_2026-10-18', 'S3', '周涛', '320102198111139048', '13793568149'),
         ('A2457', 1, 'SC_DR08_2026-10-18', 'S7', '黄杰', '320102198603219941', '15571368247'),
         ('A2458', 1, 'SC_DR08_2026-10-18', 'S11', '黄芳', '110105200406152055', '19318642971'),
         ('A2459', 1, 'SC_DR08_2026-10-19', 'S2', '黄艳', '310104197610031230', '17791468035'),
         ('A2460', 1, 'SC_DR08_2026-10-19', 'S3', '徐静', '320102196007278495', '18085297412'),
         ('A2461', 1, 'SC_DR08_2026-10-19', 'S6', '何娜', '110101197212260525', '15468157922'),
         ('A2462', 1, 'SC_DR08_2026-10-19', 'S10', '郭军', '320102198412278535', '18752964085'),
         ('A2463', 1, 'SC_DR08_2026-10-20', 'S3', '张明', '440305196107288604', '18318542975'),
         ('A2464', 1, 'SC_DR08_2026-10-20', 'S12', '周娜', '310104199304215380', '15975308641'),
         ('A2465', 1, 'SC_DR09_2026-10-07', 'S1', '黄芳', '110101198602048858', '18206418530'),
         ('A2466', 2, 'SC_DR09_2026-10-07', 'S1', '朱伟', '330102198404259555', '13803691470'),
         ('A2467', 3, 'SC_DR09_2026-10-07', 'S1', '马丽', '31010119660217385X', '18086319742'),
         ('A2468', 4, 'SC_DR09_2026-10-07', 'S1', '陈磊', '11010519510704259X', '17924603571'),
         ('A2469', 5, 'SC_DR09_2026-10-07', 'S1', '黄娜', '310104198304212644', '13974108521'),
         ('A2470', 6, 'SC_DR09_2026-10-07', 'S1', '黄军', '310101200406013161', '17460235816'),
         ('A2471', 7, 'SC_DR09_2026-10-07', 'S1', '李涛', '110101197410062044', '19085396422'),
         ('A2472', 1, 'SC_DR09_2026-10-07', 'S2', '胡芳', '330102198402199640', '13792468139'),
         ('A2473', 2, 'SC_DR09_2026-10-07', 'S2', '胡艳', '310104198705223205', '13317542865'),
         ('A2474', 1, 'SC_DR09_2026-10-07', 'S3', '李娟', '440305196409226046', '15752064195'),
         ('A2475', 2, 'SC_DR09_2026-10-07', 'S3', '林平', '310101198903073675', '18469157022'),
         ('A2476', 3, 'SC_DR09_2026-10-07', 'S3', '郭勇', '440103197212276323', '17641975204'),
         ('A2477', 1, 'SC_DR09_2026-10-07', 'S4', '孙涛', '330102198404258501', '13914602571'),
         ('A2478', 2, 'SC_DR09_2026-10-07', 'S4', '罗军', '110105197512112204', '19864175200'),
         ('A2479', 3, 'SC_DR09_2026-10-07', 'S4', '黄军', '440305197510107900', '13804679350'),
         ('A2480', 4, 'SC_DR09_2026-10-07', 'S4', '杨芳', '310101195606133607', '13296418530'),
         ('A2481', 1, 'SC_DR09_2026-10-07', 'S5', '何杰', '440305196901025940', '15074218537'),
         ('A2482', 2, 'SC_DR09_2026-10-07', 'S5', '刘洋', '330102196508170441', '15359124801'),
         ('A2483', 3, 'SC_DR09_2026-10-07', 'S5', '高勇', '440103196708186503', '15530842973'),
         ('A2484', 4, 'SC_DR09_2026-10-07', 'S5', '张强', '310101200406012150', '17035792462'),
         ('A2485', 5, 'SC_DR09_2026-10-07', 'S5', '李明', '440103200504216458', '17196408523'),
         ('A2486', 6, 'SC_DR09_2026-10-07', 'S5', '孙霞', '440103200206136978', '19469257132'),
         ('A2487', 1, 'SC_DR09_2026-10-07', 'S6', '马平', '110101199106280820', '15025713682'),
         ('A2488', 1, 'SC_DR09_2026-10-07', 'S7', '张超', '440305197001037158', '15742085314'),
         ('A2489', 2, 'SC_DR09_2026-10-07', 'S7', '刘强', '110101199602200674', '15570246917'),
         ('A2490', 1, 'SC_DR09_2026-10-07', 'S8', '高娜', '110105197311254011', '18136802579'),
         ('A2491', 2, 'SC_DR09_2026-10-07', 'S8', '罗杰', '440103200306267238', '15642075319'),
         ('A2492', 3, 'SC_DR09_2026-10-07', 'S8', '胡伟', '310101196512156191', '19914602581'),
         ('A2493', 4, 'SC_DR09_2026-10-07', 'S8', '赵秀英', '320102195109056864', '17529763087'),
         ('A2494', 5, 'SC_DR09_2026-10-07', 'S8', '刘强', '110105200106011576', '17035714682'),
         ('A2495', 1, 'SC_DR09_2026-10-07', 'S9', '何军', '310104198402152817', '13752964189'),
         ('A2496', 1, 'SC_DR09_2026-10-07', 'S10', '周芳', '110105200504103425', '13208619750'),
         ('A2497', 1, 'SC_DR09_2026-10-07', 'S11', '王丽', '440103197309097575', '19258014794'),
         ('A2498', 2, 'SC_DR09_2026-10-07', 'S11', '朱洋', '110101197512121148', '19084219532'),
         ('A2499', 3, 'SC_DR09_2026-10-07', 'S11', '朱霞', '310104196901175854', '19469157026'),
         ('A2500', 4, 'SC_DR09_2026-10-07', 'S11', '张涛', '310104198404213847', '13186420753'),
         ('A2501', 5, 'SC_DR09_2026-10-07', 'S11', '郭秀英', '110105195211043795', '18803691470'),
         ('A2502', 1, 'SC_DR09_2026-10-07', 'S12', '孙强', '330102199101039859', '18207519640'),
         ('A2503', 2, 'SC_DR09_2026-10-07', 'S12', '胡芳', '310104196610116299', '19803691470'),
         ('A2504', 3, 'SC_DR09_2026-10-07', 'S12', '周娜', '110101196712130730', '18429753086'),
         ('A2505', 1, 'SC_DR09_2026-10-08', 'S1', '朱霞', '440305197001186030', '19135724693'),
         ('A2506', 2, 'SC_DR09_2026-10-08', 'S1', '朱强', '110105197011081227', '18753164209'),
         ('A2507', 3, 'SC_DR09_2026-10-08', 'S1', '陈勇', '440103196708066608', '19359124805'),
         ('A2508', 1, 'SC_DR09_2026-10-08', 'S2', '何艳', '310101200008182509', '19086319748'),
         ('A2509', 1, 'SC_DR09_2026-10-08', 'S3', '马平', '110105199707031825', '17025713682'),
         ('A2510', 2, 'SC_DR09_2026-10-08', 'S3', '吴静', '31010419560817345X', '13074286317'),
         ('A2511', 3, 'SC_DR09_2026-10-08', 'S3', '孙超', '110105197311250803', '17146803579'),
         ('A2512', 4, 'SC_DR09_2026-10-08', 'S3', '郭洋', '310104199803186326', '15319720865'),
         ('A2513', 5, 'SC_DR09_2026-10-08', 'S3', '吴超', '320102197411147766', '19925781462'),
         ('A2514', 6, 'SC_DR09_2026-10-08', 'S3', '刘静', '440103199402264592', '15630874198'),
         ('A2515', 7, 'SC_DR09_2026-10-08', 'S3', '马明', '440305197512166883', '13468057926'),
         ('A2516', 1, 'SC_DR09_2026-10-08', 'S4', '马磊', '310101199905111262', '19428631752'),
         ('A2517', 2, 'SC_DR09_2026-10-08', 'S4', '何敏', '320102197202197521', '19692480359'),
         ('A2518', 3, 'SC_DR09_2026-10-08', 'S4', '刘明', '110101197312111826', '19531864297'),
         ('A2519', 1, 'SC_DR09_2026-10-08', 'S5', '刘强', '320102197311146600', '19357024695'),
         ('A2520', 2, 'SC_DR09_2026-10-08', 'S5', '张超', '310101195608194569', '13420853192'),
         ('A2521', 1, 'SC_DR09_2026-10-08', 'S6', '赵伟', '110105199604091673', '19419730862'),
         ('A2522', 1, 'SC_DR09_2026-10-08', 'S7', '赵娟', '440305196509096138', '19460235816'),
         ('A2523', 2, 'SC_DR09_2026-10-08', 'S7', '罗娟', '440305199807285299', '15752986309'),
         ('A2524', 3, 'SC_DR09_2026-10-08', 'S7', '胡平', '440305197412156733', '13357046815'),
         ('A2525', 4, 'SC_DR09_2026-10-08', 'S7', '孙静', '310104199504225663', '15208631974'),
         ('A2526', 5, 'SC_DR09_2026-10-08', 'S7', '杨军', '110105199406021359', '15137925803'),
         ('A2527', 6, 'SC_DR09_2026-10-08', 'S7', '王超', '310101200206131825', '19530842963'),
         ('A2528', 1, 'SC_DR09_2026-10-08', 'S8', '高娟', '110101196612129599', '18074219532'),
         ('A2529', 2, 'SC_DR09_2026-10-08', 'S8', '高敏', '310101200506023383', '17570246917'),
         ('A2530', 3, 'SC_DR09_2026-10-08', 'S8', '朱丽', '320102195706258990', '17086497533'),
         ('A2531', 4, 'SC_DR09_2026-10-08', 'S8', '王敏', '31010420050204643X', '19802469135'),
         ('A2532', 5, 'SC_DR09_2026-10-08', 'S8', '高杰', '110101198702059087', '18207519640'),
         ('A2533', 1, 'SC_DR09_2026-10-08', 'S9', '张丽', '440305199907165411', '19246935700'),
         ('A2534', 2, 'SC_DR09_2026-10-08', 'S9', '徐秀英', '440103196708186482', '15207519640'),
         ('A2535', 3, 'SC_DR09_2026-10-08', 'S9', '周涛', '440103200304087145', '19026891578'),
         ('A2536', 4, 'SC_DR09_2026-10-08', 'S9', '黄娜', '310101198612123169', '13539742867'),
         ('A2537', 1, 'SC_DR09_2026-10-08', 'S10', '胡霞', '440305197309096584', '19680357928'),
         ('A2538', 1, 'SC_DR09_2026-10-08', 'S11', '孙强', '110105195004102465', '13196408539'),
         ('A2539', 2, 'SC_DR09_2026-10-08', 'S11', '周涛', '310104196510116259', '19681379248'),
         ('A2540', 1, 'SC_DR09_2026-10-08', 'S12', '王丽', '330102199001170606', '15247913684'),
         ('A2541', 2, 'SC_DR09_2026-10-08', 'S12', '王超', '440305195107286815', '17640875198'),
         ('A2542', 3, 'SC_DR09_2026-10-08', 'S12', '杨洋', '310101199907041202', '17680379148'),
         ('A2543', 1, 'SC_DR09_2026-10-09', 'S1', '周娜', '330102196111099608', '18531964207'),
         ('A2544', 2, 'SC_DR09_2026-10-09', 'S1', '吴杰', '110105197911241812', '17570246913'),
         ('A2545', 3, 'SC_DR09_2026-10-09', 'S1', '吴敏', '330102199302040207', '18530742963'),
         ('A2546', 1, 'SC_DR09_2026-10-09', 'S2', '陈磊', '110101196712289645', '15913502467'),
         ('A2547', 2, 'SC_DR09_2026-10-09', 'S2', '马静', '440103197209217445', '17642053194'),
         ('A2548', 3, 'SC_DR09_2026-10-09', 'S2', '林芳', '33010219640716021X', '15137902689'),
         ('A2549', 4, 'SC_DR09_2026-10-09', 'S2', '孙丽', '440103200203205907', '15963175201'),
         ('A2550', 1, 'SC_DR09_2026-10-09', 'S3', '周敏', '110105196901140044', '18196420753'),
         ('A2551', 2, 'SC_DR09_2026-10-09', 'S3', '刘艳', '31010419540704415X', '18804679350'),
         ('A2552', 3, 'SC_DR09_2026-10-09', 'S3', '黄平', '330102196608020600', '18631942088'),
         ('A2553', 4, 'SC_DR09_2026-10-09', 'S3', '罗秀英', '440103199103063926', '18802479136'),
         ('A2554', 5, 'SC_DR09_2026-10-09', 'S3', '吴静', '110101199103079849', '18974286317'),
         ('A2555', 6, 'SC_DR09_2026-10-09', 'S3', '林芳', '440305196512156103', '19581369247'),
         ('A2556', 1, 'SC_DR09_2026-10-09', 'S4', '杨勇', '44030519990510640X', '19248080767'),
         ('A2557', 1, 'SC_DR09_2026-10-09', 'S5', '罗军', '31010419830115360X', '13864275310'),
         ('A2558', 2, 'SC_DR09_2026-10-09', 'S5', '罗秀英', '33010219790322757X', '13025713682'),
         ('A2559', 3, 'SC_DR09_2026-10-09', 'S5', '杨芳', '440103200306266139', '15640875198'),
         ('A2560', 1, 'SC_DR09_2026-10-09', 'S6', '吴杰', '32010219530715713X', '13570246813'),
         ('A2561', 2, 'SC_DR09_2026-10-09', 'S6', '陈明', '110105198302163622', '13086419752'),
         ('A2562', 3, 'SC_DR09_2026-10-09', 'S6', '高静', '330102198204249328', '13925703681'),
         ('A2563', 4, 'SC_DR09_2026-10-09', 'S6', '马强', '310104198705233251', '13960807421'),
         ('A2564', 1, 'SC_DR09_2026-10-09', 'S7', '周敏', '110101196409059214', '18862075190'),
         ('A2565', 2, 'SC_DR09_2026-10-09', 'S7', '郭秀英', '110105197402042057', '17803591465'),
         ('A2566', 3, 'SC_DR09_2026-10-09', 'S7', '张超', '320102197703068293', '17085319748'),
         ('A2567', 4, 'SC_DR09_2026-10-09', 'S7', '周军', '110105198302042636', '17579168023'),
         ('A2568', 5, 'SC_DR09_2026-10-09', 'S7', '何杰', '44010319681125560X', '15862097316'),
         ('A2569', 1, 'SC_DR09_2026-10-09', 'S8', '何秀英', '310104197101097215', '19369157026'),
         ('A2570', 1, 'SC_DR09_2026-10-09', 'S9', '赵伟', '110101198805110279', '18186429758'),
         ('A2571', 1, 'SC_DR09_2026-10-09', 'S10', '朱洋', '310101198803193506', '13207531864'),
         ('A2572', 2, 'SC_DR09_2026-10-09', 'S10', '王丽', '320102198612159944', '15571346927'),
         ('A2573', 3, 'SC_DR09_2026-10-09', 'S10', '朱丽', '110105196810070976', '18530842977'),
         ('A2574', 4, 'SC_DR09_2026-10-09', 'S10', '林伟', '310104199703055134', '19680247913'),
         ('A2575', 5, 'SC_DR09_2026-10-09', 'S10', '王涛', '440103196808195634', '15641953074'),
         ('A2576', 1, 'SC_DR09_2026-10-09', 'S11', '孙涛', '330102197011250141', '15357946800'),
         ('A2577', 2, 'SC_DR09_2026-10-09', 'S11', '陈明', '31010119671014663X', '15752063195'),
         ('A2578', 3, 'SC_DR09_2026-10-09', 'S11', '朱平', '110101196710220708', '15469235812'),
         ('A2579', 4, 'SC_DR09_2026-10-09', 'S11', '郭勇', '320102200506266404', '17539741867'),
         ('A2580', 1, 'SC_DR09_2026-10-09', 'S12', '吴娜', '310101198903194717', '13864297530'),
         ('A2581', 2, 'SC_DR09_2026-10-09', 'S12', '朱霞', '330102195908188224', '13357024691'),
         ('A2582', 1, 'SC_DR09_2026-10-10', 'S1', '胡艳', '310101200007171357', '19085219635'),
         ('A2583', 2, 'SC_DR09_2026-10-10', 'S1', '张洋', '31010419970305617X', '19914780367'),
         ('A2584', 1, 'SC_DR09_2026-10-10', 'S2', '胡芳', '330102198404259571', '13358046915'),
         ('A2585', 2, 'SC_DR09_2026-10-10', 'S2', '高杰', '310101199905111211', '19640852974'),
         ('A2586', 3, 'SC_DR09_2026-10-10', 'S2', '王敏', '330102196109198551', '13802479136'),
         ('A2587', 1, 'SC_DR09_2026-10-10', 'S3', '杨平', '110101198805110260', '18642075314'),
         ('A2588', 2, 'SC_DR09_2026-10-10', 'S3', '何芳', '440103196908072607', '17803579240'),
         ('A2589', 3, 'SC_DR09_2026-10-10', 'S3', '王涛', '310101197712121481', '19530742967'),
         ('A2590', 4, 'SC_DR09_2026-10-10', 'S3', '李磊', '440103199304075472', '18792568145'),
         ('A2591', 5, 'SC_DR09_2026-10-10', 'S3', '胡磊', '320102197812288447', '17297508649'),
         ('A2592', 1, 'SC_DR09_2026-10-10', 'S4', '杨洋', '440103196109074358', '18914680351'),
         ('A2593', 2, 'SC_DR09_2026-10-10', 'S4', '陈霞', '320102198105129054', '17186429758'),
         ('A2594', 3, 'SC_DR09_2026-10-10', 'S4', '赵杰', '11010119731227182X', '17359146021'),
         ('A2595', 4, 'SC_DR09_2026-10-10', 'S4', '朱磊', '110105199707160790', '19317542961'),
         ('A2596', 5, 'SC_DR09_2026-10-10', 'S4', '郭芳', '110101196412269124', '15468057912'),
         ('A2597', 1, 'SC_DR09_2026-10-10', 'S5', '李超', '11010119870205901X', '18751964085'),
         ('A2598', 1, 'SC_DR09_2026-10-10', 'S6', '郭娜', '310104195207033886', '18793568149'),
         ('A2599', 2, 'SC_DR09_2026-10-10', 'S6', '李超', '310104198605223048', '13085212635'),
         ('A2600', 1, 'SC_DR09_2026-10-10', 'S7', '林磊', '330102198301039429', '18785363195'),
         ('A2601', 2, 'SC_DR09_2026-10-10', 'S7', '赵勇', '110105198302042628', '17135724688'),
         ('A2602', 3, 'SC_DR09_2026-10-10', 'S7', '郭军', '320102198603068864', '18751986305'),
         ('A2603', 1, 'SC_DR09_2026-10-10', 'S8', '徐涛', '310104198605103177', '18803591466'),
         ('A2604', 2, 'SC_DR09_2026-10-10', 'S8', '马静', '310101199205030963', '18530842973'),
         ('A2605', 3, 'SC_DR09_2026-10-10', 'S8', '何秀英', '310101199001014902', '18692458134'),
         ('A2606', 4, 'SC_DR09_2026-10-10', 'S8', '林勇', '110101197409060914', '19196308523'),
         ('A2607', 1, 'SC_DR09_2026-10-10', 'S9', '赵娜', '320102195410067351', '17640875198'),
         ('A2608', 1, 'SC_DR09_2026-10-10', 'S10', '张涛', '440103199607275922', '15085319642'),
         ('A2609', 1, 'SC_DR09_2026-10-10', 'S11', '孙霞', '31010119781105267X', '17803591465'),
         ('A2610', 2, 'SC_DR09_2026-10-10', 'S11', '刘平', '320102200506266551', '17862075190'),
         ('A2611', 3, 'SC_DR09_2026-10-10', 'S11', '张强', '320102198612158845', '15136802473'),
         ('A2612', 4, 'SC_DR09_2026-10-10', 'S11', '孙敏', '31010419500614351X', '13196408539'),
         ('A2613', 1, 'SC_DR09_2026-10-10', 'S12', '徐丽', '440305199807285272', '15428653976'),
         ('A2614', 2, 'SC_DR09_2026-10-10', 'S12', '徐明', '110105199604251702', '15803679250'),
         ('A2615', 3, 'SC_DR09_2026-10-10', 'S12', '何艳', '440103200204207007', '15297518644'),
         ('A2616', 1, 'SC_DR09_2026-10-11', 'S1', '张洋', '110101197510222156', '17469135802'),
         ('A2617', 1, 'SC_DR09_2026-10-11', 'S2', '孙强', '44030519550624759X', '17429631856'),
         ('A2618', 2, 'SC_DR09_2026-10-11', 'S2', '林芳', '310101198502054035', '18369157021'),
         ('A2619', 3, 'SC_DR09_2026-10-11', 'S2', '罗军', '330102199304101261', '18197420859'),
         ('A2620', 1, 'SC_DR09_2026-10-11', 'S3', '胡平', '310101198512272984', '18479136802'),
         ('A2621', 2, 'SC_DR09_2026-10-11', 'S3', '胡强', '310104198604224057', '13631974208'),
         ('A2622', 1, 'SC_DR09_2026-10-11', 'S4', '徐敏', '310104197404211986', '19197520863'),
         ('A2623', 1, 'SC_DR09_2026-10-11', 'S5', '刘艳', '310101199104085068', '18369147021'),
         ('A2624', 1, 'SC_DR09_2026-10-11', 'S6', '郭勇', '440103200407276352', '17206431754'),
         ('A2625', 2, 'SC_DR09_2026-10-11', 'S6', '吴超', '320102198412149514', '13681357028'),
         ('A2626', 3, 'SC_DR09_2026-10-11', 'S6', '刘超', '310104198402153828', '13863175200'),
         ('A2627', 4, 'SC_DR09_2026-10-11', 'S6', '刘强', '440305195105106825', '13914680357'),
         ('A2628', 1, 'SC_DR09_2026-10-11', 'S7', '郭芳', '310104199705105019', '19924603577'),
         ('A2629', 2, 'SC_DR09_2026-10-11', 'S7', '吴娜', '110101199003060657', '18208519740'),
         ('A2630', 1, 'SC_DR09_2026-10-11', 'S8', '杨霞', '440305197410227809', '17308686757'),
         ('A2631', 2, 'SC_DR09_2026-10-11', 'S8', '何芳', '110105196901010012', '15357946801'),
         ('A2632', 1, 'SC_DR09_2026-10-11', 'S9', '陈艳', '320102198211149307', '13682457138'),
         ('A2633', 1, 'SC_DR09_2026-10-11', 'S10', '高静', '110101199103220785', '15915780461'),
         ('A2634', 2, 'SC_DR09_2026-10-11', 'S10', '马强', '440103199306264349', '15530864197'),
         ('A2635', 3, 'SC_DR09_2026-10-11', 'S10', '李静', '330102199204249904', '15025757986'),
         ('A2636', 1, 'SC_DR09_2026-10-11', 'S11', '杨霞', '440305197111257186', '15642953084'),
         ('A2637', 2, 'SC_DR09_2026-10-11', 'S11', '马明', '31010419960510481X', '19368047911'),
         ('A2638', 3, 'SC_DR09_2026-10-11', 'S11', '朱洋', '440305197801027468', '17630874193'),
         ('A2639', 4, 'SC_DR09_2026-10-11', 'S11', '高静', '440305199807166345', '19915702687'),
         ('A2640', 1, 'SC_DR09_2026-10-11', 'S12', '马超', '110105199303230086', '15579146807'),
         ('A2641', 1, 'SC_DR09_2026-10-12', 'S1', '吴娜', '440103195911255207', '13753086415'),
         ('A2642', 2, 'SC_DR09_2026-10-12', 'S1', '赵勇', '110101199702210829', '17913680251'),
         ('A2643', 3, 'SC_DR09_2026-10-12', 'S1', '刘平', '320102200506266420', '17207519645'),
         ('A2644', 1, 'SC_DR09_2026-10-12', 'S2', '杨艳', '110101198504258739', '15479158027'),
         ('A2645', 1, 'SC_DR09_2026-10-12', 'S3', '高杰', '320102197101036294', '17852096315'),
         ('A2646', 1, 'SC_DR09_2026-10-12', 'S4', '罗丽', '330102198001178822', '13803579240'),
         ('A2647', 2, 'SC_DR09_2026-10-12', 'S4', '孙丽', '330102195710087989', '17195320643'),
         ('A2648', 3, 'SC_DR09_2026-10-12', 'S4', '黄勇', '330102198903239428', '15024613572'),
         ('A2649', 1, 'SC_DR09_2026-10-12', 'S6', '林平', '110101198803219297', '15024791362'),
         ('A2650', 1, 'SC_DR09_2026-10-12', 'S7', '陈平', '44010319580819395X', '13752064195'),
         ('A2651', 1, 'SC_DR09_2026-10-12', 'S8', '杨军', '11010119651227043X', '15804691573'),
         ('A2652', 1, 'SC_DR09_2026-10-12', 'S9', '郭艳', '31010419830421368X', '13308641975'),
         ('A2653', 2, 'SC_DR09_2026-10-12', 'S9', '徐涛', '440103200203075882', '19914680357'),
         ('A2654', 1, 'SC_DR09_2026-10-12', 'S10', '林艳', '110101198805129332', '18196320749'),
         ('A2655', 1, 'SC_DR09_2026-10-12', 'S12', '黄伟', '310104195109213613', '13075318648'),
         ('A2656', 2, 'SC_DR09_2026-10-12', 'S12', '杨洋', '33010219930219007X', '15468135706'),
         ('A2657', 1, 'SC_DR09_2026-10-13', 'S1', '周军', '110101197111260489', '15468057922'),
         ('A2658', 1, 'SC_DR09_2026-10-13', 'S2', '张涛', '330102200511087461', '17631975208'),
         ('A2659', 1, 'SC_DR09_2026-10-13', 'S4', '李超', '320102196007278460', '18085297412'),
         ('A2660', 2, 'SC_DR09_2026-10-13', 'S4', '何敏', '110101197512282259', '17925703687'),
         ('A2661', 1, 'SC_DR09_2026-10-13', 'S5', '何芳', '310104199402034479', '18791468035'),
         ('A2662', 2, 'SC_DR09_2026-10-13', 'S5', '郭洋', '310101197602172261', '19086419752'),
         ('A2663', 1, 'SC_DR09_2026-10-13', 'S6', '胡强', '330102196508010464', '18318620755'),
         ('A2664', 1, 'SC_DR09_2026-10-13', 'S7', '孙霞', '110105198011243024', '17703569245'),
         ('A2665', 1, 'SC_DR09_2026-10-13', 'S8', '张明', '330102199104089763', '18641875294'),
         ('A2666', 2, 'SC_DR09_2026-10-13', 'S8', '郭秀英', '320102195006147675', '19581346023'),
         ('A2667', 1, 'SC_DR09_2026-10-13', 'S9', '林伟', '110105195207042757', '18368047916'),
         ('A2668', 2, 'SC_DR09_2026-10-13', 'S9', '陈勇', '110101197309051885', '19964285311'),
         ('A2669', 1, 'SC_DR09_2026-10-13', 'S11', '李超', '330102196808039891', '18418630756'),
         ('A2670', 1, 'SC_DR09_2026-10-13', 'S12', '孙霞', '310101198812284442', '18136902589'),
         ('A2671', 1, 'SC_DR09_2026-10-14', 'S1', '王涛', '330102199301030066', '18195308429'),
         ('A2672', 1, 'SC_DR09_2026-10-14', 'S3', '刘超', '310104196608183038', '19864275316'),
         ('A2673', 1, 'SC_DR09_2026-10-14', 'S4', '刘强', '32010219840220847X', '13702481359'),
         ('A2674', 1, 'SC_DR09_2026-10-14', 'S5', '高娟', '110105200407152145', '19560797423'),
         ('A2675', 2, 'SC_DR09_2026-10-14', 'S5', '何秀英', '33010219570817889X', '13460235912'),
         ('A2676', 1, 'SC_DR09_2026-10-14', 'S7', '王杰', '31010119550818446X', '13308641970'),
         ('A2677', 1, 'SC_DR09_2026-10-14', 'S8', '杨艳', '110101195405207377', '13802479136'),
         ('A2678', 1, 'SC_DR09_2026-10-14', 'S9', '杨芳', '440305195606247650', '17296408534'),
         ('A2679', 2, 'SC_DR09_2026-10-14', 'S9', '吴涛', '330102196711240812', '15581369243'),
         ('A2680', 1, 'SC_DR09_2026-10-14', 'S11', '杨勇', '330102198001178857', '13793568149'),
         ('A2681', 2, 'SC_DR09_2026-10-14', 'S11', '高娟', '440305200104015685', '15318575209'),
         ('A2682', 1, 'SC_DR09_2026-10-14', 'S12', '徐静', '310101200005111342', '19207419630'),
         ('A2683', 1, 'SC_DR09_2026-10-15', 'S1', '林芳', '310101195608064596', '18914702581'),
         ('A2684', 2, 'SC_DR09_2026-10-15', 'S1', '高娟', '310104195906144075', '13529741863'),
         ('A2685', 1, 'SC_DR09_2026-10-15', 'S2', '陈平', '310104195909204045', '13529763083'),
         ('A2686', 1, 'SC_DR09_2026-10-15', 'S3', '周杰', '440305197612167103', '13468057916'),
         ('A2687', 1, 'SC_DR09_2026-10-15', 'S5', '马平', '32010219821113915X', '13803579240'),
         ('A2688', 1, 'SC_DR09_2026-10-15', 'S6', '杨芳', '110105200304091968', '19185307428'),
         ('A2689', 1, 'SC_DR09_2026-10-15', 'S8', '陈明', '110101197312111738', '19196420753'),
         ('A2690', 1, 'SC_DR09_2026-10-15', 'S10', '胡伟', '440103196211145714', '18460257136'),
         ('A2691', 1, 'SC_DR09_2026-10-15', 'S11', '陈霞', '330102197903078770', '17863197426'),
         ('A2692', 1, 'SC_DR09_2026-10-16', 'S1', '王杰', '310104195906155188', '13974285317'),
         ('A2693', 1, 'SC_DR09_2026-10-16', 'S2', '何芳', '320102198111138061', '13792468139'),
         ('A2694', 1, 'SC_DR09_2026-10-16', 'S3', '刘霞', '310104196407174880', '15973186207'),
         ('A2695', 1, 'SC_DR09_2026-10-16', 'S6', '王静', '31010419641010498X', '19246835794'),
         ('A2696', 1, 'SC_DR09_2026-10-16', 'S7', '赵娜', '11010520030614199X', '19195320749'),
         ('A2697', 1, 'SC_DR09_2026-10-16', 'S8', '郭秀英', '310104199201025250', '18681357024'),
         ('A2698', 1, 'SC_DR09_2026-10-16', 'S10', '郭军', '44030519510522686X', '17429731866'),
         ('A2699', 1, 'SC_DR09_2026-10-16', 'S12', '周芳', '310104199502165716', '15864275310'),
         ('A2700', 1, 'SC_DR09_2026-10-17', 'S1', '赵勇', '440305200206126001', '19913680913'),
         ('A2701', 1, 'SC_DR09_2026-10-17', 'S2', '罗军', '110101196409050148', '18318620755'),
         ('A2702', 1, 'SC_DR09_2026-10-17', 'S4', '杨芳', '110105196901140052', '18781919632'),
         ('A2703', 1, 'SC_DR09_2026-10-17', 'S5', '吴娟', '310101198103072180', '17913502467'),
         ('A2704', 1, 'SC_DR09_2026-10-17', 'S9', '徐娟', '32010219721113643X', '19136802573'),
         ('A2705', 1, 'SC_DR09_2026-10-17', 'S12', '林芳', '110101197111261545', '15460257132'),
         ('A2706', 1, 'SC_DR09_2026-10-19', 'S1', '王丽', '310104196307045897', '19136902583'),
         ('A2707', 1, 'SC_DR09_2026-10-19', 'S4', '王杰', '320102198502059838', '18208531960'),
         ('A2708', 1, 'SC_DR09_2026-10-19', 'S5', '赵娟', '310101195308054054', '18247035814'),
         ('A2709', 1, 'SC_DR09_2026-10-19', 'S6', '陈平', '320102198603068872', '18317575801'),
         ('A2710', 1, 'SC_DR09_2026-10-19', 'S8', '郭艳', '110105198111093238', '19975386421'),
         ('A2711', 1, 'SC_DR09_2026-10-19', 'S9', '高静', '44030519560612874X', '13247013690'),
         ('A2712', 1, 'SC_DR09_2026-10-19', 'S10', '周涛', '320102195407168450', '13925781467'),
         ('A2713', 1, 'SC_DR09_2026-10-19', 'S11', '徐秀英', '310101197612112262', '19420731866'),
         ('A2714', 1, 'SC_DR09_2026-10-20', 'S1', '张磊', '320102198211139248', '13793568149'),
         ('A2715', 1, 'SC_DR09_2026-10-20', 'S2', '朱磊', '110101200103071527', '19085397425'),
         ('A2716', 1, 'SC_DR09_2026-10-20', 'S3', '赵勇', '310104196207044694', '18913580241'),
         ('A2717', 1, 'SC_DR09_2026-10-20', 'S5', '王丽', '330102198703220159', '15571368247'),
         ('A2718', 2, 'SC_DR09_2026-10-20', 'S5', '马强', '440305197710237304', '17136408539'),
         ('A2719', 1, 'SC_DR09_2026-10-20', 'S6', '徐丽', '110105198506148635', '18207531860'),
         ('A2720', 1, 'SC_DR09_2026-10-20', 'S7', '陈磊', '110105200106011613', '17358046915'),
         ('A2721', 1, 'SC_DR09_2026-10-20', 'S8', '张超', '320102195906269328', '18308619755'),
         ('A2722', 1, 'SC_DR09_2026-10-20', 'S9', '王丽', '110101197309211885', '17793568245'),
         ('A2723', 1, 'SC_DR09_2026-10-20', 'S10', '林芳', '110101196209209820', '15026891578'),
         ('A2724', 1, 'SC_DR09_2026-10-20', 'S12', '高秀英', '11010119661022949X', '15702469135'),
         ('A2725', 1, 'SC_DR10_2026-10-07', 'S1', '李娟', '110105200103072605', '19964285316'),
         ('A2726', 2, 'SC_DR10_2026-10-07', 'S1', '马明', '310101197703051549', '17246835790'),
         ('A2727', 3, 'SC_DR10_2026-10-07', 'S1', '王涛', '110101198504108765', '18318542961'),
         ('A2728', 1, 'SC_DR10_2026-10-07', 'S2', '王静', '440305197410106812', '13681357028'),
         ('A2729', 2, 'SC_DR10_2026-10-07', 'S2', '王杰', '310101200509203304', '13196420759'),
         ('A2730', 3, 'SC_DR10_2026-10-07', 'S2', '吴娜', '32010220040819737X', '19358046921'),
         ('A2731', 4, 'SC_DR10_2026-10-07', 'S2', '黄娜', '31010119530717293X', '13640875194'),
         ('A2732', 1, 'SC_DR10_2026-10-07', 'S3', '高杰', '440103197009205976', '15539742863'),
         ('A2733', 1, 'SC_DR10_2026-10-07', 'S4', '朱伟', '110101199905282267', '17358046318'),
         ('A2734', 1, 'SC_DR10_2026-10-07', 'S5', '黄伟', '440305197512288047', '17319642071'),
         ('A2735', 2, 'SC_DR10_2026-10-07', 'S5', '赵勇', '310104195107032720', '18357024695'),
         ('A2736', 1, 'SC_DR10_2026-10-07', 'S6', '周杰', '440103197212156487', '19802591360'),
         ('A2737', 2, 'SC_DR10_2026-10-07', 'S6', '杨平', '31010419960217592X', '15753164200'),
         ('A2738', 3, 'SC_DR10_2026-10-07', 'S6', '朱平', '320102197612158218', '13358124708'),
         ('A2739', 4, 'SC_DR10_2026-10-07', 'S6', '李超', '44010319600819422X', '13428631752'),
         ('A2740', 1, 'SC_DR10_2026-10-07', 'S7', '徐静', '310101195809203812', '13752986305'),
         ('A2741', 2, 'SC_DR10_2026-10-07', 'S7', '高敏', '110105197211251729', '15692458134'),
         ('A2742', 3, 'SC_DR10_2026-10-07', 'S7', '吴娜', '310104197307177640', '17752064195'),
         ('A2743', 4, 'SC_DR10_2026-10-07', 'S7', '王敏', '31010119530527297X', '18025791462'),
         ('A2744', 5, 'SC_DR10_2026-10-07', 'S7', '李超', '330102195407287427', '17752964189'),
         ('A2745', 1, 'SC_DR10_2026-10-07', 'S8', '高敏', '110105198312263686', '17358124701'),
         ('A2746', 2, 'SC_DR10_2026-10-07', 'S8', '何军', '310101200108181511', '19074218538'),
         ('A2747', 3, 'SC_DR10_2026-10-07', 'S8', '赵勇', '310104198605103126', '18035714688'),
         ('A2748', 1, 'SC_DR10_2026-10-07', 'S9', '郭洋', '110101197109041447', '19086397522'),
         ('A2749', 2, 'SC_DR10_2026-10-07', 'S9', '罗秀英', '11010520030602200X', '17135724683'),
         ('A2750', 3, 'SC_DR10_2026-10-07', 'S9', '高娟', '110105197402160889', '19640875198'),
         ('A2751', 1, 'SC_DR10_2026-10-07', 'S10', '李超', '110101197109040401', '19973186201'),
         ('A2752', 2, 'SC_DR10_2026-10-07', 'S10', '何敏', '31010119860305419X', '18147935809'),
         ('A2753', 1, 'SC_DR10_2026-10-07', 'S11', '黄艳', '310101198612273079', '18358024791'),
         ('A2754', 1, 'SC_DR10_2026-10-07', 'S12', '孙敏', '310104199602175874', '15975386421'),
         ('A2755', 2, 'SC_DR10_2026-10-07', 'S12', '朱霞', '440103197212146430', '19024713582'),
         ('A2756', 3, 'SC_DR10_2026-10-07', 'S12', '陈伟', '440103199206254143', '13296430754'),
         ('A2757', 4, 'SC_DR10_2026-10-07', 'S12', '赵杰', '110105199406021375', '15681379258'),
         ('A2758', 5, 'SC_DR10_2026-10-07', 'S12', '黄平', '310104199504225671', '15086419752'),
         ('A2759', 1, 'SC_DR10_2026-10-08', 'S1', '黄杰', '440305197710118428', '13571346027'),
         ('A2760', 2, 'SC_DR10_2026-10-08', 'S1', '王涛', '31010419800524526X', '15630874198'),
         ('A2761', 1, 'SC_DR10_2026-10-08', 'S2', '何杰', '310101195806143973', '13530742963'),
         ('A2762', 1, 'SC_DR10_2026-10-08', 'S3', '孙超', '440305197610117153', '13791368029'),
         ('A2763', 2, 'SC_DR10_2026-10-08', 'S3', '黄伟', '110101195209123950', '13208631970'),
         ('A2764', 3, 'SC_DR10_2026-10-08', 'S3', '赵杰', '320102195009207717', '19359146021'),
         ('A2765', 4, 'SC_DR10_2026-10-08', 'S3', '李明', '110101199905121252', '19318652971'),
         ('A2766', 1, 'SC_DR10_2026-10-08', 'S4', '朱丽', '440305197901025427', '15208531960'),
         ('A2767', 2, 'SC_DR10_2026-10-08', 'S4', '黄勇', '110105199604250726', '17135702463'),
         ('A2768', 3, 'SC_DR10_2026-10-08', 'S4', '杨伟', '310104197911081768', '19530742967'),
         ('A2769', 4, 'SC_DR10_2026-10-08', 'S4', '林娜', '320102199702146068', '19803579246'),
         ('A2770', 1, 'SC_DR10_2026-10-08', 'S5', '陈勇', '110105200106012608', '17359146025'),
         ('A2771', 2, 'SC_DR10_2026-10-08', 'S5', '郭军', '440103197209216485', '17074286317'),
         ('A2772', 1, 'SC_DR10_2026-10-08', 'S6', '林艳', '110101199805121087', '19085319648'),
         ('A2773', 1, 'SC_DR10_2026-10-08', 'S7', '周杰', '310104195909084071', '18802591360'),
         ('A2774', 2, 'SC_DR10_2026-10-08', 'S7', '徐秀英', '110105198111093190', '19642053198'),
         ('A2775', 3, 'SC_DR10_2026-10-08', 'S7', '周娟', '310104195006023470', '17915780461'),
         ('A2776', 4, 'SC_DR10_2026-10-08', 'S7', '胡洋', '110101198802059164', '18085397428'),
         ('A2777', 1, 'SC_DR10_2026-10-08', 'S8', '赵伟', '110101197309051789', '19753164299'),
         ('A2778', 2, 'SC_DR10_2026-10-08', 'S8', '杨洋', '110105195107042653', '17246935804'),
         ('A2779', 3, 'SC_DR10_2026-10-08', 'S8', '吴静', '310101197602171218', '19318542965'),
         ('A2780', 1, 'SC_DR10_2026-10-08', 'S9', '陈勇', '310101198712284349', '18247013690'),
         ('A2781', 2, 'SC_DR10_2026-10-08', 'S9', '郭军', '110101198905129524', '18084242968'),
         ('A2782', 1, 'SC_DR10_2026-10-08', 'S10', '孙明', '110105197411261972', '17247913680'),
         ('A2783', 1, 'SC_DR10_2026-10-08', 'S11', '高勇', '320102195207278110', '17631942088'),
         ('A2784', 1, 'SC_DR10_2026-10-08', 'S12', '胡平', '310101197812281642', '17913680257'),
         ('A2785', 2, 'SC_DR10_2026-10-08', 'S12', '罗军', '320102195909049291', '18964208531'),
         ('A2786', 3, 'SC_DR10_2026-10-08', 'S12', '黄杰', '440103195811124998', '18359147025'),
         ('A2787', 1, 'SC_DR10_2026-10-09', 'S1', '杨芳', '310104199805235179', '15085219632'),
         ('A2788', 2, 'SC_DR10_2026-10-09', 'S1', '马霞', '440305197710118348', '13925781462'),
         ('A2789', 3, 'SC_DR10_2026-10-09', 'S1', '杨霞', '310101197812122641', '19975386421'),
         ('A2790', 1, 'SC_DR10_2026-10-09', 'S2', '胡芳', '310101199104085041', '18803591705'),
         ('A2791', 1, 'SC_DR10_2026-10-09', 'S3', '李娟', '110105198001153113', '19642975308'),
         ('A2792', 1, 'SC_DR10_2026-10-09', 'S4', '胡平', '110101197209200644', '15924680357'),
         ('A2793', 2, 'SC_DR10_2026-10-09', 'S4', '胡强', '11010519720215170X', '19975308642'),
         ('A2794', 1, 'SC_DR10_2026-10-09', 'S5', '周秀英', '440305195606247650', '17318520645'),
         ('A2795', 2, 'SC_DR10_2026-10-09', 'S5', '孙霞', '310101198603054093', '18792580365'),
         ('A2796', 1, 'SC_DR10_2026-10-09', 'S6', '李磊', '110101197410212022', '17358124701'),
         ('A2797', 2, 'SC_DR10_2026-10-09', 'S6', '胡洋', '110101199106139843', '18530764183'),
         ('A2798', 3, 'SC_DR10_2026-10-09', 'S6', '黄勇', '110101196512279354', '15468157922'),
         ('A2799', 4, 'SC_DR10_2026-10-09', 'S6', '王娟', '320102198603069904', '18308641971'),
         ('A2800', 1, 'SC_DR10_2026-10-09', 'S7', '罗军', '440103199903186502', '15752064199'),
         ('A2801', 1, 'SC_DR10_2026-10-09', 'S8', '杨艳', '320102198406208485', '13680279138'),
         ('A2802', 1, 'SC_DR10_2026-10-09', 'S9', '李超', '440103196710245429', '15741985204'),
         ('A2803', 1, 'SC_DR10_2026-10-09', 'S10', '胡磊', '330102199003080575', '18319742081'),
         ('A2804', 2, 'SC_DR10_2026-10-09', 'S10', '张丽', '440305196610105254', '19358024795'),
         ('A2805', 3, 'SC_DR10_2026-10-09', 'S10', '王超', '330102200404026284', '17852074190'),
         ('A2806', 1, 'SC_DR10_2026-10-09', 'S11', '周涛', '310101195708074791', '18692470358'),
         ('A2807', 2, 'SC_DR10_2026-10-09', 'S11', '郭军', '110101199602050696', '19862074196'),
         ('A2808', 1, 'SC_DR10_2026-10-09', 'S12', '杨伟', '44010319721227634X', '17752096315'),
         ('A2809', 1, 'SC_DR10_2026-10-10', 'S1', '吴秀英', '110105198211103421', '13864175300'),
         ('A2810', 1, 'SC_DR10_2026-10-10', 'S2', '高娜', '440305195505127561', '13792468135'),
         ('A2811', 2, 'SC_DR10_2026-10-10', 'S2', '陈明', '440103199306255354', '15753186429'),
         ('A2812', 1, 'SC_DR10_2026-10-10', 'S3', '高杰', '310104199402164572', '15195308423'),
         ('A2813', 2, 'SC_DR10_2026-10-10', 'S3', '李磊', '440305195007157741', '19570368143'),
         ('A2814', 3, 'SC_DR10_2026-10-10', 'S3', '胡芳', '44010319681125675X', '15863197426'),
         ('A2815', 1, 'SC_DR10_2026-10-10', 'S4', '高敏', '440305195608188690', '13914602577'),
         ('A2816', 1, 'SC_DR10_2026-10-10', 'S5', '孙敏', '320102196310060034', '18429753086'),
         ('A2817', 1, 'SC_DR10_2026-10-10', 'S6', '赵勇', '440103199905125463', '19579268033'),
         ('A2818', 2, 'SC_DR10_2026-10-10', 'S6', '罗杰', '110105199704101947', '19208619750'),
         ('A2819', 1, 'SC_DR10_2026-10-10', 'S7', '林勇', '320102196209068824', '18862097410'),
         ('A2820', 2, 'SC_DR10_2026-10-10', 'S7', '张磊', '310104196006025251', '18703569249'),
         ('A2821', 1, 'SC_DR10_2026-10-10', 'S8', '罗丽', '440103197209087441', '19803579240'),
         ('A2822', 1, 'SC_DR10_2026-10-10', 'S9', '林洋', '110105200404093223', '19863175206'),
         ('A2823', 1, 'SC_DR10_2026-10-10', 'S10', '徐丽', '110105195104102569', '13429731862'),
         ('A2824', 1, 'SC_DR10_2026-10-10', 'S12', '孙静', '33010219890101046X', '18531942083'),
         ('A2825', 2, 'SC_DR10_2026-10-10', 'S12', '吴娟', '310104198404082672', '17802491356'),
         ('A2826', 1, 'SC_DR10_2026-10-12', 'S1', '杨伟', '44030519500422673X', '17429731866'),
         ('A2827', 2, 'SC_DR10_2026-10-12', 'S1', '周涛', '110105198101023164', '17804691576'),
         ('A2828', 1, 'SC_DR10_2026-10-12', 'S3', '郭洋', '310104199402165583', '15197508644'),
         ('A2829', 1, 'SC_DR10_2026-10-12', 'S4', '王敏', '110101197412270883', '17803592466'),
         ('A2830', 1, 'SC_DR10_2026-10-12', 'S5', '张霞', '110101197412120973', '19196420753'),
         ('A2831', 2, 'SC_DR10_2026-10-12', 'S5', '吴涛', '440103197209087417', '19136902573'),
         ('A2832', 1, 'SC_DR10_2026-10-12', 'S7', '高勇', '110101197512122183', '19753186429'),
         ('A2833', 1, 'SC_DR10_2026-10-12', 'S8', '胡平', '110101199502200554', '15246813574'),
         ('A2834', 1, 'SC_DR10_2026-10-12', 'S9', '罗涛', '110105195004102406', '13428630752'),
         ('A2835', 2, 'SC_DR10_2026-10-12', 'S9', '赵娟', '440305197801178522', '13703581469'),
         ('A2836', 1, 'SC_DR10_2026-10-12', 'S10', '周芳', '110101197410062060', '19641952088'),
         ('A2837', 1, 'SC_DR10_2026-10-12', 'S11', '杨军', '440305198901104621', '18036892578'),
         ('A2838', 1, 'SC_DR10_2026-10-12', 'S12', '林艳', '330102196908030069', '18318520645'),
         ('A2839', 1, 'SC_DR10_2026-10-13', 'S2', '高娟', '330102196410079164', '18640875198'),
         ('A2840', 1, 'SC_DR10_2026-10-13', 'S3', '罗秀英', '110101197512271090', '17468057911'),
         ('A2841', 1, 'SC_DR10_2026-10-13', 'S4', '张超', '110105197810082728', '19531942077'),
         ('A2842', 1, 'SC_DR10_2026-10-13', 'S6', '胡洋', '110101197109040401', '19863075290'),
         ('A2843', 2, 'SC_DR10_2026-10-13', 'S6', '何敏', '44010320010613684X', '19803591466'),
         ('A2844', 1, 'SC_DR10_2026-10-13', 'S7', '何芳', '330102196307169065', '15913580246'),
         ('A2845', 1, 'SC_DR10_2026-10-13', 'S9', '王丽', '110105195007033549', '17137924803'),
         ('A2846', 1, 'SC_DR10_2026-10-13', 'S11', '林磊', '320102196009059536', '18420753186'),
         ('A2847', 1, 'SC_DR10_2026-10-13', 'S12', '孙涛', '310104199605104967', '19813592466'),
         ('A2848', 1, 'SC_DR10_2026-10-14', 'S3', '林艳', '110105196901139991', '18863097420'),
         ('A2849', 1, 'SC_DR10_2026-10-14', 'S4', '王丽', '310104198301023645', '17914680356'),
         ('A2850', 1, 'SC_DR10_2026-10-14', 'S5', '朱强', '310101198009133047', '19975286411'),
         ('A2851', 1, 'SC_DR10_2026-10-15', 'S1', '孙超', '33010220010824157X', '17246835794'),
         ('A2852', 1, 'SC_DR10_2026-10-15', 'S2', '林磊', '330102198204099286', '18864207536'),
         ('A2853', 1, 'SC_DR10_2026-10-15', 'S5', '黄勇', '110105199805261077', '17702468139'),
         ('A2854', 1, 'SC_DR10_2026-10-15', 'S6', '高军', '44010319570818479X', '13075396428'),
         ('A2855', 1, 'SC_DR10_2026-10-15', 'S8', '高娟', '310104198905243665', '13963107421'),
         ('A2856', 1, 'SC_DR10_2026-10-15', 'S9', '杨艳', '310101198204072323', '17357046811'),
         ('A2857', 1, 'SC_DR10_2026-10-16', 'S1', '何军', '110105197502171163', '19641975209'),
         ('A2858', 1, 'SC_DR10_2026-10-16', 'S4', '高秀英', '320102195307157113', '13570246913'),
         ('A2859', 1, 'SC_DR10_2026-10-16', 'S5', '马强', '320102195207276983', '17196308523'),
         ('A2860', 1, 'SC_DR10_2026-10-16', 'S6', '周涛', '320102200506137442', '19803679256'),
         ('A2861', 1, 'SC_DR10_2026-10-16', 'S7', '徐敏', '110105197011081251', '18208619755'),
         ('A2862', 1, 'SC_DR10_2026-10-16', 'S9', '杨伟', '440103196312274742', '15529764083'),
         ('A2863', 1, 'SC_DR10_2026-10-16', 'S10', '罗军', '110101199106130822', '18308641971'),
         ('A2864', 1, 'SC_DR10_2026-10-17', 'S1', '刘艳', '330102197901178751', '13470236916'),
         ('A2865', 1, 'SC_DR10_2026-10-17', 'S2', '胡艳', '310101199905111246', '19641853074'),
         ('A2866', 1, 'SC_DR10_2026-10-17', 'S5', '李强', '110101198605269939', '15793581469'),
         ('A2867', 1, 'SC_DR10_2026-10-17', 'S6', '黄娜', '440305196412285055', '15428653972'),
         ('A2868', 1, 'SC_DR10_2026-10-17', 'S8', '刘超', '330102196109049599', '18208519744'),
         ('A2869', 1, 'SC_DR10_2026-10-17', 'S9', '张洋', '310101197612272397', '17358024790'),
         ('A2870', 1, 'SC_DR10_2026-10-17', 'S10', '郭娜', '110101197209201719', '15793565242'),
         ('A2871', 1, 'SC_DR10_2026-10-17', 'S11', '赵芳', '32010219600627947X', '18197408633'),
         ('A2872', 1, 'SC_DR10_2026-10-19', 'S3', '罗丽', '440103200103076829', '19358124701'),
         ('A2873', 1, 'SC_DR10_2026-10-19', 'S4', '赵娜', '310104199505224689', '15206431754'),
         ('A2874', 1, 'SC_DR10_2026-10-19', 'S5', '郭伟', '310104199304084288', '18357946800'),
         ('A2875', 1, 'SC_DR10_2026-10-19', 'S8', '黄芳', '310101195405123189', '13641853074'),
         ('A2876', 1, 'SC_DR10_2026-10-19', 'S9', '罗敏', '330102199001179635', '15802479130'),
         ('A2877', 1, 'SC_DR10_2026-10-19', 'S12', '王强', '110101196612270525', '15914602816'),
         ('A2878', 1, 'SC_DR10_2026-10-20', 'S2', '杨平', '310101195809205017', '13753186425'),
         ('A2879', 1, 'SC_DR10_2026-10-20', 'S3', '周娟', '320102198202199169', '13803591460'),
         ('A2880', 1, 'SC_DR10_2026-10-20', 'S6', '陈明', '330102199101020832', '18318620751'),
         ('A2881', 1, 'SC_DR10_2026-10-20', 'S7', '马平', '440305197510108014', '13469235816'),
         ('A2882', 1, 'SC_DR10_2026-10-20', 'S9', '黄艳', '330102196410229097', '15357946801'),
         ('A2883', 1, 'SC_DR10_2026-10-20', 'S11', '罗涛', '310104197307176584', '17429731862'),
         ('A2884', 1, 'SC_DR10_2026-10-20', 'S12', '赵杰', '110101199003220710', '15026891572')
       ) AS v(id, seq_no, schedule_id, slot_id, patient_name, id_card, phone)
  JOIN schedules      s  ON s.id = v.schedule_id
  JOIN schedule_slots sl ON sl.schedule_id = v.schedule_id AND sl.slot_id = v.slot_id
  JOIN doctors        d  ON d.id = s.doctor_id;

-- ------------------------------------------------------------
-- 12.4 对齐挂号单号序列
--      上面是手工写入固定单号（A1000~），而应用插入时走的是
--      'A' || nextval('appointment_no_seq')。序列若不同步，
--      下一次真实挂号会取到已存在的单号 → 主键冲突。
--      这里把序列推到当前最大单号的数字部分。
-- ------------------------------------------------------------
SELECT setval('appointment_no_seq',
              (SELECT max(substring(id from 2)::bigint) FROM appointments),
              true);

-- ------------------------------------------------------------
-- 12.5 按真实挂号数回填号源占用（幂等，可重复执行）
--
--      这一步是整套设计的核心不变量：
--          schedule_slots.booked  ≡  count(该排班该时段 status=active 的挂号)
--
--      为什么必须回填而不是手写数字？因为一旦有人直接 UPDATE 号源、
--      或用 UPDATE 改挂号状态而没同步号源，两边就会脱节：
--      统计出来的剩余号源是错的，退号会把号源减成负数，
--      极端情况下还会把号卖超。把回填做成一条 SQL，
--      任何时候都能用它把数据重新拉回自洽状态。
-- ------------------------------------------------------------
UPDATE schedule_slots sl
   SET booked = sub.cnt
  FROM (
    SELECT schedule_id, slot_id, COUNT(*)::INT AS cnt
      FROM appointments
     WHERE status = 'active'
     GROUP BY schedule_id, slot_id
  ) sub
 WHERE sl.schedule_id = sub.schedule_id
   AND sl.slot_id = sub.slot_id;

-- 号源为 0 的时段也要归零（上面的 JOIN 覆盖不到没有挂号的时段）
UPDATE schedule_slots sl
   SET booked = 0
 WHERE NOT EXISTS (
   SELECT 1 FROM appointments a
    WHERE a.schedule_id = sl.schedule_id
      AND a.slot_id = sl.slot_id
      AND a.status = 'active'
 );


-- ------------------------------------------------------------
-- 12.6 装载结果自检
--      期望：130 / 1560 / 1885 / 1885，且差值为 0。
--      差值是整套设计的核心不变量，必须为 0。
-- ------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM schedules)                          AS "排班数",
       (SELECT COUNT(*) FROM schedule_slots)                     AS "号源时段数",
       (SELECT COUNT(*) FROM appointments WHERE status='active') AS "有效挂号数",
       (SELECT COALESCE(SUM(booked),0) FROM schedule_slots)      AS "号源已占数",
       (SELECT COUNT(*) FROM appointments WHERE status='active')
       - (SELECT COALESCE(SUM(booked),0) FROM schedule_slots)    AS "差值(应为0)";


-- ============================================================================
--  第 13 组：数据操纵演示（ALTER / INSERT / UPDATE / DELETE）
-- ============================================================================
--
--  目的：完整演示 DDL 与 DML 四类基本操作。
--  安全措施：整组包在 BEGIN ... ROLLBACK 里，
--           跑完之后数据回到原样，不污染正式数据。
--           演示时可以逐条执行，观察每步的输出。
-- ============================================================================

BEGIN;

-- ------------------------------------------------------------
-- 13.1 ALTER TABLE —— 修改表结构：给医生表加一个"简介"字段
--      生产环境加字段要注意：加 NOT NULL 列必须给 DEFAULT，
--      否则已有行没法填值，语句会直接失败。
-- ------------------------------------------------------------
ALTER TABLE doctors ADD COLUMN intro VARCHAR(200);

SELECT column_name AS "新增字段", data_type AS "类型", is_nullable AS "可空"
  FROM information_schema.columns
 WHERE table_name = 'doctors' AND column_name = 'intro';

-- ------------------------------------------------------------
-- 13.2 INSERT —— 插入一条新的后台账号
--      id 用 U09 是为了不撞现有的 U01 / U02。
--      注意 password_hash 给的是"看起来像散列"的占位串：
--      真实口令必须由应用层用 scrypt 派生（server/auth.js 的 hashPassword），
--      手工 INSERT 没法生成 —— 这一点恰好说明"库里不存明文"。
-- ------------------------------------------------------------
INSERT INTO users (id, username, password_hash, display_name, role, status)
VALUES ('U09', 'demo_acct', 'scrypt$placeholder$placeholder', '演示账号', 'staff', 'active');

SELECT id AS "编号", username AS "登录名", display_name AS "显示名", role AS "角色"
  FROM users WHERE id = 'U09';

-- ------------------------------------------------------------
-- 13.3 UPDATE —— 修改数据，顺便证明"约束真的在拦人"
--      13.3.1 合法更新：DR02 是副主任医师，把评分由 4.8 调到 4.9
--      13.3.2 非法更新：把主任医师 DR01 的挂号费从 50 元改成 1 元
--
--      ★ 为什么不能只写 CHECK (fee >= 0)？
--        CHECK 只能看到"新行的值"。1 >= 0 成立，所以 50 改成 1
--        照样能写进去 —— 1 是合法数字，却不是合法价格。
--        真正的业务规则是"挂号费按职称分档"，必须把这条规则
--        如实写成约束（见 doctors 表的 ck_doctor_fee_tier），才拦得住。
--
--      ★ 非法语句为什么放在 DO 块里？
--        它本来就会报错。直接用裸语句会中断脚本，破坏
--        "首次执行 0 错误"这一验收标准；用 DO 块的异常处理器
--        把错误接住并转成 NOTICE，既证明了约束有效，脚本又依然干净。
-- ------------------------------------------------------------
UPDATE doctors SET rating = 4.9 WHERE id = 'DR02';

SELECT id AS "编号", name AS "姓名", rating AS "评分(已上调)"
  FROM doctors WHERE id = 'DR02';

-- 13.3.2a 非法改价：主任医师 50 元 -> 1 元，应被 ck_doctor_fee_tier 拒绝
DO $$
BEGIN
  UPDATE doctors SET fee = 1 WHERE id = 'DR01';
  RAISE NOTICE '【异常】非法改价竟然通过了，约束失效！';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE '【已拦截】非法改价被 ck_doctor_fee_tier 拒绝：%', SQLERRM;
END $$;

-- 13.3.2b 非法改历史快照：挂号单上的 fee 是下单时的价格，不许改
--         CHECK 看不到旧值，判断不了"该不该改"，所以这条规则
--         只能由 BEFORE 触发器 trg_appointment_audit 来守。
DO $$
BEGIN
  UPDATE appointments SET fee = 1
   WHERE id = (SELECT id FROM appointments ORDER BY id LIMIT 1);
  RAISE NOTICE '【异常】历史费用快照竟然被改了，触发器失效！';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE '【已拦截】历史费用快照被 trg_appointment_audit 拒绝：%', SQLERRM;
END $$;

-- 13.3.3 对照：同样是 UPDATE，只改状态不动 fee 就完全正常
DO $$
DECLARE
  v_n INT;
BEGIN
  UPDATE appointments
     SET status = 'cancelled', cancelled_at = NOW(), close_note = '演示用，随后整体回滚'
   WHERE id = (SELECT id FROM appointments WHERE status = 'active' ORDER BY id LIMIT 1);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE '【正常】退号（只改状态、不动 fee）成功，受影响 % 行', v_n;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '【异常】正常退号竟然失败了：%', SQLERRM;
END $$;

-- ------------------------------------------------------------
-- 13.4 DELETE —— 删除数据：删掉刚插入的测试账号
--      刚插入的 U09 没有子记录（没有会话指向它），可以删。
--
--      ★ 反过来说，删除"被别的表引用"的父表行会被外键挡住 ——
--        这正是参照完整性在起作用。例如执行
--            DELETE FROM departments WHERE id = 'D01';
--        会因为 doctors.dept_id 还指向 D01 而失败：
--            ERROR: update or delete on table "departments" violates
--                   foreign key constraint "doctors_dept_id_fkey" on table "doctors"
--        这类语句故意不放在脚本里真跑，否则会破坏
--        "首次执行 0 错误"这一验收标准，答辩时口头演示即可。
-- ------------------------------------------------------------
DELETE FROM users WHERE id = 'U09';

SELECT COUNT(*) AS "U09剩余条数(应为0)" FROM users WHERE id = 'U09';

ROLLBACK;   -- ★ 回滚，撤销上面所有改动

-- 回滚后自检：DR01 的挂号费仍是 50（本来就没让它改成功），
--            DR02 的评分恢复为 4.8，intro 字段应已消失
SELECT id AS "编号", name AS "姓名", fee AS "挂号费(应为50)"
  FROM doctors WHERE id = 'DR01';
SELECT id AS "编号", name AS "姓名", rating AS "评分(应恢复为4.8)"
  FROM doctors WHERE id = 'DR02';


-- ============================================================================
--  第 14 组：对象调用与业务验证
-- ============================================================================
--
--  这一组是"证明数据库对象真的能用"的验证集合，
--  也是写课程设计报告第 4、5 章时的实测依据。
-- ============================================================================

-- ------------------------------------------------------------
-- 14.1 调用标量函数：查 DR01 的剩余号源
--      注意这个值会随挂号/退号变化，不是固定值。
-- ------------------------------------------------------------
SELECT fn_doctor_remain('DR01') AS "DR01 可约号源";

-- ------------------------------------------------------------
-- 14.2 调用表函数：按科室统计今天的挂号情况
--      返回的是"一张表"，可以直接 SELECT * 出来，
--      也可以当普通表继续 JOIN / WHERE / ORDER BY。
-- ------------------------------------------------------------
SELECT * FROM fn_dept_daily_stats(CURRENT_DATE);

-- ------------------------------------------------------------
-- 14.3 调用存储过程：归档过期挂号
--      用 CALL 而不是 SELECT。RAISE NOTICE 的消息
--      会以 NOTICE 级别输出到客户端（psql 里能看到"已归档过期挂号 N 条"）。
--      本数据集的有效挂号都在未来日期，所以正常应输出 0 条。
-- ------------------------------------------------------------
CALL sp_archive_past_appointments();

-- ------------------------------------------------------------
-- 14.4 视图一：排班号源使用情况（看前 5 条）
-- ------------------------------------------------------------
SELECT doctor_id AS "医生", work_date AS "日期",
       total_quota AS "总号源", booked_quota AS "已占", remain_quota AS "剩余"
  FROM v_schedule_usage
 ORDER BY work_date, doctor_id
 LIMIT 5;

-- ------------------------------------------------------------
-- 14.5 视图二：医生工作量排行
-- ------------------------------------------------------------
SELECT doctor_id AS "医生", doctor_name AS "姓名", title AS "职称",
       dept_name AS "科室", active_count AS "挂号量", revenue AS "收入"
  FROM v_doctor_workload
 ORDER BY active_count DESC
 LIMIT 5;

-- ------------------------------------------------------------
-- 14.6 ★ 核心不变量验证：号源已占数 == 有效挂号数
--      这是全系统最重要的自洽性检查。差值必须为 0。
--      只要不为 0，说明号源与挂号记录脱节了，
--      统计会出错、退号可能把号源减成负数。
-- ------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM appointments WHERE status='active')      AS "有效挂号数",
       (SELECT COALESCE(SUM(booked), 0) FROM schedule_slots)          AS "号源已占数",
       (SELECT COUNT(*) FROM appointments WHERE status='active')
       - (SELECT COALESCE(SUM(booked), 0) FROM schedule_slots)        AS "差值(应为0)";

-- ------------------------------------------------------------
-- 14.7 审计日志统计
--      1885 条 INSERT 是第 12 组装载数据时触发器自动写的；
--      条数应当与挂号总数一致（触发器在 INSERT 时逐行触发）。
-- ------------------------------------------------------------
SELECT action AS "动作", COUNT(*) AS "条数"
  FROM appointment_audit
 GROUP BY action
 ORDER BY action;

-- ------------------------------------------------------------
-- 14.8 ★ 触发器验证：事务内退号，观察审计日志是否自动多一条
--      包在事务里最后 ROLLBACK，不污染数据。
-- ------------------------------------------------------------
BEGIN;

-- (1) 退号前：该挂号单的状态
SELECT id AS "挂号单号", status AS "状态(退号前)"
  FROM appointments
 WHERE id = (SELECT MIN(id) FROM appointments WHERE status='active');

-- (2) 执行退号（应用层走的就是这条 UPDATE）
UPDATE appointments
   SET status = 'cancelled',
       cancelled_at = NOW()
 WHERE id = (SELECT MIN(id) FROM appointments WHERE status='active');

-- (3) 触发器应已自动写入一条 UPDATE 类型的审计记录
SELECT appointment_id AS "挂号单号", action AS "动作",
       old_status AS "原状态", new_status AS "新状态",
       changed_by AS "操作者", changed_at AS "时间"
  FROM appointment_audit
 WHERE appointment_id = (SELECT MIN(appointment_id) FROM appointment_audit WHERE action='UPDATE')
 ORDER BY audit_id;

ROLLBACK;


-- ------------------------------------------------------------
-- 14.9 ★ 后台账号与口令散列（登录功能的数据库侧证据）
--      期望：2 个账号；password_hash 一律以 "scrypt$" 开头，
--      且看不到任何明文口令 —— 说明口令是以散列形式存储的。
--      散列长度固定 64 字节（128 个十六进制字符），
--      盐 16 字节（32 个十六进制字符），格式 scrypt$盐$散列。
-- ------------------------------------------------------------
SELECT id AS "编号", username AS "登录名", display_name AS "显示名",
       role AS "角色", status AS "状态",
       left(password_hash, 7) AS "散列算法前缀",
       length(password_hash)  AS "散列串长度",
       position('$' in password_hash) AS "第一个$位置(应为7)"
  FROM users
 ORDER BY id;

-- 口令散列的分段长度自检：盐应 32 字符、散列应 128 字符
SELECT username AS "登录名",
       length(split_part(password_hash, '$', 2)) AS "盐长度(应为32)",
       length(split_part(password_hash, '$', 3)) AS "散列长度(应为128)"
  FROM users
 ORDER BY username;


-- ============================================================================
--  第 15 组：数据库对象清单查询（写报告、答辩截图用）
-- ============================================================================
--
--  这一组全部是"查数据字典"的 SQL：从系统目录表里读出
--  本库建了哪些表、哪些约束、哪些索引、哪些视图/函数/触发器。
--  截图放进报告，比手写清单更有说服力。
-- ============================================================================

-- ------------------------------------------------------------
-- 15.1 数据表清单（表名 / 字段数 / 占用空间）
--      pg_class 是 PostgreSQL 的系统目录表；
--      relkind='r' 表示普通表（'v' 视图、'i' 索引、'S' 序列）。
-- ------------------------------------------------------------
SELECT c.relname AS "表名",
       (SELECT COUNT(*) FROM information_schema.columns col
         WHERE col.table_name = c.relname
           AND col.table_schema = 'public')            AS "字段数",
       pg_size_pretty(pg_total_relation_size(c.oid))    AS "占用空间"
  FROM pg_class c
 WHERE c.relnamespace = 'public'::regnamespace
   AND c.relkind = 'r'
 ORDER BY c.relname;

-- ------------------------------------------------------------
-- 15.2 完整性约束清单（主键 / 外键 / 唯一 / 检查）
--      contype 的取值：p=主键 f=外键 u=唯一 c=检查
-- ------------------------------------------------------------
SELECT t.relname AS "表名",
       c.conname AS "约束名",
       CASE c.contype
         WHEN 'p' THEN '主键'
         WHEN 'f' THEN '外键'
         WHEN 'u' THEN '唯一'
         WHEN 'c' THEN '检查'
       END       AS "类型"
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
 WHERE c.connamespace = 'public'::regnamespace
   AND c.contype IN ('p','f','u','c')
 ORDER BY t.relname, c.contype, c.conname;

-- 15.2.1 约束分类计数（一行看清约束总量）
SELECT CASE c.contype
         WHEN 'p' THEN '主键' WHEN 'f' THEN '外键'
         WHEN 'u' THEN '唯一' WHEN 'c' THEN '检查'
       END      AS "类型",
       COUNT(*) AS "数量"
  FROM pg_constraint c
 WHERE c.connamespace = 'public'::regnamespace
   AND c.contype IN ('p','f','u','c')
 GROUP BY c.contype
 ORDER BY c.contype;

-- ------------------------------------------------------------
-- 15.3 索引清单
--      注意 uq_appt_same_doctor 既是唯一索引也是业务约束，
--      它是用 CREATE UNIQUE INDEX ... WHERE 建的，
--      所以出现在这里而不是 15.2 里。
-- ------------------------------------------------------------
SELECT tablename AS "表名", indexname AS "索引名", indexdef AS "定义"
  FROM pg_indexes
 WHERE schemaname = 'public'
 ORDER BY tablename, indexname;

-- ------------------------------------------------------------
-- 15.4 视图清单
-- ------------------------------------------------------------
SELECT table_name AS "视图名"
  FROM information_schema.views
 WHERE table_schema = 'public'
 ORDER BY table_name;

-- ------------------------------------------------------------
-- 15.5 函数与存储过程清单
--      prokind: f=普通函数 p=存储过程
--      pg_get_function_arguments / pg_get_function_result
--      可以把参数列表和返回类型直接读成文本，省得手写。
-- ------------------------------------------------------------
SELECT p.proname AS "名称",
       CASE p.prokind WHEN 'f' THEN '函数' WHEN 'p' THEN '存储过程' END AS "类型",
       pg_get_function_arguments(p.oid) AS "参数",
       pg_get_function_result(p.oid)    AS "返回"
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   -- 排除 plpgsql 语言自带的内建函数，只留我们自己建的
   AND p.proname IN ('fn_appointment_audit','fn_doctor_remain','fn_dept_daily_stats','sp_archive_past_appointments')
 ORDER BY p.prokind, p.proname;

-- ------------------------------------------------------------
-- 15.6 触发器清单
--      tgisinternal = true 的是系统为外键自动创建的内部触发器，
--      要排除掉，否则会混进一堆外键触发器干扰阅读。
-- ------------------------------------------------------------
SELECT t.tgname AS "触发器名",
       c.relname AS "所在表",
       p.proname AS "触发函数",
       CASE WHEN t.tgtype & 4  = 4  THEN 'INSERT' ELSE '' END ||
       CASE WHEN t.tgtype & 16 = 16 THEN ' UPDATE' ELSE '' END AS "触发事件"
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc  p ON p.oid = t.tgfoid
 WHERE NOT t.tgisinternal
 ORDER BY t.tgname;


-- ============================================================================
--  附录 A：日常排查与运维查询
-- ============================================================================
--
--  这些不是"必须执行"的语句，而是遇到问题时的排查工具箱，
--  也是答辩时被追问"你怎么验证数据没问题"的标准答案。
-- ============================================================================

-- ------------------------------------------------------------
-- A.1 找出"号源占用数与实际挂号数不一致"的时段
--     正常应返回 0 行。一旦有输出，就是数据脱节的精确位置。
--     修法：重新执行第 12.5 组的回填语句。
-- ------------------------------------------------------------
SELECT sl.schedule_id AS "排班", sl.slot_id AS "时段",
       sl.booked AS "记录的已占", actual.cnt AS "实际的已占",
       sl.booked - actual.cnt AS "偏差"
  FROM schedule_slots sl
  JOIN LATERAL (
    SELECT COUNT(*)::INT AS cnt
      FROM appointments a
     WHERE a.schedule_id = sl.schedule_id
       AND a.slot_id = sl.slot_id
       AND a.status = 'active'
  ) actual ON TRUE
 WHERE sl.booked <> actual.cnt
 LIMIT 50;

-- ------------------------------------------------------------
-- A.2 全库超卖扫描：找出 booked > total 的时段
--     正常应返回 0 行。理论上被 ck_slot_not_oversold 约束挡住，
--     跑这条只是"再确认一遍"。
-- ------------------------------------------------------------
SELECT schedule_id AS "排班", slot_id AS "时段",
       total AS "号源总数", booked AS "已占" 
  FROM schedule_slots
 WHERE booked > total;

-- ------------------------------------------------------------
-- A.3 挂号量排行：各科室有效挂号数与收入
-- ------------------------------------------------------------
SELECT dp.id AS "科室编号", dp.name AS "科室",
       COUNT(a.id) AS "挂号量",
       COALESCE(SUM(a.fee), 0) AS "收入"
  FROM departments dp
  LEFT JOIN appointments a
         ON a.dept_id = dp.id AND a.status = 'active'
 GROUP BY dp.id, dp.name
 ORDER BY COUNT(a.id) DESC;

-- ------------------------------------------------------------
-- A.4 挂号量排行：医生 TOP 8
-- ------------------------------------------------------------
SELECT a.doctor_id AS "医生编号", d.name AS "姓名", d.title AS "职称",
       dp.name AS "科室", COUNT(a.id) AS "挂号量",
       COALESCE(SUM(a.fee), 0) AS "收入"
  FROM appointments a
  JOIN doctors d     ON d.id = a.doctor_id
  JOIN departments dp ON dp.id = a.dept_id
 WHERE a.status = 'active'
 GROUP BY a.doctor_id, d.name, d.title, dp.name
 ORDER BY COUNT(a.id) DESC
 LIMIT 8;

-- ------------------------------------------------------------
-- A.5 按午别统计挂号量（对应前端"上午/下午"两个大段的展示口径）
-- ------------------------------------------------------------
SELECT period AS "午别",
       COUNT(*) AS "挂号量",
       COALESCE(SUM(fee), 0) AS "收入"
  FROM appointments
 WHERE status = 'active'
 GROUP BY period
 ORDER BY period;

-- ------------------------------------------------------------
-- A.6 排班利用情况：占用率最高的 20 条排班
--     管理端据此判断哪些医生的号最紧俏、要不要加号。
--     NULLIF(total_quota, 0) 是为了防止除零（总号源为 0 的排班）。
-- ------------------------------------------------------------
SELECT schedule_id AS "排班", doctor_id AS "医生", work_date AS "日期",
       total_quota AS "总号源", booked_quota AS "已占", remain_quota AS "剩余",
       ROUND(booked_quota::NUMERIC / NULLIF(total_quota, 0) * 100, 1) AS "占用率%"
  FROM v_schedule_usage
 WHERE total_quota > 0
 ORDER BY booked_quota::NUMERIC / total_quota DESC, schedule_id
 LIMIT 20;

-- ------------------------------------------------------------
-- A.7 查找疑似重复挂号（同一人同一天同一科室挂了多个号）
--     正常应返回 0 行 —— 被 idx_appt_conflict 挡住了。
-- ------------------------------------------------------------
SELECT id_card AS "身份证", work_date AS "就诊日期", dept_id AS "科室",
       COUNT(*) AS "有效号数"
  FROM appointments
 WHERE status = 'active'
 GROUP BY id_card, work_date, dept_id
HAVING COUNT(*) > 1;

-- ------------------------------------------------------------
-- A.8 按就诊日期统计（每天的挂号量与收入）
-- ------------------------------------------------------------
SELECT work_date AS "就诊日期", weekday AS "星期",
       COUNT(*) AS "挂号量",
       COALESCE(SUM(fee), 0) AS "收入"
  FROM appointments
 WHERE status = 'active'
 GROUP BY work_date, weekday
 ORDER BY work_date;

-- ------------------------------------------------------------
-- A.9 库与表的体积概览
-- ------------------------------------------------------------
SELECT current_database() AS "数据库",
       pg_size_pretty(pg_database_size(current_database())) AS "库大小";

SELECT c.relname AS "表名",
       pg_size_pretty(pg_total_relation_size(c.oid)) AS "总大小(含索引)"
  FROM pg_class c
 WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
 ORDER BY pg_total_relation_size(c.oid) DESC;

-- ------------------------------------------------------------
-- A.10 重新生成排班与号源（当数据被误删、或想换一批日期时）
--      这两句只是"怎么恢复"的提示，不能直接执行 —— 因为
--      批量生成逻辑在 server/init-db.js 里（它要按出诊规则
--      计算每位医生每天是否出诊），纯 SQL 难以表达完整规则。
--      正确做法是在项目目录下执行：
--
--          node server/init-db.js --force
--
--      或者干脆把本文件从头再跑一遍（第 1 组会先清理干净）。
-- ------------------------------------------------------------


-- ============================================================================
--  全部命令结束
-- ============================================================================
--
--  执行完本文件后，数据库应处于如下状态：
--
--      数据库      hospital_registration（UTF8）
--      表          8 张（7 张业务表 + 1 张审计日志表）
--                    departments / doctors / schedules / schedule_slots /
--                    appointments / users / user_sessions / appointment_audit
--      视图        2 个（v_schedule_usage / v_doctor_workload）
--      函数        3 个（2 个业务函数 + 1 个触发器函数）
--      存储过程    1 个（sp_archive_past_appointments）
--      触发器      1 个（trg_appointment_audit）
--      序列        2 个（appointment_no_seq + schedule_slots.id 的隐式序列）
--      索引        28 个
--      业务约束    37 个（8 主键 + 8 外键 + 4 唯一 + 17 检查）
--      数据        5 个科室 / 10 位医生 / 2 个后台账号
--                  130 条排班 / 1560 个号源时段 / 1885 条挂号记录
--
--  挂号费的两道"值"级保护（本设计的一个重点）：
--      doctors.fee      —— ck_doctor_fee_tier（跨列 CHECK）
--                          价格按职称分档：主任医师 50 / 副主任医师 30 / 主治医师 15。
--                          单列 CHECK (fee >= 0) 只能挡负数，挡不住 50 -> 1；
--                          把"价格按职称分档"写成约束才拦得住。
--      appointments.fee —— trg_appointment_audit（BEFORE UPDATE 触发器）
--                          历史价格快照，禁止修改。CHECK 看不到旧值，
--                          判断不了"该不该改"，这类规则只能靠触发器。
--
--  核心不变量（务必为 0）：
--      sum(schedule_slots.booked) − count(appointments where status='active') = 0
--
--  后台账号（明文口令，登录管理后台用）：
--      admin  / admin123    （管理员，可重置数据、调号源、停诊）
--      triage / triage123   （值班员，只能查看与日常值机）
--
--  启动应用验证：
--      在 hospital-registration 目录下执行  npm start
--      浏览器打开  http://127.0.0.1:3000
--
-- ============================================================================
