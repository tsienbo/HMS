-- ============================================================================
--  智慧医院预约挂号系统（HMS）—— 数据库完整脚本
--  PostgreSQL 14 及以上（开发与验证环境：PostgreSQL 18）
-- ============================================================================
--
--  用途
--    从零建出与系统运行库完全一致的数据库：16 张表、5 个视图、16 个函数、
--    20 个触发器、全部约束与索引，并装入基础数据（科室、医生、后台账号、
--    未来 14 天的排班）。执行完即可启动应用。
--
--  执行方式（在命令行，以超级用户身份）
--    psql -U postgres -f 04_数据库脚本.sql
--
--  脚本结构
--    第 0 部分  建库并连接
--    第 1 部分  清理旧对象（可重复执行）
--    第 2 部分  数据表（含约束与索引）
--               2.1 基础数据    departments / doctors / schedules
--               2.2 业务数据    patients / appointments / waitlist
--               2.3 后台与安全  users / user_sessions / patient_sessions /
--                               citizen_registry / identity_verify_log /
--                               verification_codes / blacklist
--               2.4 审计与通知  appointment_log / access_log / notification_outbox
--    第 3 部分  视图
--    第 4 部分  函数（触发器函数 14 个 + 普通函数 2 个）
--    第 5 部分  触发器
--    第 6 部分  基础数据装载
--    第 7 部分  检查与验证
--
--  设计原则
--    能在数据库里表达的业务规则，就写进数据库：号源增减、号序分配、状态流转、
--    防超卖、限挂、候补补位、实名校验都由约束、触发器和函数完成。应用层仍做
--    一遍校验，那是为了给用户即时、友好的提示；数据库这一层保证「绕过接口
--    直接写库，也写不进不合规的数据」。
--
--  业务错误的抛出方式
--    触发器中的 RAISE EXCEPTION 不指定 ERRCODE，默认 SQLSTATE = P0001；
--    应用层把 P0001 的消息原样返回给用户，所以错误信息都写成中文。
-- ============================================================================


-- ============================================================================
--  第 0 部分  建库并连接
-- ============================================================================

-- 库不存在才创建（CREATE DATABASE 不能放进事务或 DO 块，用 \gexec 实现条件执行）。
-- 指定 template0 才能显式设置编码；UTF8 保证中文正确存储。
SELECT 'CREATE DATABASE hospital_registration WITH ENCODING = ''UTF8'' TEMPLATE = template0'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'hospital_registration')
\gexec

\c hospital_registration

SET client_encoding = 'UTF8';
SET timezone = 'Asia/Shanghai';
-- 首次执行时「对象不存在，跳过」之类的提示没有意义，只显示警告及以上
SET client_min_messages = warning;


-- ============================================================================
--  第 1 部分  清理旧对象
--  按依赖倒序删除，保证脚本可以重复执行。
--  视图和函数是独立对象，DROP TABLE ... CASCADE 不会带走它们，需要单独删。
-- ============================================================================

DROP VIEW IF EXISTS v_waitlist_detail      CASCADE;
DROP VIEW IF EXISTS v_appointment_public   CASCADE;
DROP VIEW IF EXISTS v_doctor_workload      CASCADE;
DROP VIEW IF EXISTS v_appointment_detail   CASCADE;
DROP VIEW IF EXISTS v_available_schedules  CASCADE;

DROP TABLE IF EXISTS identity_verify_log  CASCADE;
DROP TABLE IF EXISTS citizen_registry     CASCADE;
DROP TABLE IF EXISTS patient_sessions     CASCADE;
DROP TABLE IF EXISTS verification_codes   CASCADE;
DROP TABLE IF EXISTS notification_outbox  CASCADE;
DROP TABLE IF EXISTS access_log           CASCADE;
DROP TABLE IF EXISTS blacklist            CASCADE;
DROP TABLE IF EXISTS waitlist             CASCADE;
DROP TABLE IF EXISTS appointment_log      CASCADE;
DROP TABLE IF EXISTS user_sessions        CASCADE;
DROP TABLE IF EXISTS users                CASCADE;
DROP TABLE IF EXISTS appointments         CASCADE;
DROP TABLE IF EXISTS schedules            CASCADE;
DROP TABLE IF EXISTS patients             CASCADE;
DROP TABLE IF EXISTS doctors              CASCADE;
DROP TABLE IF EXISTS departments          CASCADE;

