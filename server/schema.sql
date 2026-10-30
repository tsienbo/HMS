-- ============================================================
-- 智慧医院预约挂号系统 —— 数据库结构（v2）
-- PostgreSQL 12+
--
-- 本版在 v1 的基础上补齐了课程设计要求里的四类对象：
--   约束（主键 / 外键 / 唯一 / CHECK）、索引、视图、触发器。
--
-- 与 v1 的主要差异（v1 见 legacy 备份与 .tmp 里的 pg_dump）：
--   1. 新增 patients 患者表，appointments 用 patient_id 外键引用，
--      不再把姓名 / 身份证 / 手机号三份冗余存在挂号单上；
--   2. 号源列改名：quota_total → max_quota，quota_booked → booked_count；
--      时段列改名：period → time_slot，并补 start_time / end_time；
--   3. 挂号状态从 active / cancelled / closed 三态改为
--      booked / cancelled / completed / no_show 四态；
--   4. 号源增减、状态流转、审计日志全部下沉到触发器，
--      应用层不再手写 UPDATE schedules SET booked_count = ...；
--   5. 新增 4 个视图、9 个函数、14 个触发器。
--
-- 设计说明（为什么仍然没有 hospitals 表）：
--   本系统面向「某一家医院」的挂号业务，医院信息是部署期常量，
--   不存在第二家医院，因此不建 hospitals 表 —— 否则
--   departments.hospital_id / schedules.hospital_id 三列恒为同一个值，
--   UNIQUE(hospital_id, name) 会退化成 UNIQUE(name)，属于典型的「伪 1:N」冗余。
--   医院名称、等级、地址等展示信息放在前端常量 web/js/app.js 的 HOSPITAL 中。
-- ============================================================

-- ------------------------------------------------------------
-- 0. 幂等重建：按依赖倒序清理
--    视图和函数要单独删 —— DROP TABLE ... CASCADE 只会带走触发器本身，
--    函数是独立对象，不会跟着表一起走。
-- ------------------------------------------------------------
DROP VIEW  IF EXISTS v_appointment_public    CASCADE;
DROP VIEW  IF EXISTS v_doctor_workload       CASCADE;
DROP VIEW  IF EXISTS v_appointment_detail    CASCADE;
DROP VIEW  IF EXISTS v_available_schedules   CASCADE;
DROP VIEW  IF EXISTS v_schedule_usage        CASCADE;

DROP TABLE IF EXISTS appointment_log  CASCADE;
DROP TABLE IF EXISTS user_sessions    CASCADE;
DROP TABLE IF EXISTS users            CASCADE;
DROP TABLE IF EXISTS appointments     CASCADE;
DROP TABLE IF EXISTS schedules        CASCADE;
DROP TABLE IF EXISTS patients         CASCADE;
DROP TABLE IF EXISTS doctors          CASCADE;
DROP TABLE IF EXISTS departments      CASCADE;

-- 历史遗留对象（从旧库升级上来时才存在，新库上是空操作）
DROP TABLE IF EXISTS schedule_slots     CASCADE;
DROP TABLE IF EXISTS hospitals          CASCADE;
DROP TABLE IF EXISTS appointment_audit  CASCADE;
DROP FUNCTION IF EXISTS fn_appointment_audit() CASCADE;
DROP SEQUENCE IF EXISTS appointment_no_seq;

-- 触发器函数：先删函数，挂在上面的触发器会随之消失
DROP FUNCTION IF EXISTS fn_touch_updated_at()        CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_insert()      CASCADE;
DROP FUNCTION IF EXISTS fn_appt_after_insert()       CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_update()      CASCADE;
DROP FUNCTION IF EXISTS fn_appt_after_update()       CASCADE;
DROP FUNCTION IF EXISTS fn_schedule_before_update()  CASCADE;
DROP FUNCTION IF EXISTS fn_schedule_before_delete()  CASCADE;
DROP FUNCTION IF EXISTS fn_doctor_before_delete()    CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_delete()      CASCADE;

-- ------------------------------------------------------------
-- 1. 科室
--    只存「会变化的业务事实」：编号、名称、简介。
--    图标（emoji）刻意不进库 —— 它是「怎么画」，不是业务数据：
--    没有查询、约束、统计会用到它，换一套图标还要改库跑迁移，
--    所以放在前端常量 js/utils.js 的 DEPT_ICONS 里，按科室编号取。
-- ------------------------------------------------------------
CREATE TABLE departments (
  id          VARCHAR(8)   PRIMARY KEY,
  name        VARCHAR(50)  NOT NULL,
  description VARCHAR(200) NOT NULL,
  location    VARCHAR(120),               -- 科室在院区内的位置（楼层 / 区域），方便患者找路
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_dept_name UNIQUE (name)
);