DROP FUNCTION IF EXISTS fn_touch_updated_at()          CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_insert()        CASCADE;
DROP FUNCTION IF EXISTS fn_appt_guard_before_insert()  CASCADE;
DROP FUNCTION IF EXISTS fn_appt_after_insert()         CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_update()        CASCADE;
DROP FUNCTION IF EXISTS fn_appt_after_update()         CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_delete()        CASCADE;
DROP FUNCTION IF EXISTS fn_appt_promote_waitlist()     CASCADE;
DROP FUNCTION IF EXISTS fn_appt_close_waitlist()       CASCADE;
DROP FUNCTION IF EXISTS fn_schedule_before_update()    CASCADE;
DROP FUNCTION IF EXISTS fn_schedule_before_delete()    CASCADE;
DROP FUNCTION IF EXISTS fn_doctor_before_delete()      CASCADE;
DROP FUNCTION IF EXISTS fn_waitlist_before_insert()    CASCADE;
DROP FUNCTION IF EXISTS fn_waitlist_before_update()    CASCADE;
DROP FUNCTION IF EXISTS fn_offer_next_waitlist(VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS fn_verify_identity(TEXT, TEXT, TEXT, TEXT) CASCADE;


-- ============================================================================
--  第 2 部分  数据表
-- ============================================================================

-- ----------------------------------------------------------------------------
--  2.1 基础数据
-- ----------------------------------------------------------------------------

-- 科室
--   单院区部署：医院是部署期常量，不建 hospitals 表。否则各表的 hospital_id
--   恒为同一个值，「同院科室不重名」也会退化成「科室不重名」，属于冗余设计。
--   location 是科室在院内的位置（楼层 / 区域），挂号成功页据此告诉患者去哪。
CREATE TABLE departments (
  id          VARCHAR(8)   PRIMARY KEY,
  name        VARCHAR(50)  NOT NULL,
  description VARCHAR(200) NOT NULL,
  location    VARCHAR(120),
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_dept_name     UNIQUE (name),
  CONSTRAINT ck_dept_location CHECK (location IS NOT NULL AND length(btrim(location)) >= 2)
);

-- 医生
--   is_active 是软删除开关：医生离职不删行，只置 FALSE，历史挂号单仍有归属。
--   挂号费不用 CHECK (fee >= 0)：单列约束挡不住「主任医师 50 元被改成 1 元」，
--   真实规则是「挂号费必须与职称匹配」，写成跨列约束 ck_doctor_fee_tier。
--   ck_doctor_title 已把职称限定为三个取值，因此该约束同时蕴含 fee >= 0。
CREATE TABLE doctors (
  id         VARCHAR(8)   PRIMARY KEY,
  dept_id    VARCHAR(8)   NOT NULL REFERENCES departments(id) ON DELETE RESTRICT,
  name       VARCHAR(50)  NOT NULL,
  title      VARCHAR(20)  NOT NULL,
  fee        NUMERIC(8,2) NOT NULL,
  is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_doctor_title    CHECK (title IN ('主任医师','副主任医师','主治医师')),
  -- 价格档位：主任医师 50 / 副主任医师 30 / 主治医师 15
  CONSTRAINT ck_doctor_fee_tier CHECK (
    (title = '主任医师'   AND fee = 50.00) OR
    (title = '副主任医师' AND fee = 30.00) OR
    (title = '主治医师'   AND fee = 15.00)
  ),
  -- id 本身已唯一；这条约束是给挂号单的复合外键 (doctor_id, fee) 提供引用目标，
  -- PostgreSQL 要求被引用的列组合上必须存在唯一约束。
  CONSTRAINT uq_doctor_id_fee UNIQUE (id, fee)
);
-- 外键列索引：按科室列出医生、删除科室时反查医生
CREATE INDEX idx_doctors_dept ON doctors(dept_id);

-- 排班：一行 = 某医生某天某个半天（上午 / 下午）
--   号源直接挂在排班行上（max_quota 总量 / booked_count 已约数）。患者挂号的
--   最小单位就是半天，具体就诊顺序由到院后的现场叫号决定，因此不再细分时段表。
--   booked_count 只由触发器维护，应用层不直接修改。
CREATE TABLE schedules (
  id           VARCHAR(32) PRIMARY KEY,           -- SC_医生编号_日期_AM|PM
  doctor_id    VARCHAR(8)  NOT NULL REFERENCES doctors(id)     ON DELETE RESTRICT,
  dept_id      VARCHAR(8)  NOT NULL REFERENCES departments(id) ON DELETE RESTRICT,
  work_date    DATE        NOT NULL,
  weekday      VARCHAR(8)  NOT NULL,
  time_slot    VARCHAR(8)  NOT NULL,              -- 上午 / 下午
  start_time   TIME        NOT NULL,
  end_time     TIME        NOT NULL,
  room         VARCHAR(24) NOT NULL DEFAULT '',   -- 诊室号，成功页展示用
  max_quota    INTEGER     NOT NULL,              -- 该半天的号源总量
  booked_count INTEGER     NOT NULL DEFAULT 0,    -- 已约数（触发器维护）
  closed       BOOLEAN     NOT NULL DEFAULT FALSE,-- 是否停诊
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- 同一医生同一天同一半天只有一条排班；左前缀 (doctor_id, work_date)
  -- 同时覆盖「查某医生某天的排班」，无需再单独建索引。
  CONSTRAINT uq_schedule_doctor_date_slot UNIQUE (doctor_id, work_date, time_slot),
  -- 复合外键引用目标：保证挂号单上的医生就是这条排班的医生
  CONSTRAINT uq_schedule_id_doctor        UNIQUE (id, doctor_id),
  CONSTRAINT ck_schedule_slot         CHECK (time_slot IN ('上午','下午')),
  CONSTRAINT ck_schedule_time_order   CHECK (end_time > start_time),
  CONSTRAINT ck_schedule_max_quota    CHECK (max_quota > 0),
  -- 防超卖的最后一道防线：即使触发器被禁用，也写不进超卖数据
  CONSTRAINT ck_schedule_booked_range CHECK (booked_count BETWEEN 0 AND max_quota)
);
CREATE INDEX idx_schedules_date ON schedules(work_date);   -- 按日期查号源
CREATE INDEX idx_schedules_dept ON schedules(dept_id);     -- 外键列：删除科室时反查

-- ----------------------------------------------------------------------------
--  2.2 业务数据
-- ----------------------------------------------------------------------------

-- 就诊人（患者档案）
--   一人一档，身份证号唯一；挂号单只引用 patient_id，修改手机号只改一处。
--   主键用「P + 毫秒时间戳」拼成，16 位定长，并发插入不撞号，也无需序列。
--   email 选填，填了才能收到就诊提醒邮件。
CREATE TABLE patients (
  id         VARCHAR(16)  PRIMARY KEY,             -- 'P' + YYMMDDHH24MISSMS
  name       VARCHAR(50)  NOT NULL,
  id_card    VARCHAR(18)  NOT NULL,
  phone      VARCHAR(11)  NOT NULL,
  email      VARCHAR(120),
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_patients_id_card UNIQUE (id_card),
  CONSTRAINT ck_patients_idcard  CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_patients_phone   CHECK (phone   ~ '^1[3-9][0-9]{9}$'),
  CONSTRAINT ck_patients_email   CHECK (email IS NULL OR email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);
-- 身份证末位 x / X 视为同一号码：表达式唯一索引，防止绕过应用层写入重复档案
CREATE UNIQUE INDEX idx_patients_id_card_ci ON patients (UPPER(id_card));

-- 挂号单
--   id             'A' + 毫秒时间戳，内部主键
--   appointment_no 10 位随机预约单号，供患者凭单号查询（不可枚举）
--   seq_no         该半天的第几个号，由触发器分配，到院按它叫号
--   fee            下单时刻的挂号费快照，参与收入统计，不允许事后修改
--   就诊日期、时段、科室都能经 schedule_id 推出，不在挂号单上冗余存储，
--   展示时查视图 v_appointment_detail。doctor_id 必须保留：
--   它是两条复合外键（排班一致性、挂号费防篡改）的组成部分。
CREATE TABLE appointments (
  id             VARCHAR(16)  PRIMARY KEY,
  appointment_no VARCHAR(16)  NOT NULL,
  seq_no         INTEGER      NOT NULL,
  schedule_id    VARCHAR(32)  NOT NULL,
  doctor_id      VARCHAR(8)   NOT NULL,
  patient_id     VARCHAR(16)  NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
  fee            NUMERIC(8,2) NOT NULL,
  status         VARCHAR(12)  NOT NULL DEFAULT 'booked',
  cancel_reason  VARCHAR(16),                      -- patient / admin / closure
  close_note     VARCHAR(200),
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  cancelled_at   TIMESTAMPTZ,
  CONSTRAINT uq_appt_no             UNIQUE (appointment_no),
  -- 同一排班内号序唯一；退号留空号、不重排，历史单据上的号序永远不变
  CONSTRAINT uq_appt_schedule_seq   UNIQUE (schedule_id, seq_no),
  CONSTRAINT ck_appt_status         CHECK (status IN ('booked','cancelled','completed','no_show')),
  CONSTRAINT ck_appt_cancel_reason  CHECK (cancel_reason IS NULL OR cancel_reason IN ('patient','admin','closure')),
  -- 取消必须留痕：状态为 cancelled 当且仅当有取消时间
  CONSTRAINT ck_appt_cancel_pair    CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
  CONSTRAINT ck_appt_seq            CHECK (seq_no > 0),
  CONSTRAINT ck_appt_fee            CHECK (fee >= 0),
  -- 挂号单上的医生必须就是这条排班的医生
  CONSTRAINT fk_appt_schedule   FOREIGN KEY (schedule_id, doctor_id)
    REFERENCES schedules (id, doctor_id) ON DELETE RESTRICT,
  -- 挂号费防篡改：(医生, 挂号费) 必须是价目表中真实存在的一对。
  -- 价目表被 ck_doctor_fee_tier 锁定，因此「一元挂号单」会被直接拒绝（SQLSTATE 23503）。
  CONSTRAINT fk_appt_doctor_fee FOREIGN KEY (doctor_id, fee)
    REFERENCES doctors (id, fee)
);
CREATE INDEX idx_appt_patient_created ON appointments(patient_id, created_at DESC); -- 我的预约
CREATE INDEX idx_appt_schedule_status ON appointments(schedule_id, status);         -- 按排班统计
CREATE INDEX idx_appt_doctor          ON appointments(doctor_id);                   -- 外键列
-- 部分唯一索引：同一患者对同一号源只能有一张有效单（待就诊 / 已完成）；
-- 取消后可以重新预约。若做成全表唯一，一次误取消就会永久封死这个号源。
CREATE UNIQUE INDEX uq_appt_active_slot ON appointments(schedule_id, patient_id)
  WHERE status IN ('booked','completed');

-- 候补队列
--   号源已满时排队；有人退号，触发器把号保留给队首并发通知，保留 2 小时。
--   position 由触发器在锁住排班行后串行分配，比按时间戳排序更确定。
CREATE TABLE waitlist (
  id                       VARCHAR(16) PRIMARY KEY,           -- 'W' + YYMMDDHH24MISSMS
  schedule_id              VARCHAR(32) NOT NULL REFERENCES schedules(id) ON DELETE RESTRICT,
  patient_id               VARCHAR(16) NOT NULL REFERENCES patients(id)  ON DELETE RESTRICT,
  position                 INTEGER     NOT NULL,
  status                   VARCHAR(12) NOT NULL DEFAULT 'waiting',
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  offered_at               TIMESTAMPTZ,                       -- 通知时间
  offer_expires_at         TIMESTAMPTZ,                       -- 保留截止时间
  converted_appointment_id VARCHAR(16) REFERENCES appointments(id) ON DELETE SET NULL,
  CONSTRAINT ck_waitlist_status CHECK (status IN ('waiting','offered','converted','expired','cancelled')),
  -- 状态与通知时间自洽：排队中一定未通知；已通知 / 已转正 / 已过期一定通知过；
  -- 已取消两种情况都可能（排队中放弃或通知后放弃）
  CONSTRAINT ck_waitlist_offer_pair CHECK (
    CASE
      WHEN status = 'waiting' THEN offered_at IS NULL
      WHEN status IN ('offered','converted','expired') THEN offered_at IS NOT NULL
      ELSE TRUE
    END
  ),
  CONSTRAINT ck_waitlist_offer_window CHECK (offer_expires_at IS NULL OR offered_at IS NULL OR offer_expires_at > offered_at),
  CONSTRAINT ck_waitlist_position     CHECK (position > 0),
  CONSTRAINT uq_waitlist_schedule_pos UNIQUE (schedule_id, position)
);
-- 同一患者对同一排班只能有一条进行中的候补；转正、过期、取消后可以重新排
CREATE UNIQUE INDEX uq_waitlist_active ON waitlist(schedule_id, patient_id)
  WHERE status IN ('waiting','offered');
CREATE INDEX idx_waitlist_queue   ON waitlist(schedule_id, status, position);  -- 补位取队首
CREATE INDEX idx_waitlist_patient ON waitlist(patient_id, created_at DESC);    -- 我的候补

-- ----------------------------------------------------------------------------
--  2.3 后台与安全
-- ----------------------------------------------------------------------------

-- 后台用户
--   口令不存明文，存 scrypt 派生的散列（格式 scrypt$盐$散列），应用层定长比较。
--   role：admin 管理员（全部权限）/ auditor 审计员（只读）/ desk 窗口人员（代约）。
--   权限按角色判断而非按用户名，增减人员只改数据不改代码。
CREATE TABLE users (
  id            VARCHAR(16)  PRIMARY KEY,
  username      VARCHAR(32)  NOT NULL,
  password_hash VARCHAR(200) NOT NULL,
  display_name  VARCHAR(50)  NOT NULL,
  role          VARCHAR(12)  NOT NULL DEFAULT 'admin',
  status        VARCHAR(12)  NOT NULL DEFAULT 'active',
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_users_username UNIQUE (username),
  CONSTRAINT ck_users_username CHECK (username ~ '^[A-Za-z0-9_]{3,32}$'),
  CONSTRAINT ck_users_status   CHECK (status IN ('active','disabled')),
  CONSTRAINT ck_users_role     CHECK (role IN ('admin','auditor','desk'))
);

-- 后台登录会话
--   令牌落库而不用 JWT：注销即删除这一行，可以真正让令牌立即失效。
CREATE TABLE user_sessions (
  token      VARCHAR(64) PRIMARY KEY,
  user_id    VARCHAR(16) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT ck_session_expiry CHECK (expires_at > created_at)
);
CREATE INDEX idx_sessions_user    ON user_sessions(user_id);
CREATE INDEX idx_sessions_expires ON user_sessions(expires_at);   -- 清理过期会话

-- 患者凭证
--   患者端没有账号。实名校验通过后签发 30 天有效的凭证，查看 / 取消挂号、
--   修改资料都要持有本人凭证。只存 SHA-256，数据库泄露也拿不到可用凭证。
CREATE TABLE patient_sessions (
  token_hash VARCHAR(64) PRIMARY KEY,
  patient_id VARCHAR(16) NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_patient_sessions_patient ON patient_sessions (patient_id);

-- 模拟公安人口库（身份证号 → 真实姓名），实名校验的比对依据
--   source：seed = 初始导入，auto = 首次校验时登记
CREATE TABLE citizen_registry (
  id_card    VARCHAR(18) PRIMARY KEY,
  name       VARCHAR(50) NOT NULL,
  source     VARCHAR(8)  NOT NULL DEFAULT 'auto',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_registry_id_card CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_registry_source  CHECK (source IN ('seed', 'auto'))
);

-- 实名校验日志：每一次校验都留痕
--   reason：match 比对一致 / new 首次登记 / name_mismatch 姓名不符
--   purpose：booking 挂号 / auth 查看记录前校验 / proxy 窗口代约
CREATE TABLE identity_verify_log (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  id_card    VARCHAR(18) NOT NULL,
  name_input VARCHAR(50) NOT NULL,
  passed     BOOLEAN     NOT NULL,
  reason     VARCHAR(16) NOT NULL,
  purpose    VARCHAR(16) NOT NULL DEFAULT 'booking',
  client_ip  VARCHAR(64),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_ivl_reason CHECK (reason IN ('match', 'new', 'name_mismatch'))
);
CREATE INDEX idx_ivl_id_card ON identity_verify_log (id_card, created_at DESC);

-- 验证码（短信 / 邮件，备用身份验证方式）
--   只存哈希；带过期时间、已用标记与尝试次数，防止重放与暴力猜测。
CREATE TABLE verification_codes (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  target     VARCHAR(120) NOT NULL,                 -- 接收方：手机号、邮箱或就诊人编号
  code_hash  VARCHAR(64)  NOT NULL,
  purpose    VARCHAR(20)  NOT NULL DEFAULT 'lookup',
  expire_at  TIMESTAMPTZ  NOT NULL,
  used       BOOLEAN      NOT NULL DEFAULT FALSE,
  attempts   INTEGER      NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_vc_target ON verification_codes (target, created_at DESC);

-- 挂号黑名单：until 为 NULL 表示永久；解除即删除该行或把 until 改为过去时间
CREATE TABLE blacklist (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  id_card    VARCHAR(18)  NOT NULL,
  patient_id VARCHAR(16)  REFERENCES patients(id) ON DELETE SET NULL,
  reason     VARCHAR(200) NOT NULL,
  until      TIMESTAMPTZ,
  created_by VARCHAR(32)  NOT NULL,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_blacklist_idcard  UNIQUE (id_card),
  CONSTRAINT ck_blacklist_idcard  CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_blacklist_reason  CHECK (length(btrim(reason)) >= 2)
);
CREATE UNIQUE INDEX idx_blacklist_id_card_ci ON blacklist (UPPER(id_card));

-- ----------------------------------------------------------------------------
--  2.4 审计与通知
-- ----------------------------------------------------------------------------

-- 挂号操作日志：哪张单子、何时、由谁、从什么状态变成什么状态
--   完全由触发器写入，应用层没有一句 INSERT，任何写入路径都会留下记录。
--   操作人取自会话变量 app.operator（应用层在事务内设置）。
CREATE TABLE appointment_log (
  id             BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  appointment_id VARCHAR(16) NOT NULL REFERENCES appointments(id) ON DELETE CASCADE,
  action         VARCHAR(16) NOT NULL,             -- insert / cancel / complete / no_show
  old_status     VARCHAR(12),
  new_status     VARCHAR(12),
  operator       VARCHAR(50),
  changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_log_action CHECK (action IN ('insert','cancel','complete','no_show'))
);
CREATE INDEX idx_log_appt ON appointment_log(appointment_id, changed_at DESC);

-- 隐私访问日志：谁、因为什么、查看了哪位患者的完整身份证 / 手机号
--   与 appointment_log 互补：前者记业务事实，后者防内部越权。
--   username 冗余存储，账号被删除后仍可追溯。
CREATE TABLE access_log (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  user_id     VARCHAR(16) REFERENCES users(id)    ON DELETE SET NULL,
  username    VARCHAR(32) NOT NULL,
  action      VARCHAR(24) NOT NULL,
  target_type VARCHAR(16) NOT NULL,
  target_id   VARCHAR(32) NOT NULL,
  patient_id  VARCHAR(16) REFERENCES patients(id) ON DELETE SET NULL,
  reason      VARCHAR(120),
  client_ip   VARCHAR(45),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_access_action CHECK (action IN ('reveal_idcard','view_patient','export_records','view_audit','blacklist')),
  CONSTRAINT ck_access_target CHECK (target_type IN ('patient','appointment','waitlist'))
);
CREATE INDEX idx_access_patient ON access_log(patient_id, created_at DESC);
CREATE INDEX idx_access_user    ON access_log(user_id,    created_at DESC);

-- 通知发件箱：就诊提醒、候补通知
--   数据库不直接发信（不依赖网络）：触发器和后台任务只写入待发记录，
--   由应用层的发信进程投递，失败可重试。
--   dedupe_key 保证幂等：同一张单的同一类提醒只会生成一条。
CREATE TABLE notification_outbox (
  id             BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  channel        VARCHAR(8)   NOT NULL,            -- email / inapp
  template       VARCHAR(24)  NOT NULL,
  dedupe_key     VARCHAR(120) NOT NULL,
  recipient      VARCHAR(160) NOT NULL,
  subject        VARCHAR(200) NOT NULL,
  body           TEXT         NOT NULL,
  status         VARCHAR(10)  NOT NULL DEFAULT 'pending',
  attempts       INTEGER      NOT NULL DEFAULT 0,
  scheduled_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  sent_at        TIMESTAMPTZ,
  last_error     VARCHAR(300),
  appointment_id VARCHAR(16)  REFERENCES appointments(id) ON DELETE CASCADE,
  waitlist_id    VARCHAR(16)  REFERENCES waitlist(id)     ON DELETE CASCADE,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_outbox_channel  CHECK (channel IN ('email','inapp')),
  CONSTRAINT ck_outbox_status   CHECK (status  IN ('pending','sent','failed','skipped')),
  CONSTRAINT ck_outbox_template CHECK (template IN ('waitlist_offer','waitlist_expired','reminder_t1','reminder_t0','booking_done')),
  CONSTRAINT uq_outbox_dedupe   UNIQUE (dedupe_key)
);
-- 部分索引：发信进程只查待发记录，按计划时间先后处理
CREATE INDEX idx_outbox_pending ON notification_outbox(status, scheduled_at) WHERE status = 'pending';


-- ============================================================================
--  第 3 部分  视图
-- ============================================================================

-- 可挂号源：今天及以后、未停诊、医生在岗、仍有余号的排班
CREATE VIEW v_available_schedules AS
SELECT s.id                           AS schedule_id,
       d.id                           AS dept_id,
       d.name                         AS dept_name,
       doc.id                         AS doctor_id,
       doc.name                       AS doctor_name,
       doc.title                      AS doctor_title,
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

-- 挂号详情：挂号单 + 患者 + 医生 + 科室 + 排班（五表连接）
--   我的预约、后台挂号记录、挂号成功回显都查这个视图。
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

-- 医生工作量：按医生 / 日期统计预约、取消、完成、爽约与收入
--   以排班为左表，当天无人挂号的排班也会出现（计数为 0），报表不漏行。
CREATE VIEW v_doctor_workload AS
SELECT doc.id   AS doctor_id,
       doc.name AS doctor_name,
       d.id     AS dept_id,
       d.name   AS dept_name,
       s.work_date,
       COUNT(a.id)                                     AS total_count,
       COUNT(*) FILTER (WHERE a.status = 'booked')     AS booked_count,
       COUNT(*) FILTER (WHERE a.status = 'cancelled')  AS cancelled_count,
       COUNT(*) FILTER (WHERE a.status = 'completed')  AS completed_count,
       COUNT(*) FILTER (WHERE a.status = 'no_show')    AS no_show_count,
       COALESCE(SUM(a.fee) FILTER (
         WHERE a.status IN ('booked','completed')), 0) AS revenue
  FROM schedules s
  JOIN doctors     doc ON doc.id = s.doctor_id
  JOIN departments d   ON d.id   = s.dept_id
  LEFT JOIN appointments a ON a.schedule_id = s.id
 GROUP BY doc.id, doc.name, d.id, d.name, s.work_date;

-- 脱敏视图：身份证中间 8 位、手机号中间 4 位替换为星号，供不应看到完整信息的场景使用
CREATE VIEW v_appointment_public AS
SELECT a.id,
       a.seq_no,
       a.status,
       p.name                                             AS patient_name,
       overlay(p.id_card PLACING '********' FROM 7 FOR 8) AS id_card_masked,
       overlay(p.phone   PLACING '****'     FROM 4 FOR 4) AS phone_masked,
       doc.name                                           AS doctor_name,
       d.name                                             AS dept_name,
       s.work_date,
       s.time_slot,
       a.fee
  FROM appointments a
  JOIN patients    p   ON p.id   = a.patient_id
  JOIN schedules   s   ON s.id   = a.schedule_id
  JOIN doctors     doc ON doc.id = a.doctor_id
  JOIN departments d   ON d.id   = doc.dept_id;

-- 候补明细：候补 + 排班 + 医生 + 科室 + 患者（身份证脱敏）
CREATE VIEW v_waitlist_detail AS
SELECT w.id,
       w.position,
       w.status,
       w.created_at,
       w.offered_at,
       w.offer_expires_at,
       w.converted_appointment_id,
       w.schedule_id,
       s.work_date,
       s.weekday,
       s.time_slot,
       s.start_time,
       s.end_time,
       s.max_quota,
       s.booked_count,
       (s.max_quota - s.booked_count) AS remain,
       s.closed,
       doc.id    AS doctor_id,
       doc.name  AS doctor_name,
       doc.title AS doctor_title,
       doc.fee,
       d.id      AS dept_id,
       d.name    AS dept_name,
       p.id      AS patient_id,
       p.name    AS patient_name,
       p.phone,
       p.email,
       overlay(p.id_card PLACING '********' FROM 7 FOR 8) AS id_card_masked
  FROM waitlist w
  JOIN schedules   s   ON s.id   = w.schedule_id
  JOIN doctors     doc ON doc.id = s.doctor_id
  JOIN departments d   ON d.id   = s.dept_id
  JOIN patients    p   ON p.id   = w.patient_id;


-- ============================================================================
--  第 4 部分  函数
-- ============================================================================

-- ----------------------------------------------------------------------------
--  4.1 通用
-- ----------------------------------------------------------------------------

-- 任何 UPDATE 自动刷新 updated_at
--   用 clock_timestamp() 而不是 NOW()：NOW() 是事务开始时间，同一事务内
--   多次修改得到的时间相同；clock_timestamp() 是真实的当前时间。
CREATE FUNCTION fn_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
--  4.2 挂号单
-- ----------------------------------------------------------------------------

-- 挂号前校验与号序分配（BEFORE INSERT）
--   校验：排班存在、未停诊、日期未过、号源未满、未重复预约、当天同科室无其他有效号。
--   并发控制：SELECT ... FOR UPDATE 锁住排班行。两个请求同时抢最后一个号时，
--   后到的请求在此等待前者提交，拿到锁后读到的已约数已是最新值，因此不会超卖。
--   号序取该排班已有最大号 + 1，退号留下的空号不回收。
CREATE FUNCTION fn_appt_before_insert() RETURNS trigger
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

  -- 同一号源，同一患者只能有一张有效单
  IF EXISTS (SELECT 1 FROM appointments a
              WHERE a.schedule_id = NEW.schedule_id
                AND a.patient_id  = NEW.patient_id
                AND a.status IN ('booked','completed')) THEN
    RAISE EXCEPTION '您已预约该时段，请勿重复挂号';
  END IF;

  -- 同一患者同一天同一科室只能有一个有效号
  IF EXISTS (SELECT 1 FROM appointments a
               JOIN schedules s2 ON s2.id = a.schedule_id
               JOIN doctors   d2 ON d2.id = a.doctor_id
              WHERE a.patient_id = NEW.patient_id
                AND a.status = 'booked'
                AND s2.work_date = sc.work_date
                AND d2.dept_id  = sc.dept_id) THEN
    RAISE EXCEPTION '同一就诊人当天在该科室已有有效预约，请勿重复挂号';
  END IF;

  SELECT COALESCE(MAX(seq_no), 0) + 1 INTO v_next
    FROM appointments WHERE schedule_id = NEW.schedule_id;
  NEW.seq_no := v_next;

  -- 新建单据只能是「待就诊」
  IF NEW.status IS DISTINCT FROM 'booked' THEN
    RAISE EXCEPTION '新建挂号单的状态只能是 booked';
  END IF;

  RETURN NEW;
END;
$$;

-- 限挂规则（BEFORE INSERT），防止恶意占号
--   1) 黑名单内的就诊人不能线上挂号；
--   2) 近 30 天自行取消 ≥ 5 次（管理员退号、停诊退号不计）；
--   3) 近 180 天爽约 ≥ 3 次；
--   4) 同一天最多 2 个有效号（跨科室）。
CREATE FUNCTION fn_appt_guard_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_idcard    VARCHAR(18);
  v_cancel    INTEGER;
  v_noshow    INTEGER;
  v_same_day  INTEGER;
  v_work_date DATE;