-- ------------------------------------------------------------
-- 2. 医生
--    is_active 是「软删除」开关：医生离职不删行，只置 FALSE。
--    原因见文件末尾的删除保护触发器 —— 医生一旦有排班和挂号，
--    物理删除会让历史单据失去归属，所以这里留一个状态位。
--    fee 不写 CHECK (fee >= 0)：单列域约束挡不住「主任医师 50 元被改成 1 元」，
--    1 是合法数字但不是合法价格。真正的规则是「fee 必须等于该职称对应的价目」，
--    写成下面的跨列 CHECK ck_doctor_fee_tier。
-- ------------------------------------------------------------
CREATE TABLE doctors (
  id         VARCHAR(8)   PRIMARY KEY,
  dept_id    VARCHAR(8)   NOT NULL REFERENCES departments(id) ON DELETE RESTRICT,
  name       VARCHAR(50)  NOT NULL,
  title      VARCHAR(20)  NOT NULL,
  fee        NUMERIC(8,2) NOT NULL,
  is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_doctor_title CHECK (title IN ('主任医师','副主任医师','主治医师')),
  -- 价格档位（跨列约束）：挂号费必须与职称匹配。
  -- 主任医师 50 / 副主任医师 30 / 主治医师 15。
  -- 由于 ck_doctor_title 已把 title 限死在三个值上，这条约束同时蕴含了 fee >= 0。
  CONSTRAINT ck_doctor_fee_tier CHECK (
    (title = '主任医师'   AND fee = 50.00) OR
    (title = '副主任医师' AND fee = 30.00) OR
    (title = '主治医师'   AND fee = 15.00)
  ),
  -- 单看 id 它本来就唯一（主键），这里多声明一条的唯一目的，
  -- 是给 appointments 的「医生 + 挂号费」复合外键提供引用目标：
  -- PostgreSQL 要求外键指向的列组合上必须有唯一约束。
  CONSTRAINT uq_doctor_id_fee UNIQUE (id, fee)
);
-- 外键列必须建索引：删科室、改医生编号时，数据库要按 dept_id 反查医生。
CREATE INDEX idx_doctors_dept ON doctors(dept_id);

-- ------------------------------------------------------------
-- 3. 患者
--    v1 把姓名 / 身份证 / 手机号直接抄在每条挂号单上，同一个人的
--    三次挂号就是三份重复数据，改一次手机号要改三行，还可能改漏。
--    拆出独立的患者表后，挂号单只留 patient_id：
--      · 身份证号天然唯一 → uq_patients_id_card，一个人只有一条档案；
--      · 「我的预约」按身份证查，先命中患者再找挂号单；
--      · 手机号 / 身份证的格式 CHECK 只写一遍，不用在两处维护。
--    ★ 为什么不用自增主键：和挂号单号一样，用「P + 毫秒时间戳」拼，
--      16 位定长，并发插入不会撞号，也不需要额外的序列对象。
-- ------------------------------------------------------------
CREATE TABLE patients (
  id         VARCHAR(16) PRIMARY KEY,              -- 'P' + YYMMDDHH24MISSMS
  name       VARCHAR(50) NOT NULL,
  id_card    VARCHAR(18) NOT NULL,
  phone      VARCHAR(11) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_patients_id_card UNIQUE (id_card),
  CONSTRAINT ck_patients_idcard CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_patients_phone  CHECK (phone   ~ '^1[3-9][0-9]{9}$')
);