BEGIN
  SELECT id_card   INTO v_idcard    FROM patients  WHERE id = NEW.patient_id;
  SELECT work_date INTO v_work_date FROM schedules WHERE id = NEW.schedule_id;

  IF EXISTS (SELECT 1 FROM blacklist b
              WHERE b.id_card = v_idcard
                AND (b.until IS NULL OR b.until > NOW())) THEN
    RAISE EXCEPTION '该就诊人已被限制挂号，请联系门诊服务台';
  END IF;

  SELECT COUNT(*) INTO v_cancel
    FROM appointments a
   WHERE a.patient_id = NEW.patient_id
     AND a.status = 'cancelled'
     AND COALESCE(a.cancel_reason, 'patient') = 'patient'
     AND a.created_at > NOW() - INTERVAL '30 days';
  IF v_cancel >= 5 THEN
    RAISE EXCEPTION '近 30 天已取消 % 次挂号，超出限制，请到院窗口办理', v_cancel;
  END IF;

  SELECT COUNT(*) INTO v_noshow
    FROM appointments a
   WHERE a.patient_id = NEW.patient_id
     AND a.status = 'no_show'
     AND a.created_at > NOW() - INTERVAL '180 days';
  IF v_noshow >= 3 THEN
    RAISE EXCEPTION '近 180 天爽约 % 次，已暂停线上挂号，请到院窗口办理', v_noshow;
  END IF;

  SELECT COUNT(*) INTO v_same_day
    FROM appointments a
    JOIN schedules s2 ON s2.id = a.schedule_id
   WHERE a.patient_id = NEW.patient_id
     AND a.status IN ('booked','completed')
     AND s2.work_date = v_work_date;
  IF v_same_day >= 2 THEN
    RAISE EXCEPTION '同一就诊人同一天最多预约 2 个号，请先取消不需要的';
  END IF;

  RETURN NEW;