-- ------------------------------------------------------------
-- 4. 排班（某医生某天某个半天一条：上午 / 下午各一条）
--    time_slot 把「半天」提升为排班键的一部分，于是同一医生同一天
--    可以同时拥有「上午」「下午」两条排班，又能保证同一半天不被重复生成。
--    start_time / end_time 是这段时间的起止，ck_schedule_time_order
--    保证结束晚于开始；它同时也是 v_appointment_detail 里
--    「就诊时间」的展示依据。
--
--    号源直接挂在排班行上（max_quota / booked_count），不再拆成
--    「30 分钟一格的时段表」：患者挂号的最小单位就是上午 / 下午，
--    真正的就诊顺序由到院签到后的现场叫号决定。
-- ------------------------------------------------------------
CREATE TABLE schedules (
  id           VARCHAR(32) PRIMARY KEY,          -- 排班编号 SC_医生编号_日期_AM|PM
  doctor_id    VARCHAR(8)  NOT NULL REFERENCES doctors(id)     ON DELETE RESTRICT,
  dept_id      VARCHAR(8)  NOT NULL REFERENCES departments(id) ON DELETE RESTRICT,
  work_date    DATE        NOT NULL,
  weekday      VARCHAR(8)  NOT NULL,
  time_slot    VARCHAR(8)  NOT NULL,             -- 出诊时段：上午 / 下午（半日一档）
  start_time   TIME        NOT NULL,
  end_time     TIME        NOT NULL,
  room         VARCHAR(24) NOT NULL DEFAULT '',  -- 诊室号（纯展示，成功页告诉患者去几号诊室）
  max_quota    INTEGER     NOT NULL,             -- 该半天的号源总量
  booked_count INTEGER     NOT NULL DEFAULT 0,   -- 已约数（由触发器维护）
  closed       BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- 同一医生、同一天、同一时段只能有一条排班：允许上/下午并存，禁止同日同段重复。
  -- 这条唯一约束的左前缀 (doctor_id, work_date) 正好覆盖「查某医生某天的排班」，
  -- 所以不再单独建 (doctor_id, work_date) 索引 —— 重复建只是白占空间。
  CONSTRAINT uq_schedule_doctor_date_slot UNIQUE (doctor_id, work_date, time_slot),
  -- 同样是给外键当引用目标：appointments 用 (schedule_id, doctor_id)
  -- 整体引用它，从而保证挂号单上的医生一定是这条排班的医生。
  CONSTRAINT uq_schedule_id_doctor UNIQUE (id, doctor_id),

  CONSTRAINT ck_schedule_slot       CHECK (time_slot IN ('上午','下午')),
  CONSTRAINT ck_schedule_time_order CHECK (end_time > start_time),
  CONSTRAINT ck_schedule_max_quota  CHECK (max_quota > 0),
  -- 防超卖的最后一道防线：即便应用层逻辑被绕过、触发器被禁用，
  -- 数据库也会拒绝 booked_count > max_quota 的写入。
  CONSTRAINT ck_schedule_booked_range CHECK (booked_count BETWEEN 0 AND max_quota)
);
-- 按日期查号源（挂号页「今天有哪些号」）
CREATE INDEX idx_schedules_date ON schedules(work_date);
-- 外键列索引：删科室时要按 dept_id 反查排班
CREATE INDEX idx_schedules_dept ON schedules(dept_id);

-- ------------------------------------------------------------
-- 5. 挂号记录
--    seq_no 是「该半天的第几个号」，到院签到后按它叫号。
--    它由 BEFORE INSERT 触发器统一分配（MAX(seq_no) + 1），应用层传什么都无效。
--
--    ★ id（挂号单号）不建序列：由 INSERT 语句拼成
--      'A' + 当前时间的年月日时分秒毫秒（例如 A261014165120986），共 16 位。
--      不用 max(id)+1 是因为并发时两条插入可能取到同一个最大值而撞号；
--      毫秒时间戳每条语句各取各的时间，不会重复。
--
--    ★ 为什么这里不再有 work_date / weekday / time_slot / dept_id：
--      它们都能顺着 schedule_id → schedules → doctors 推出来。
--      存一份就是给「改排班」埋一个不同步的雷。
--      要展示时查 v_appointment_detail 就行。
--
--    ★ doctor_id 看着也冗余（schedule 已经决定了医生），但它必须留：
--      1) 挂号费防篡改的外键 fk_appt_doctor_fee 需要它；
--      2) 配合 fk_appt_schedule 的复合外键，能保证它与排班的医生一致。
-- ------------------------------------------------------------
CREATE TABLE appointments (
  id             VARCHAR(16)  PRIMARY KEY,        -- 'A' + YYMMDDHH24MISSMS
  appointment_no VARCHAR(16)  NOT NULL,           -- 随机预约单号（患者查询用），唯一约束 uq_appt_no 见下
  seq_no         INTEGER      NOT NULL,           -- 该半天的第几个号，由触发器分配
  schedule_id   VARCHAR(32)  NOT NULL,
  doctor_id     VARCHAR(8)   NOT NULL,
  patient_id    VARCHAR(16)  NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
  -- 挂号费「快照」：下单那一刻从 doctors.fee 抄过来，之后就是历史事实。
  -- 它参与收入统计（SUM(fee)），一旦被改，报表数字会跟着错。
  fee           NUMERIC(8,2) NOT NULL,
  status        VARCHAR(12)  NOT NULL DEFAULT 'booked',
  cancel_reason VARCHAR(16),                     -- patient / admin / closure
  close_note    VARCHAR(200),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  cancelled_at  TIMESTAMPTZ,

  CONSTRAINT uq_appt_no UNIQUE (appointment_no),
  CONSTRAINT ck_appt_status CHECK (status IN ('booked','cancelled','completed','no_show')),
  CONSTRAINT ck_appt_cancel_reason CHECK (
    cancel_reason IS NULL OR cancel_reason IN ('patient','admin','closure')
  ),
  -- 取消必须留痕：状态是 cancelled 就一定要有取消时间，反之亦然。
  CONSTRAINT ck_appt_cancel_pair CHECK (
    (status = 'cancelled') = (cancelled_at IS NOT NULL)
  ),
  CONSTRAINT ck_appt_seq CHECK (seq_no > 0),
  CONSTRAINT ck_appt_fee CHECK (fee >= 0),

  -- 复合外键：挂号单上的医生必须就是这条排班的医生。
  -- ON DELETE RESTRICT：排班一旦有挂号记录就删不掉，避免预约凭空消失。
  CONSTRAINT fk_appt_schedule FOREIGN KEY (schedule_id, doctor_id)
    REFERENCES schedules (id, doctor_id) ON DELETE RESTRICT,

  -- 挂号费防篡改：把「接诊医生 + 挂号费」当成一个整体，去引用 doctors 的
  -- (id, fee) 唯一键。价目表被 ck_doctor_fee_tier 锁死在固定三档上，
  -- 所以这条外键等价于「挂号单上的价格必须与该医生的职称相符」。
  -- 哪怕有人绕过接口手写 SQL，也会被数据库拒绝（SQLSTATE 23503）。
  CONSTRAINT fk_appt_doctor_fee FOREIGN KEY (doctor_id, fee)
    REFERENCES doctors (id, fee),

  -- 同一号源下号序不能重复。注意：这条约束意味着「退号后不重排序号」，
  -- 退掉的号就是空号 —— 这是真实医院的做法，也让历史单据的序号保持不变。
  CONSTRAINT uq_appt_schedule_seq UNIQUE (schedule_id, seq_no)
);

-- 患者查「我的预约」：按患者 + 时间倒序翻页
CREATE INDEX idx_appt_patient_created ON appointments(patient_id, created_at DESC);
-- 统计某排班已约 / 已取消人数
CREATE INDEX idx_appt_schedule_status ON appointments(schedule_id, status);
-- 外键列索引：删医生时按 doctor_id 反查挂号单
CREATE INDEX idx_appt_doctor ON appointments(doctor_id);

-- 同一患者不能重复预约同一个号源。
-- ★ 这里用「部分唯一索引」而不是全表唯一约束：只约束仍然有效的单据
--   （booked / completed），取消之后还能重新挂同一个号。
--   若做成全表唯一，一次误取消就永久封死了这个号源。
CREATE UNIQUE INDEX uq_appt_active_slot ON appointments(schedule_id, patient_id)
  WHERE status IN ('booked','completed');

-- ------------------------------------------------------------
-- 6. 后台用户
--    密码不存明文，存 scrypt 派生的 password_hash，格式：
--        scrypt$<salt-hex>$<hash-hex>
--    校验在应用层用 hmac.compare_digest 做定长比较，避免时序侧信道。
-- ------------------------------------------------------------
CREATE TABLE users (
  id            VARCHAR(16)  PRIMARY KEY,
  username      VARCHAR(32)  NOT NULL,
  password_hash VARCHAR(200) NOT NULL,
  display_name  VARCHAR(50)  NOT NULL,
  status        VARCHAR(12)  NOT NULL DEFAULT 'active',
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_users_username UNIQUE (username),
  CONSTRAINT ck_users_username CHECK (username ~ '^[A-Za-z0-9_]{3,32}$'),
  CONSTRAINT ck_users_status   CHECK (status IN ('active','disabled'))
);

-- ------------------------------------------------------------
-- 7. 登录会话（服务端令牌）
--    不用 JWT：令牌落库后可以真正「注销」和「踢下线」——
--    退出登录就是删掉这一行，管理员禁用账号就是按 user_id 删一批。
-- ------------------------------------------------------------
CREATE TABLE user_sessions (
  token      VARCHAR(64) PRIMARY KEY,
  user_id    VARCHAR(16) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT ck_session_expiry CHECK (expires_at > created_at)
);
CREATE INDEX idx_sessions_user    ON user_sessions(user_id);
CREATE INDEX idx_sessions_expires ON user_sessions(expires_at);

-- ------------------------------------------------------------
-- 8. 挂号操作日志（审计表）
--    谁、什么时候、把哪张单子从什么状态改成了什么状态。
--    出纠纷时（「我明明取消了，怎么还记我爽约」）靠它追溯。
--
--    写入完全由触发器完成，应用层没有一句 INSERT —— 这样任何写入路径
--    （接口、psql、导入脚本）都会留下痕迹，绕不过去。
--    操作人从会话变量 app.operator 取，由应用层在事务里 SET LOCAL 设置；
--    没设置时（例如手工跑 SQL）记为 NULL。
-- ------------------------------------------------------------
CREATE TABLE appointment_log (
  id             BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  appointment_id VARCHAR(16) NOT NULL REFERENCES appointments(id) ON DELETE CASCADE,
  action         VARCHAR(16) NOT NULL,           -- insert / cancel / complete / no_show
  old_status     VARCHAR(12),
  new_status     VARCHAR(12),
  operator       VARCHAR(50),
  changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_log_action CHECK (action IN ('insert','cancel','complete','no_show'))
);
CREATE INDEX idx_log_appt ON appointment_log(appointment_id, changed_at DESC);