END;
$$;

-- 挂号成功后：已约数 + 1，写审计日志（AFTER INSERT）
--   放在 AFTER 而非 BEFORE：单据确实写入成功后才动号源，语义更清晰。
CREATE FUNCTION fn_appt_after_insert() RETURNS trigger
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

-- 状态流转与关键字段保护（BEFORE UPDATE）
--   只允许 booked → cancelled / completed / no_show；已取消不能复活，已完成不能改成爽约。
--   取消时间由数据库填写。单号、号序、排班、医生、患者、挂号费一经生成不可修改。
CREATE FUNCTION fn_appt_before_update() RETURNS trigger
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

-- 状态变更后：离开「待就诊」时已约数 - 1，写审计日志（AFTER UPDATE）
CREATE FUNCTION fn_appt_after_update() RETURNS trigger
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

-- 物理删除有效挂号单时回收号源（BEFORE DELETE）
--   系统的规范做法是只改状态、不删行；这里保证手工清理数据时号源计数也不会出错。
CREATE FUNCTION fn_appt_before_delete() RETURNS trigger
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

-- ----------------------------------------------------------------------------
--  4.3 排班与医生
-- ----------------------------------------------------------------------------

-- 排班修改保护（BEFORE UPDATE）
--   号源总量不得小于已约数；已有有效预约的排班不得修改日期、时段或医生
--   （否则等于在患者不知情的情况下改了就诊时间），需先停诊退号。
CREATE FUNCTION fn_schedule_before_update() RETURNS trigger
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

-- 排班删除保护（BEFORE DELETE）：有挂号记录的排班不得删除，保留以备追溯
CREATE FUNCTION fn_schedule_before_delete() RETURNS trigger
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

-- 医生删除保护（BEFORE DELETE）：有排班的医生不得删除，离职改用 is_active 软删除
CREATE FUNCTION fn_doctor_before_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM schedules WHERE doctor_id = OLD.id) THEN
    RAISE EXCEPTION '医生 % 仍有排班记录，不能删除；离职请把 is_active 置为 FALSE', OLD.name;
  END IF;
  RETURN OLD;
END;
$$;

-- ----------------------------------------------------------------------------
--  4.4 候补
-- ----------------------------------------------------------------------------

-- 候补排队前校验与序号分配（BEFORE INSERT）
--   只有号源已满才能候补（还有号就应直接挂号）；锁住排班行，保证并发下序号不重复。
CREATE FUNCTION fn_waitlist_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  sc     schedules%ROWTYPE;
  v_next INTEGER;
BEGIN
  SELECT * INTO sc FROM schedules WHERE id = NEW.schedule_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '排班不存在，请刷新后重试';
  END IF;

  IF sc.closed THEN
    RAISE EXCEPTION '该医生已停诊，无法候补';
  END IF;

  IF sc.work_date < CURRENT_DATE THEN
    RAISE EXCEPTION '不能候补已过去的日期';
  END IF;

  IF sc.booked_count < sc.max_quota THEN
    RAISE EXCEPTION '该时段还有 % 个号源，请直接挂号', sc.max_quota - sc.booked_count;
  END IF;

  IF EXISTS (SELECT 1 FROM appointments a
              WHERE a.schedule_id = NEW.schedule_id
                AND a.patient_id  = NEW.patient_id
                AND a.status IN ('booked','completed')) THEN
    RAISE EXCEPTION '您已预约该时段，无需候补';
  END IF;

  -- 序号只在仍有效的候补中取最大值 + 1，前端显示的「第几位」与实际人数一致
  SELECT COALESCE(MAX(position), 0) + 1 INTO v_next
    FROM waitlist
   WHERE schedule_id = NEW.schedule_id
     AND status IN ('waiting','offered');
  NEW.position := v_next;

  IF NEW.status IS DISTINCT FROM 'waiting' THEN
    RAISE EXCEPTION '新建候补的状态只能是 waiting';
  END IF;

  RETURN NEW;