-- ============================================================
-- 9. 视图
-- ============================================================

-- 9.1 可挂号源：挂号页直接查这个
--     科室 + 医生 + 排班 + 剩余号源，只剩「今天及以后、没停诊、还有余号」的行。
--     remain > 0 的条件写在这里，应用层就不用每次都重复一遍三连判断。
CREATE VIEW v_available_schedules AS
SELECT s.id                          AS schedule_id,
       d.id                          AS dept_id,
       d.name                        AS dept_name,
       doc.id                        AS doctor_id,
       doc.name                      AS doctor_name,
       doc.title                     AS doctor_title,
       doc.fee,
       s.work_date,
       s.weekday,
       s.time_slot,
       s.start_time,
       s.end_time,
       s.max_quota,
       s.booked_count,
       (s.max_quota - s.booked_count) AS remain
  FROM schedules s
  JOIN doctors     doc ON doc.id = s.doctor_id
  JOIN departments d   ON d.id   = s.dept_id
 WHERE s.closed = FALSE
   AND doc.is_active = TRUE
   AND s.work_date >= CURRENT_DATE
   AND s.max_quota - s.booked_count > 0;

-- 9.2 预约详情：预约 + 患者 + 医生 + 科室 + 就诊时间
--     「我的预约」和管理端列表都查它，省得每个接口各写一遍五表 JOIN。
CREATE VIEW v_appointment_detail AS
SELECT a.id,
       a.appointment_no,
       a.seq_no,
       a.status,
       a.fee,
       a.cancel_reason,
       a.close_note,
       a.created_at,
       a.cancelled_at,
       p.id        AS patient_id,
       p.name      AS patient_name,
       p.id_card,
       p.phone,
       doc.id      AS doctor_id,
       doc.name    AS doctor_name,
       doc.title   AS doctor_title,
       d.id        AS dept_id,
       d.name      AS dept_name,
       d.location  AS location,
       s.id        AS schedule_id,
       s.room      AS room,
       s.work_date,
       s.weekday,
       s.time_slot,
       s.start_time,
       s.end_time
  FROM appointments a
  JOIN patients    p   ON p.id   = a.patient_id
  JOIN schedules   s   ON s.id   = a.schedule_id
  JOIN doctors     doc ON doc.id = a.doctor_id
  JOIN departments d   ON d.id   = doc.dept_id;

-- 9.3 医生工作量：按医生 / 日期统计预约、取消、爽约
--     以排班为左表，所以「当天没一个人挂号」的排班也会出现（各计数为 0），
--     报表里不会漏行。
CREATE VIEW v_doctor_workload AS
SELECT doc.id   AS doctor_id,
       doc.name AS doctor_name,
       d.id     AS dept_id,
       d.name   AS dept_name,
       s.work_date,
       COUNT(a.id)                                              AS total_count,
       COUNT(*) FILTER (WHERE a.status = 'booked')              AS booked_count,
       COUNT(*) FILTER (WHERE a.status = 'cancelled')           AS cancelled_count,
       COUNT(*) FILTER (WHERE a.status = 'completed')           AS completed_count,
       COUNT(*) FILTER (WHERE a.status = 'no_show')             AS no_show_count,
       COALESCE(SUM(a.fee) FILTER (
         WHERE a.status IN ('booked','completed')), 0)          AS revenue
  FROM schedules s
  JOIN doctors     doc ON doc.id = s.doctor_id
  JOIN departments d   ON d.id   = s.dept_id
  LEFT JOIN appointments a ON a.schedule_id = s.id
 GROUP BY doc.id, doc.name, d.id, d.name, s.work_date;

-- 9.4 脱敏视图：给前台 / 大屏等不该看到完整身份证与手机号的场景用
--     overlay() 把身份证中间 8 位、手机号中间 4 位替换成星号。
CREATE VIEW v_appointment_public AS
SELECT a.id,
       a.seq_no,
       a.status,
       p.name                                        AS patient_name,
       overlay(p.id_card PLACING '********' FROM 7 FOR 8) AS id_card_masked,
       overlay(p.phone   PLACING '****'     FROM 4 FOR 4) AS phone_masked,
       doc.name                                      AS doctor_name,
       d.name                                        AS dept_name,
       s.work_date,
       s.time_slot,
       a.fee
  FROM appointments a
  JOIN patients    p   ON p.id   = a.patient_id
  JOIN schedules   s   ON s.id   = a.schedule_id
  JOIN doctors     doc ON doc.id = a.doctor_id
  JOIN departments d   ON d.id   = doc.dept_id;


-- ============================================================
-- 10. 触发器函数
--
-- 业务规则为什么写在数据库里：接口可以被绕过（psql、导入脚本、别的服务），
-- 约束和触发器绕不过去。应用层仍然做一遍校验，那是为了给用户友好的提示；
-- 数据库这一层是「就算你绕过我，也写不进坏数据」。
--
-- 业务错误的抛出方式：RAISE EXCEPTION 不带 ERRCODE，默认 SQLSTATE = P0001。
-- 应用层 db.py 把 P0001 的 message 原样回给用户，所以这里写的是给人看的中文。
-- ============================================================

-- 10.1 时间戳维护：任何 UPDATE 都自动刷新 updated_at
--      应用层不用记得改它，也不可能改错。
--      ★ 用 clock_timestamp() 而不是 NOW()：NOW() 返回的是「事务开始的时间」，
--        同一个事务里改两次，第二次拿到的时间跟第一次一模一样，
--        updated_at 看起来就没变。clock_timestamp() 才是真实的墙上时间。
CREATE OR REPLACE FUNCTION fn_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

-- 10.2 预约前校验（BEFORE INSERT）
--      一次把四件事做完：
--        · 排班存在、没停诊、日期没过去；
--        · 号源没满（并且用 FOR UPDATE 锁住这一行，见下面的并发说明）；
--        · 同一患者没有重复预约同一个号源；
--        · 同一患者当天同一科室没有别的有效预约（按业务规则）。
--      最后统一分配 seq_no。
--
--      ★ 并发控制就靠这里的 SELECT ... FOR UPDATE：
--        两个事务同时给同一个排班挂号，第二个会卡在 FOR UPDATE 上等第一个提交，
--        等它拿到锁时读到的 booked_count 已经是加过 1 的值，
--        于是「还有没有号」的判断永远基于最新数据 —— 不会超卖。
--        AFTER INSERT 里的 +1 也在同一个事务内，锁一直持有到提交。
CREATE OR REPLACE FUNCTION fn_appt_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  sc      schedules%ROWTYPE;
  v_next  INTEGER;
BEGIN
  SELECT * INTO sc FROM schedules WHERE id = NEW.schedule_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '排班不存在，请刷新后重试';
  END IF;

  IF sc.closed THEN
    RAISE EXCEPTION '该医生已停诊，无法挂号';
  END IF;

  IF sc.work_date < CURRENT_DATE THEN
    RAISE EXCEPTION '不能预约已过去的日期';
  END IF;

  IF sc.booked_count >= sc.max_quota THEN
    RAISE EXCEPTION '该时段号源已挂完，请选择其他时段';
  END IF;

  -- 同一个号源，同一个人只能有一张有效单（取消之后可以重挂）
  IF EXISTS (SELECT 1 FROM appointments a
              WHERE a.schedule_id = NEW.schedule_id
                AND a.patient_id  = NEW.patient_id
                AND a.status IN ('booked','completed')) THEN
    RAISE EXCEPTION '您已预约该时段，请勿重复挂号';
  END IF;

  -- 同一患者同一天同一科室只能有一个有效号（防止一个人把整科号挂满）
  IF EXISTS (SELECT 1 FROM appointments a
               JOIN schedules s2 ON s2.id = a.schedule_id
               JOIN doctors   d2 ON d2.id = a.doctor_id
              WHERE a.patient_id = NEW.patient_id
                AND a.status = 'booked'
                AND s2.work_date = sc.work_date
                AND d2.dept_id  = sc.dept_id) THEN
    RAISE EXCEPTION '同一就诊人当天在该科室已有有效预约，请勿重复挂号';
  END IF;

  -- 号序：取该排班已有的最大号 + 1。退号留下的空号不回收，
  -- 这样历史单据上的「第几号」永远不变（uq_appt_schedule_seq 也要求如此）。
  SELECT COALESCE(MAX(seq_no), 0) + 1 INTO v_next
    FROM appointments WHERE schedule_id = NEW.schedule_id;
  NEW.seq_no := v_next;

  -- 新建的单据只可能是「待就诊」，不允许直接建成已完成 / 爽约
  IF NEW.status IS DISTINCT FROM 'booked' THEN
    RAISE EXCEPTION '新建挂号单的状态只能是 booked';
  END IF;

  RETURN NEW;
END;
$$;

-- 10.3 预约成功后号源 +1（AFTER INSERT）
--      为什么放在 AFTER 而不是 BEFORE：BEFORE 里改 schedules 属于「顺手改别的表」，
--      一旦后续约束失败（比如唯一索引冲突），这次修改也要跟着回滚，
--      放 AFTER 语义更干净 —— 单据确实写进去了，才动号源。
CREATE OR REPLACE FUNCTION fn_appt_after_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE schedules
     SET booked_count = booked_count + 1
   WHERE id = NEW.schedule_id;

  INSERT INTO appointment_log (appointment_id, action, old_status, new_status, operator)
  VALUES (NEW.id, 'insert', NULL, NEW.status,
          NULLIF(current_setting('app.operator', true), ''));
  RETURN NULL;