END;
$$;

-- 候补状态流转保护（BEFORE UPDATE）
--   waiting → offered / cancelled / expired；offered → converted / cancelled / expired。
--   通知时自动填写通知时间与 2 小时保留期；转正必须关联挂号单；排队信息不可修改。
CREATE FUNCTION fn_waitlist_before_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
         (OLD.status = 'waiting' AND NEW.status IN ('offered','cancelled','expired'))
      OR (OLD.status = 'offered' AND NEW.status IN ('converted','cancelled','expired'))
    ) THEN
      RAISE EXCEPTION '非法候补状态流转：% → %', OLD.status, NEW.status;
    END IF;
  END IF;

  IF NEW.status = 'offered' THEN
    NEW.offered_at       := COALESCE(NEW.offered_at, clock_timestamp());
    NEW.offer_expires_at := COALESCE(NEW.offer_expires_at,
                                     clock_timestamp() + INTERVAL '2 hours');
  END IF;

  IF NEW.status = 'converted' AND NEW.converted_appointment_id IS NULL THEN
    RAISE EXCEPTION '候补转正必须关联挂号单号';
  END IF;

  IF NEW.position <> OLD.position
     OR NEW.schedule_id <> OLD.schedule_id
     OR NEW.patient_id  <> OLD.patient_id THEN
    RAISE EXCEPTION '候补的排队序号 / 排班 / 就诊人不允许修改';
  END IF;

  RETURN NEW;
END;
$$;

-- 为某条排班补位一位候补，返回被通知的候补编号；无人可补时返回 NULL
--   被退号触发器和后台任务（处理过期顺延）共用。
--   FOR UPDATE SKIP LOCKED：多个进程同时补位时不会通知同一个人，也不会互相等锁。
CREATE FUNCTION fn_offer_next_waitlist(p_schedule VARCHAR) RETURNS VARCHAR
LANGUAGE plpgsql AS $$
DECLARE
  sc     schedules%ROWTYPE;
  w      waitlist%ROWTYPE;
  p      patients%ROWTYPE;
  v_when TEXT;