END;
$$;

-- 10.4 状态流转校验（BEFORE UPDATE）
--      只允许 booked → cancelled / completed / no_show。
--      禁止 cancelled → booked（退了的号不能「复活」）、
--      禁止 completed → cancelled（看过的病不能反悔成没来）等。
--      同时冻结关键字段：单号、号序、排班、医生、患者、挂号费都不许改。
CREATE OR REPLACE FUNCTION fn_appt_before_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status <> 'booked' THEN
      RAISE EXCEPTION '非法状态流转：% → %（只有待就诊的单据才能变更状态）',
                      OLD.status, NEW.status;
    END IF;
    IF NEW.status NOT IN ('cancelled','completed','no_show') THEN
      RAISE EXCEPTION '非法状态流转：% → %', OLD.status, NEW.status;
    END IF;

    -- 取消时间由数据库统一写，应用层不用（也改不了）手动填
    IF NEW.status = 'cancelled' THEN
      NEW.cancelled_at := COALESCE(NEW.cancelled_at, clock_timestamp());
    ELSE
      NEW.cancelled_at := NULL;
    END IF;
  END IF;

  IF NEW.schedule_id <> OLD.schedule_id
     OR NEW.doctor_id  <> OLD.doctor_id
     OR NEW.patient_id <> OLD.patient_id
     OR NEW.seq_no     <> OLD.seq_no
     OR NEW.fee        <> OLD.fee
     OR NEW.id         <> OLD.id THEN
    RAISE EXCEPTION '挂号单的关键字段（单号/号序/排班/医生/患者/费用）不允许修改';
  END IF;

  RETURN NEW;
END;
$$;

-- 10.5 状态变更后调整号源并写审计（AFTER UPDATE）
--      booked 变成任何终态 → booked_count - 1，把号还回池子；
--      反过来（终态 → booked）被 10.4 挡住，这里的 +1 分支只是兜底。
CREATE OR REPLACE FUNCTION fn_appt_after_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'booked' AND NEW.status <> 'booked' THEN
    UPDATE schedules
       SET booked_count = GREATEST(booked_count - 1, 0)
     WHERE id = NEW.schedule_id;
  ELSIF OLD.status <> 'booked' AND NEW.status = 'booked' THEN
    UPDATE schedules
       SET booked_count = booked_count + 1
     WHERE id = NEW.schedule_id;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO appointment_log (appointment_id, action, old_status, new_status, operator)
    VALUES (NEW.id,
            CASE NEW.status WHEN 'cancelled' THEN 'cancel'
                            WHEN 'completed' THEN 'complete'
                            ELSE 'no_show' END,
            OLD.status, NEW.status,
            NULLIF(current_setting('app.operator', true), ''));
  END IF;
  RETURN NULL;
END;
$$;

-- 10.6 排班修改保护（BEFORE UPDATE）
--      · max_quota 不能改得比已约数还小（否则立即出现「超卖」的坏数据）；
--      · 已经有有效预约的排班，不允许改日期 / 时段 / 医生 ——
--        改了等于把病人挪到另一个时间，患者并不知情。
--        真要调班，先停诊退号，再改。
CREATE OR REPLACE FUNCTION fn_schedule_before_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.max_quota < OLD.booked_count THEN
    RAISE EXCEPTION '号源总数不能小于已预约数（当前已约 % 个）', OLD.booked_count;
  END IF;

  IF (NEW.work_date <> OLD.work_date
      OR NEW.time_slot <> OLD.time_slot
      OR NEW.doctor_id <> OLD.doctor_id)
     AND EXISTS (SELECT 1 FROM appointments a
                  WHERE a.schedule_id = OLD.id
                    AND a.status IN ('booked','completed')) THEN
    RAISE EXCEPTION '该排班已有预约，不能修改日期、时段或医生；请先停诊退号';
  END IF;

  RETURN NEW;
END;
$$;

-- 10.7 排班删除保护（BEFORE DELETE）
--      外键 ON DELETE RESTRICT 已经能挡住，这里补一句人话提示。
CREATE OR REPLACE FUNCTION fn_schedule_before_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM appointments a
              WHERE a.schedule_id = OLD.id
                AND a.status IN ('booked','completed')) THEN
    RAISE EXCEPTION '该排班仍有有效预约，不能删除；如需停诊请用「停诊」功能';
  END IF;
  IF EXISTS (SELECT 1 FROM appointments WHERE schedule_id = OLD.id) THEN
    RAISE EXCEPTION '该排班存在历史挂号记录，不能删除（保留以备追溯）';
  END IF;
  RETURN OLD;
END;
$$;