BEGIN
  SELECT * INTO sc FROM schedules WHERE id = p_schedule;
  IF NOT FOUND OR sc.closed OR sc.work_date < CURRENT_DATE THEN
    RETURN NULL;
  END IF;
  IF sc.booked_count >= sc.max_quota THEN
    RETURN NULL;
  END IF;

  SELECT * INTO w FROM waitlist
   WHERE schedule_id = p_schedule AND status = 'waiting'
   ORDER BY position
   LIMIT 1
   FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  UPDATE waitlist
     SET status = 'offered',
         offered_at = clock_timestamp(),
         offer_expires_at = clock_timestamp() + INTERVAL '2 hours'
   WHERE id = w.id;

  SELECT * INTO p FROM patients WHERE id = w.patient_id;
  v_when := to_char(sc.work_date, 'YYYY-MM-DD') || ' ' || sc.time_slot;

  -- 站内信：无论是否填写邮箱都发
  INSERT INTO notification_outbox
        (channel, template, dedupe_key, recipient, subject, body, waitlist_id)
  VALUES ('inapp', 'waitlist_offer', 'waitlist_offer:inapp:' || w.id,
          p.id,
          '候补有号了：' || v_when,
          format('您候补的 %s（%s %s）空出一个号，请在 2 小时内确认，逾期顺延给下一位。',
                 v_when, (SELECT name FROM doctors WHERE id = sc.doctor_id), sc.time_slot),
          w.id)
  ON CONFLICT (dedupe_key) DO NOTHING;

  -- 邮件：填写了邮箱才发
  IF p.email IS NOT NULL THEN
    INSERT INTO notification_outbox
          (channel, template, dedupe_key, recipient, subject, body, waitlist_id)
    VALUES ('email', 'waitlist_offer', 'waitlist_offer:email:' || w.id,
            p.email,
            '候补有号了：' || v_when,
            format('您好 %s：您候补的 %s（%s %s）空出一个号，请在 2 小时内回到系统确认，逾期将顺延给下一位。',
                   p.name, v_when, (SELECT name FROM doctors WHERE id = sc.doctor_id), sc.time_slot),
            w.id)
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;

  RETURN w.id;
END;
$$;

-- 患者退号后立即补位（AFTER UPDATE on appointments）
--   停诊批量退号（cancel_reason = closure）不补位：医生不出诊，补上也无法就诊。
CREATE FUNCTION fn_appt_promote_waitlist() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'booked'
     AND NEW.status = 'cancelled'
     AND COALESCE(NEW.cancel_reason, 'patient') <> 'closure' THEN
    PERFORM fn_offer_next_waitlist(NEW.schedule_id);
  END IF;
  RETURN NULL;
END;
$$;

-- 挂号成功后关闭对应候补（AFTER INSERT on appointments）
--   候补转正时，挂号单一写入，对应候补自动标记为 converted。
CREATE FUNCTION fn_appt_close_waitlist() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE waitlist
     SET status = 'converted',
         converted_appointment_id = NEW.id
   WHERE schedule_id = NEW.schedule_id
     AND patient_id  = NEW.patient_id
     AND status IN ('waiting','offered');
  RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
--  4.5 实名校验
-- ----------------------------------------------------------------------------

-- 模拟公安二要素实名校验（姓名 + 身份证号），返回是否通过
--   人口库中有该身份证号：姓名必须一致；
--   没有：模拟查询成功并登记，此后该身份证号只认这个姓名（一号一名）。
--   并发下两人同时登记同一号，主键保证只登记一条，另一方按已登记结果比对。
--   每次校验写入 identity_verify_log。
--   前提假设：身份证号与姓名未泄露，二者一致即视为本人。
CREATE FUNCTION fn_verify_identity(
  p_name TEXT, p_id_card TEXT, p_purpose TEXT DEFAULT 'booking', p_ip TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
  v_name TEXT;
  v_new  BOOLEAN := FALSE;
  v_ok   BOOLEAN;
BEGIN
  p_name    := TRIM(p_name);
  p_id_card := UPPER(TRIM(p_id_card));

  SELECT name INTO v_name FROM citizen_registry WHERE id_card = p_id_card;
  IF NOT FOUND THEN
    INSERT INTO citizen_registry (id_card, name, source)
    VALUES (p_id_card, p_name, 'auto')
    ON CONFLICT (id_card) DO NOTHING;
    v_new := FOUND;
    SELECT name INTO v_name FROM citizen_registry WHERE id_card = p_id_card;
  END IF;

  v_ok := (v_name = p_name);

  INSERT INTO identity_verify_log (id_card, name_input, passed, reason, purpose, client_ip)
  VALUES (p_id_card, p_name, v_ok,
          CASE WHEN NOT v_ok THEN 'name_mismatch' WHEN v_new THEN 'new' ELSE 'match' END,
          COALESCE(p_purpose, 'booking'), p_ip);

  RETURN v_ok;
END;
$$;


-- ============================================================================
--  第 5 部分  触发器
--  同一表同一时机有多个触发器时，PostgreSQL 按触发器名称字母序执行。
-- ============================================================================

-- updated_at 自动维护
CREATE TRIGGER trg_dept_touch     BEFORE UPDATE ON departments  FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_doctor_touch   BEFORE UPDATE ON doctors      FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_patient_touch  BEFORE UPDATE ON patients     FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_schedule_touch BEFORE UPDATE ON schedules    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_appt_touch     BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_users_touch    BEFORE UPDATE ON users        FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_waitlist_touch BEFORE UPDATE ON waitlist     FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();

-- 挂号单：插入前（校验、号序、限挂）→ 插入后（号源 +1、日志、关闭候补）
CREATE TRIGGER trg_appt_before_insert   BEFORE INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_before_insert();
CREATE TRIGGER trg_appt_guard           BEFORE INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_guard_before_insert();
CREATE TRIGGER trg_appt_after_insert    AFTER  INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_after_insert();
CREATE TRIGGER trg_appt_close_waitlist  AFTER  INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_close_waitlist();

-- 挂号单：更新前（状态机）→ 更新后（号源 -1、日志、候补补位）
CREATE TRIGGER trg_appt_before_update    BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_before_update();
CREATE TRIGGER trg_appt_after_update     AFTER  UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_after_update();
CREATE TRIGGER trg_appt_promote_waitlist AFTER  UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_promote_waitlist();

-- 挂号单：删除前回收号源
CREATE TRIGGER trg_appt_before_delete BEFORE DELETE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_before_delete();

-- 排班与医生的修改 / 删除保护
CREATE TRIGGER trg_schedule_before_update BEFORE UPDATE ON schedules FOR EACH ROW EXECUTE FUNCTION fn_schedule_before_update();
CREATE TRIGGER trg_schedule_before_delete BEFORE DELETE ON schedules FOR EACH ROW EXECUTE FUNCTION fn_schedule_before_delete();
CREATE TRIGGER trg_doctor_before_delete   BEFORE DELETE ON doctors   FOR EACH ROW EXECUTE FUNCTION fn_doctor_before_delete();

-- 候补
CREATE TRIGGER trg_waitlist_before_insert BEFORE INSERT ON waitlist FOR EACH ROW EXECUTE FUNCTION fn_waitlist_before_insert();
CREATE TRIGGER trg_waitlist_before_update BEFORE UPDATE ON waitlist FOR EACH ROW EXECUTE FUNCTION fn_waitlist_before_update();


-- ============================================================================
--  第 6 部分  基础数据装载
--  挂号、候补、就诊人等业务数据初始为空，由患者在系统中产生。
-- ============================================================================

-- 科室（5 个）
INSERT INTO departments (id, name, description, location) VALUES
  ('D01', '内科', '感冒发热、高血压、糖尿病等常见内科疾病', '门诊楼 2 层东区'),
  ('D02', '外科', '外伤处理、体表肿物、术后复查',           '门诊楼 3 层'),
  ('D03', '儿科', '0-14 岁儿童常见病、生长发育咨询',        '门诊楼 1 层北侧（儿童医学中心）'),
  ('D04', '骨科', '骨折、关节疼痛、颈腰椎疾病',             '门诊楼 3 层西区'),
  ('D05', '眼科', '视力检查、结膜炎、白内障筛查',           '门诊楼 4 层');

-- 医生（10 位）：挂号费必须与职称档位一致，否则违反 ck_doctor_fee_tier
INSERT INTO doctors (id, dept_id, name, title, fee) VALUES
  ('DR01', 'D01', '张建国', '主任医师',   50),
  ('DR02', 'D01', '李慧敏', '副主任医师', 30),
  ('DR03', 'D01', '王振宇', '主治医师',   15),
  ('DR04', 'D02', '陈国强', '主任医师',   50),
  ('DR05', 'D02', '刘文博', '主治医师',   15),
  ('DR06', 'D03', '赵晓萍', '副主任医师', 30),
  ('DR07', 'D03', '孙宁',   '主治医师',   15),
  ('DR08', 'D04', '周海涛', '主任医师',   50),
  ('DR09', 'D04', '吴磊',   '主治医师',   15),
  ('DR10', 'D05', '郑晓岚', '副主任医师', 30);

-- 后台账号（1 个）：用户名 admin，初始口令 admin123（存的是 scrypt 散列，明文不入库）
-- 正式使用前请登录后修改口令。
INSERT INTO users (id, username, password_hash, display_name, role, status) VALUES
  ('U01', 'admin',
   'scrypt$1ce1601824db5cd874e6de327d86c619$c3187d301a3bf20a12232ab445120c85f1f8086aa651df350cfdb782564147a188b10cdcf3a8df20dd3a72e98ab0dafafd9912014aeeaf3b6e592e025c0b9707',
   '张明', 'admin', 'active');

-- 排班：从今天起 14 天 × 10 位医生 × 上午 / 下午 = 280 条
--   用 generate_series 生成日期，任何时候执行都会得到「未来两周」的排班。
--   号源按职称分档：主任医师 20 / 副主任医师 25 / 主治医师 30（职称越高号越少）。
--   诊室号按医生编号推导：DR01 → 诊室 01。
INSERT INTO schedules
       (id, doctor_id, dept_id, work_date, weekday, time_slot,
        start_time, end_time, room, max_quota)
SELECT 'SC_' || doc.id || '_' || to_char(day, 'YYYY-MM-DD') || '_' || p.code,
       doc.id,
       doc.dept_id,
       day::date,
       (ARRAY['周日','周一','周二','周三','周四','周五','周六'])[EXTRACT(DOW FROM day)::int + 1],
       p.slot,
       p.start_time,
       p.end_time,
       '诊室 ' || lpad(substring(doc.id FROM 3)::int::text, 2, '0'),
       CASE doc.title WHEN '主任医师'   THEN 20
                      WHEN '副主任医师' THEN 25
                      ELSE 30 END
  FROM doctors doc
 CROSS JOIN generate_series(CURRENT_DATE, CURRENT_DATE + 13, INTERVAL '1 day') AS day
 CROSS JOIN (VALUES ('AM', '上午', TIME '08:00', TIME '12:00'),
                    ('PM', '下午', TIME '13:30', TIME '17:00'))
            AS p(code, slot, start_time, end_time)
 ORDER BY day, doc.id, p.code;


-- ============================================================================
--  第 7 部分  检查与验证
-- ============================================================================

-- 7.1 数据装载结果
SELECT 'departments' AS 表名, COUNT(*) AS 行数 FROM departments
UNION ALL SELECT 'doctors',   COUNT(*) FROM doctors
UNION ALL SELECT 'users',     COUNT(*) FROM users
UNION ALL SELECT 'schedules', COUNT(*) FROM schedules;

-- 7.2 数据库对象数量（应为：表 16 / 视图 5 / 函数 16 / 触发器 20 / 索引 48）
SELECT (SELECT COUNT(*) FROM pg_tables  WHERE schemaname = 'public')                 AS 表,
       (SELECT COUNT(*) FROM pg_views   WHERE schemaname = 'public')                 AS 视图,
       (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public')                                                 AS 函数,
       (SELECT COUNT(*) FROM pg_trigger WHERE NOT tgisinternal)                      AS 触发器,
       (SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public')                 AS 索引;

-- 7.3 约束分类计数（应为：主键 16 / 外键 17 / 唯一 11 / 检查 34）
SELECT CASE c.contype WHEN 'p' THEN '主键' WHEN 'f' THEN '外键'
                      WHEN 'u' THEN '唯一' WHEN 'c' THEN '检查' END AS 约束类型,
       COUNT(*) AS 数量
  FROM pg_constraint c
  JOIN pg_namespace n ON n.oid = c.connamespace
 WHERE n.nspname = 'public' AND c.contype IN ('p','f','u','c')
 GROUP BY c.contype
 ORDER BY c.contype;

-- 7.4 核心不变量：任意时刻，所有排班的已约数之和 = 待就诊挂号单数（差值应为 0）
SELECT (SELECT COALESCE(SUM(booked_count), 0) FROM schedules)          AS 已约号源,
       (SELECT COUNT(*) FROM appointments WHERE status = 'booked')     AS 待就诊挂号,
       (SELECT COALESCE(SUM(booked_count), 0) FROM schedules)
     - (SELECT COUNT(*) FROM appointments WHERE status = 'booked')     AS 差值;

-- 7.5 价格防篡改：直接写入「主任医师 1 元」的挂号单会被外键拒绝（在事务中演示后回滚）
--   预期报错：违反外键约束 fk_appt_doctor_fee（SQLSTATE 23503）
--   如需演示，取消下面几行的注释执行：
-- BEGIN;
-- INSERT INTO patients (id, name, id_card, phone) VALUES ('PTEST', '测试', '110105199001011234', '13900000000');
-- INSERT INTO appointments (id, appointment_no, seq_no, schedule_id, doctor_id, patient_id, fee)
-- SELECT 'ATEST', 'TEST000001', 1, id, doctor_id, 'PTEST', 1 FROM schedules WHERE doctor_id = 'DR01' LIMIT 1;
-- ROLLBACK;