-- 10.8 医生删除保护（BEFORE DELETE）
--      医生一旦有排班就删不掉，提示改用 is_active 软删除。
CREATE OR REPLACE FUNCTION fn_doctor_before_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM schedules WHERE doctor_id = OLD.id) THEN
    RAISE EXCEPTION '医生 % 仍有排班记录，不能删除；离职请把 is_active 置为 FALSE', OLD.name;
  END IF;
  RETURN OLD;
END;
$$;

-- 10.9 挂号单删除时回收号源（BEFORE DELETE）
--      本系统的规范做法是「软删除」——退号只改 status，不删行。
--      但既然物理删除这条路没被堵死（DBA 手工清理、导入脚本回滚都会用），
--      就得保证它也不会把号源计数搞乱。
CREATE OR REPLACE FUNCTION fn_appt_before_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'booked' THEN
    UPDATE schedules
       SET booked_count = GREATEST(booked_count - 1, 0)
     WHERE id = OLD.schedule_id;
  END IF;
  RETURN OLD;
END;
$$;


-- ============================================================
-- 11. 触发器挂载
-- ============================================================

-- 11.1 updated_at 自动维护（每张有该列的表一个）
CREATE TRIGGER trg_dept_touch      BEFORE UPDATE ON departments FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_doctor_touch    BEFORE UPDATE ON doctors     FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_patient_touch   BEFORE UPDATE ON patients    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_schedule_touch  BEFORE UPDATE ON schedules   FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_appt_touch      BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_users_touch     BEFORE UPDATE ON users       FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();

-- 11.2 挂号单：插入前校验、插入后加号源、更新前校验流转、更新后减号源
CREATE TRIGGER trg_appt_before_insert BEFORE INSERT ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_before_insert();
CREATE TRIGGER trg_appt_after_insert  AFTER  INSERT ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_after_insert();
CREATE TRIGGER trg_appt_before_update BEFORE UPDATE ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_before_update();
CREATE TRIGGER trg_appt_after_update  AFTER  UPDATE ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_after_update();
CREATE TRIGGER trg_appt_before_delete BEFORE DELETE ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_before_delete();

-- 11.3 删除 / 改排班的保护
CREATE TRIGGER trg_schedule_before_update BEFORE UPDATE ON schedules
  FOR EACH ROW EXECUTE FUNCTION fn_schedule_before_update();
CREATE TRIGGER trg_schedule_before_delete BEFORE DELETE ON schedules
  FOR EACH ROW EXECUTE FUNCTION fn_schedule_before_delete();
CREATE TRIGGER trg_doctor_before_delete   BEFORE DELETE ON doctors
  FOR EACH ROW EXECUTE FUNCTION fn_doctor_before_delete();


-- ============================================================
-- 12. 设计说明（答辩时最容易被追问的几点）
--
--   一、号源为什么由触发器维护，而不是应用层 UPDATE
--      v1 的做法是在接口里写一条带条件的 UPDATE：
--          UPDATE schedules SET booked_count = booked_count + 1
--           WHERE id = ? AND booked_count < max_quota
--      它确实不会超卖，但只保护「这一个接口」。psql 手工插一条、
--      以后新加的批量导入脚本，都能绕过去。
--      改成触发器后，任何 INSERT 都要先过 fn_appt_before_insert 的校验
--      和 FOR UPDATE 行锁，写不进去坏数据。
--      代价：触发器里的逻辑不好调试，报错信息要自己写清楚（上面都写了中文）。
--
--   二、为什么退号后不重排 seq_no
--      v1 退号时会把后面人的号序整体前移一位，避免出现空号。
--      本版加了 uq_appt_schedule_seq（同一排班号序唯一），
--      重排会在「3 号改成 2 号」的瞬间撞上还存在的 2 号，
--      除非把已取消单据的 seq_no 置空 —— 那又破坏了「历史单据可追溯」。
--      真实医院的做法本来就是留空号：退掉的 2 号就是 2 号，不再发出去。
--
--   三、视图会不会又变成「没人调用」的摆设
--      v1 删掉过一批视图，理由是没有任何查询用过它们。
--      本版四个视图都有真实调用方：
--        v_available_schedules —— /api/departments/<id>/doctors 的余号统计
--        v_appointment_detail  —— /api/appointments 系列（列表 / 详情 / 新建后回显）
--        v_doctor_workload     —— /api/stats/doctors（管理端报表接口）
--        v_appointment_public  —— 脱敏场景（前台 / 大屏）备用
--
--   四、并发到底靠什么保证不超卖
--      三道防线，从软到硬：
--        1) 触发器里的 SELECT ... FOR UPDATE：把「判断还有没有号」和
--           「占用这个号」放进同一个事务，后来的请求排队等锁；
--        2) ck_schedule_booked_range：booked_count 不可能大于 max_quota；
--        3) uq_appt_active_slot：同一个人不可能对同一个号源留下两张有效单。
--      注意：应用层的号源更新已经全部删除，如果保留会和触发器重复计数。
-- ============================================================
