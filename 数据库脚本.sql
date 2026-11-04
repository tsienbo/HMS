-- ============================================================================
--  智慧医院预约挂号系统（HMS）—— 数据库完整脚本
--  PostgreSQL 14 及以上（开发与验证环境：PostgreSQL 18）
-- ============================================================================
--
--  用途
--    假设从零开始：执行本脚本，得到与系统运行库完全一致的数据库 ——
--    18 张表、5 个视图、24 个函数、21 个触发器、全部约束与索引，
--    以及基础数据（13 个科室、26 位医生、后台账号、未来 14 天的排班、
--    约 1.9 万条科室搜索词典）。执行完即可启动应用。
--
--  执行方式（在 HMS 目录、以超级用户身份；科室词典按相对路径 server/data/dept_keywords.csv 导入）
--    psql -U postgres -f 数据库脚本.sql
--
--  ★ 本脚本会删除并重建全部表，对已有挂号数据的库执行会清空数据。
--    已在使用的库升级请运行 .venv\Scripts\python.exe server\app.py --init（只补缺少的对象）。
--
--  本文件由 tools/build_db_script.py 按运行库的实际结构生成（2026-11-04），请勿手工修改。
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
-- ============================================================================


-- ============================================================================
--  第 0 部分  建库并连接
-- ============================================================================

-- 库不存在才创建（CREATE DATABASE 不能放进事务或 DO 块，用 \gexec 实现条件执行）
SELECT 'CREATE DATABASE hospital_registration WITH ENCODING = ''UTF8'' TEMPLATE = template0'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'hospital_registration')
\gexec
\c hospital_registration
SET client_encoding = 'UTF8';
SET client_min_messages = warning;
-- 任一语句出错就停止，避免在半成品的库上继续执行
\set ON_ERROR_STOP on


-- ============================================================================
--  第 1 部分  清理旧对象（可重复执行）
-- ============================================================================

DROP TABLE IF EXISTS dept_keywords        CASCADE;
DROP TABLE IF EXISTS notification_outbox  CASCADE;
DROP TABLE IF EXISTS access_log           CASCADE;
DROP TABLE IF EXISTS appointment_log      CASCADE;
DROP TABLE IF EXISTS blacklist            CASCADE;
DROP TABLE IF EXISTS verification_codes   CASCADE;
DROP TABLE IF EXISTS identity_verify_log  CASCADE;
DROP TABLE IF EXISTS citizen_registry     CASCADE;
DROP TABLE IF EXISTS patient_sessions     CASCADE;
DROP TABLE IF EXISTS user_sessions        CASCADE;
DROP TABLE IF EXISTS users                CASCADE;
DROP TABLE IF EXISTS waitlist             CASCADE;
DROP TABLE IF EXISTS appointments         CASCADE;
DROP TABLE IF EXISTS patients             CASCADE;
DROP TABLE IF EXISTS schedules            CASCADE;
DROP TABLE IF EXISTS doctor_fee_history   CASCADE;
DROP TABLE IF EXISTS doctors              CASCADE;
DROP TABLE IF EXISTS departments          CASCADE;

DROP FUNCTION IF EXISTS fn_appt_after_insert() CASCADE;
DROP FUNCTION IF EXISTS fn_appt_after_update() CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_delete() CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_insert() CASCADE;
DROP FUNCTION IF EXISTS fn_appt_before_update() CASCADE;
DROP FUNCTION IF EXISTS fn_appt_close_waitlist() CASCADE;
DROP FUNCTION IF EXISTS fn_appt_guard_before_insert() CASCADE;
DROP FUNCTION IF EXISTS fn_appt_promote_waitlist() CASCADE;
DROP FUNCTION IF EXISTS fn_doc_key(p_type text, p_nat text, p_no text) CASCADE;
DROP FUNCTION IF EXISTS fn_doc_valid(p_type text, p_nat text, p_no text) CASCADE;
DROP FUNCTION IF EXISTS fn_doctor_before_delete() CASCADE;
DROP FUNCTION IF EXISTS fn_doctor_fee(p_title text, p_dept text) CASCADE;
DROP FUNCTION IF EXISTS fn_doctor_fee_history() CASCADE;
DROP FUNCTION IF EXISTS fn_gb11643_ok(p text) CASCADE;
DROP FUNCTION IF EXISTS fn_mask_doc(p text) CASCADE;
DROP FUNCTION IF EXISTS fn_norm_name(p text) CASCADE;
DROP FUNCTION IF EXISTS fn_offer_next_waitlist(p_schedule character varying) CASCADE;
DROP FUNCTION IF EXISTS fn_schedule_before_delete() CASCADE;
DROP FUNCTION IF EXISTS fn_schedule_before_update() CASCADE;
DROP FUNCTION IF EXISTS fn_search_departments(p_q text) CASCADE;
DROP FUNCTION IF EXISTS fn_touch_updated_at() CASCADE;
DROP FUNCTION IF EXISTS fn_verify_identity(p_name text, p_id_card text, p_purpose text, p_ip text) CASCADE;
DROP FUNCTION IF EXISTS fn_waitlist_before_insert() CASCADE;
DROP FUNCTION IF EXISTS fn_waitlist_before_update() CASCADE;


-- ============================================================================
--  第 2 部分  扩展与建表要用的函数
-- ============================================================================

-- 科室搜索的「包含」匹配（LIKE '%胃%'）要用三元组索引，扩展装在单独的 ext 模式里
CREATE SCHEMA IF NOT EXISTS ext;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA ext;

CREATE OR REPLACE FUNCTION fn_gb11643_ok(p text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  w INT[] := ARRAY[7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  s INT := 0;
BEGIN
  IF p IS NULL OR p !~ '^[0-9]{17}[0-9X]$' THEN
    RETURN FALSE;
  END IF;
  FOR i IN 1..17 LOOP
    s := s + substr(p, i, 1)::INT * w[i];
  END LOOP;
  RETURN substr('10X98765432', s % 11 + 1, 1) = substr(p, 18, 1);
END;
$function$;

CREATE OR REPLACE FUNCTION fn_doc_valid(p_type text, p_nat text, p_no text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_type
    WHEN 'CN_ID'    THEN public.fn_gb11643_ok(p_no) AND p_no !~ '^(81|82|83|9)'
    WHEN 'HMT_RES'  THEN public.fn_gb11643_ok(p_no) AND p_no ~ '^8[123]0000'
    WHEN 'FRP'      THEN (public.fn_gb11643_ok(p_no) AND p_no ~ '^9') OR p_no ~ '^[A-Z]{3}[0-9]{12}$'
    WHEN 'HK_MO'    THEN p_no ~ '^[HM][0-9]{8}([0-9]{2})?$'
    WHEN 'TW'       THEN p_no ~ '^[0-9]{8}([0-9]{2})?$'
    WHEN 'PASSPORT' THEN p_no ~ '^[A-Z0-9]{5,14}$' AND coalesce(p_nat, '') ~ '^[A-Z]{2}$'
    ELSE FALSE
  END;
$function$;

CREATE OR REPLACE FUNCTION fn_doc_key(p_type text, p_nat text, p_no text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE WHEN p_type = 'PASSPORT'
              THEN 'P:' || upper(coalesce(p_nat, '')) || ':' || upper(p_no)
              ELSE upper(p_no) END;
$function$;

CREATE OR REPLACE FUNCTION fn_norm_name(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT upper(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'));
$function$;

CREATE OR REPLACE FUNCTION fn_mask_doc(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p IS NULL THEN NULL
    WHEN char_length(p) >= 15 THEN left(p, 6) || repeat('*', char_length(p) - 10) || right(p, 4)
    WHEN char_length(p) >= 6  THEN left(p, 2) || repeat('*', char_length(p) - 4) || right(p, 2)
    ELSE repeat('*', char_length(p))
  END;
$function$;

CREATE OR REPLACE FUNCTION fn_doctor_fee(p_title text, p_dept text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT (CASE
    WHEN p_dept = 'D10' THEN                         -- 中医科：门诊诊查费（中医辨证论治）
      CASE p_title WHEN '主任医师' THEN 21.50 WHEN '副主任医师' THEN 16.50 ELSE 11.50 END
    ELSE                                             -- 门诊诊查费（普通门诊）
      CASE p_title WHEN '主任医师' THEN 21.50 WHEN '副主任医师' THEN 14.50 ELSE 4.50 END
      + CASE WHEN p_dept IN ('D06', 'D09') THEN 2.00 ELSE 0 END   -- 妇产科、口腔科加收 2 元
  END)::NUMERIC(8,2)
$function$;



-- ============================================================================
--  第 3 部分  数据表
-- ============================================================================

-- departments：科室
CREATE TABLE departments (
  id           VARCHAR(8) NOT NULL,   -- 科室编号 D01…D13
  name         VARCHAR(50) NOT NULL,   -- 科室名（唯一）
  description  VARCHAR(200) NOT NULL,   -- 简介
  location     VARCHAR(120),   -- (新增) 楼层/区域位置，如“门诊楼 2 层东区”
  sex_limit    CHAR(1),   -- 性别限制：NULL 不限，F 只接诊女性（妇产科），M 只接诊男性（男科）
  created_at   TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at   TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 科室编号唯一，如 D01
  CONSTRAINT departments_pkey PRIMARY KEY (id),
  -- 科室名不能重复，避免出现两个「内科」让患者选错
  CONSTRAINT uq_dept_name UNIQUE (name),
  -- 每个科室都必须写明位置，预约凭证和「查看路线」要用
  CONSTRAINT ck_dept_location CHECK ((location IS NOT NULL) AND (length(btrim(location)) >= 2)),
  -- 性别限制只能是「不限 / 仅男 / 仅女」三种，挂号触发器据此拦截（妇产科 F、男科 M）
  CONSTRAINT ck_dept_sex_limit CHECK ((sex_limit IS NULL) OR (sex_limit IN ('M', 'F')))
);

-- doctors：医生
CREATE TABLE doctors (
  id          VARCHAR(8) NOT NULL,   -- 医生编号 DR01…
  dept_id     VARCHAR(8) NOT NULL,   -- 所属科室
  name        VARCHAR(50) NOT NULL,   -- 姓名
  title       VARCHAR(20) NOT NULL,   -- 职称（主任医师 / 副主任医师 / 主治医师）
  fee         NUMERIC(8,2) NOT NULL,   -- 现行挂号费，由 ck_doctor_fee_rule 按湖北省标准约束
  is_active   BOOLEAN DEFAULT TRUE NOT NULL,   -- 软删除开关（离职置 FALSE，档案保留）
  created_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 医生编号唯一，如 DR01
  CONSTRAINT doctors_pkey PRIMARY KEY (id),
  -- 医生必须属于真实存在的科室；科室下还有医生时不能删科室
  CONSTRAINT doctors_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES departments(id) ON DELETE RESTRICT,
  -- 挂号费必须等于定价函数按职称和科室算出的价格（湖北省门诊诊查费标准）；不能把医生价格改成 1 元，也不能随意定价
  CONSTRAINT ck_doctor_fee_rule CHECK (fee = fn_doctor_fee(title, dept_id)),
  -- 职称只能是三档之一，挂号费按职称计算
  CONSTRAINT ck_doctor_title CHECK (title IN ('主任医师', '副主任医师', '主治医师'))
);
CREATE INDEX idx_doctors_dept ON doctors (dept_id);

-- doctor_fee_history：价目历史
CREATE TABLE doctor_fee_history (
  doctor_id   VARCHAR(8) NOT NULL,
  fee         NUMERIC(8,2) NOT NULL,
  valid_from  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  valid_to    TIMESTAMPTZ,
  -- 每位医生执行过的每个价格一行；同时是挂号单价格外键的引用目标
  CONSTRAINT pk_doctor_fee_history PRIMARY KEY (doctor_id, fee),
  -- 价目属于真实的医生；医生被删除时价目一起删（有挂号单的医生本来就删不掉）
  CONSTRAINT doctor_fee_history_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE CASCADE,
  -- 价格必须为正数
  CONSTRAINT ck_dfh_fee CHECK (fee > 0),
  -- 失效时间不能早于生效时间；valid_to 为空表示现行价格
  CONSTRAINT ck_dfh_period CHECK ((valid_to IS NULL) OR (valid_to >= valid_from))
);
-- 每位医生同一时刻只有一个现行价格
CREATE UNIQUE INDEX uq_dfh_current ON doctor_fee_history (doctor_id) WHERE (valid_to IS NULL);

-- schedules：排班（号源挂在上面）
CREATE TABLE schedules (
  id            VARCHAR(32) NOT NULL,   -- SC_医生_日期_AM/PM
  doctor_id     VARCHAR(8) NOT NULL,
  dept_id       VARCHAR(8) NOT NULL,
  work_date     DATE NOT NULL,
  weekday       VARCHAR(8) NOT NULL,
  time_slot     VARCHAR(8) NOT NULL,
  start_time    TIME NOT NULL,
  end_time      TIME NOT NULL,
  room          VARCHAR(24) DEFAULT '' NOT NULL,   -- 诊室号（如“诊室 01”）
  max_quota     INTEGER NOT NULL,
  booked_count  INTEGER DEFAULT 0 NOT NULL,
  closed        BOOLEAN DEFAULT FALSE NOT NULL,   -- 是否停诊
  created_at    TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at    TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 排班编号唯一，如 SC_DR01_2026-11-05_AM
  CONSTRAINT schedules_pkey PRIMARY KEY (id),
  -- 同一医生同一天的上午或下午只有一条排班，不会重复放号；左前缀还兼作「按医生和日期查排班」的索引
  CONSTRAINT uq_schedule_doctor_date_slot UNIQUE (doctor_id, work_date, time_slot),
  -- 本身已由主键保证唯一，声明它是为了给挂号单的复合外键 fk_appt_schedule 当引用目标
  CONSTRAINT uq_schedule_id_doctor UNIQUE (id, doctor_id),
  -- 排班上冗余存的科室必须真实存在（按科室查号源少一次连接）
  CONSTRAINT schedules_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES departments(id) ON DELETE RESTRICT,
  -- 排班必须对应真实医生；医生还有排班时不能删
  CONSTRAINT schedules_doctor_id_fkey FOREIGN KEY (doctor_id) REFERENCES doctors(id) ON DELETE RESTRICT,
  -- 防超卖的最后一道防线：即使触发器被禁用、有人直接改库，已约数也不可能超过号源或变成负数
  CONSTRAINT ck_schedule_booked_range CHECK ((booked_count >= 0) AND (booked_count <= max_quota)),
  -- 号源总量至少 1 个；停诊用 closed 标记，不用把号源改成 0
  CONSTRAINT ck_schedule_max_quota CHECK (max_quota > 0),
  -- 号源的最小单位是半天
  CONSTRAINT ck_schedule_slot CHECK (time_slot IN ('上午', '下午')),
  -- 出诊结束时间必须晚于开始时间
  CONSTRAINT ck_schedule_time_order CHECK (end_time > start_time)
);
CREATE INDEX idx_schedules_date ON schedules (work_date);
CREATE INDEX idx_schedules_dept ON schedules (dept_id);

-- patients：患者（就诊人）
CREATE TABLE patients (
  id           VARCHAR(16) NOT NULL,   -- P + 毫秒时间戳
  name         VARCHAR(50) NOT NULL,   -- 姓名（中文，或证件上的外文拼写）
  sex          CHAR(1) NOT NULL,   -- 性别 M / F。身份证、港澳台居住证必须与证件号第 17 位一致（奇男偶女），其他证件由患者选择
  id_type      VARCHAR(10) DEFAULT 'CN_ID' NOT NULL,   -- 证件类型（v3.5）：CN_ID 居民身份证 / PASSPORT 护照 / FRP 外国人永久居留身份证 / HK_MO 港澳居民来往内地通行证 / TW 台湾居民来往大陆通行证 / HMT_RES 港澳台居民居住证
  nationality  CHAR(2),   -- 国籍 / 地区，ISO 3166 两位代码；护照必填
  id_card      VARCHAR(18) NOT NULL,   -- 证件号码
  doc_key      VARCHAR(40) GENERATED ALWAYS AS (fn_doc_key(id_type, nationality, id_card)) STORED,   -- fn_doc_key(id_type, nationality, id_card)：护照为 P:国籍:号码，其余为大写号码。各处按它识别同一个人
  phone_cc     VARCHAR(4) DEFAULT '86' NOT NULL,   -- 国际区号，默认 86
  phone        VARCHAR(11) NOT NULL,   -- 手机号（不含区号）
  email        VARCHAR(120),   -- 选填（收提醒用，NULL 或合法邮箱）
  created_at   TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at   TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 就诊人编号唯一（P + 毫秒时间戳）
  CONSTRAINT patients_pkey PRIMARY KEY (id),
  -- 一人一档：证件键由证件类型、国籍、号码自动生成，同一个证件只能有一份档案（护照按「国籍 + 号码」区分）
  CONSTRAINT uq_patients_doc_key UNIQUE (doc_key),
  -- 按证件类型校验号码格式：身份证和居住证要通过 GB 11643 校验位、出生日期必须真实；通行证、护照按各自的号码规则
  CONSTRAINT ck_patients_doc CHECK (fn_doc_valid(id_type, nationality, id_card)),
  -- 邮箱选填，填了就必须像个邮箱，否则提醒邮件发不出去
  CONSTRAINT ck_patients_email CHECK ((email IS NULL) OR (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')),
  -- 只接受居民身份证、港澳台居民居住证、外国人永居证、港澳通行证、台湾通行证、护照
  CONSTRAINT ck_patients_id_type CHECK (id_type IN ('CN_ID', 'HMT_RES', 'FRP', 'HK_MO', 'TW', 'PASSPORT')),
  -- 国籍用 ISO 两位代码；护照号在不同国家可能重复，必须带国籍才能区分
  CONSTRAINT ck_patients_nationality CHECK (((nationality IS NULL) OR (nationality ~ '^[A-Z]{2}$')) AND ((id_type NOT IN ('PASSPORT', 'FRP')) OR (nationality IS NOT NULL))),
  -- 手机号格式在数据库层兜底（各国更细的规则在应用层校验）
  CONSTRAINT ck_patients_phone_intl CHECK ((phone_cc ~ '^[1-9][0-9]{0,3}$') AND
CASE
    WHEN (phone_cc = '86') THEN (phone ~ '^1[3-9][0-9]{9}$')
    ELSE (phone ~ '^[0-9]{4,11}$')
END),
  -- 防止身份证登记的性别与证件不符，从而绕过科室性别限制
  CONSTRAINT ck_patients_sex CHECK ((sex IN ('M', 'F')) AND ((id_type NOT IN ('CN_ID', 'HMT_RES')) OR (sex =
CASE
    WHEN (((substr(id_card, 17, 1))::integer % 2) = 1) THEN 'M'
    ELSE 'F'
END)))
);

-- appointments：挂号单
CREATE TABLE appointments (
  id              VARCHAR(16) NOT NULL,   -- A + 毫秒时间戳
  appointment_no  VARCHAR(16) NOT NULL,   -- 10 位随机预约单号，供患者凭单号查询（唯一）
  seq_no          INTEGER NOT NULL,   -- 该半天第几号（触发器分配）
  schedule_id     VARCHAR(32) NOT NULL,   -- 排班编号
  doctor_id       VARCHAR(8) NOT NULL,   -- 接诊医生（与排班一致）
  patient_id      VARCHAR(16) NOT NULL,   -- 就诊人
  fee             NUMERIC(8,2) NOT NULL,   -- 挂号费快照（下单时抄医生价目）
  status          VARCHAR(12) DEFAULT 'booked' NOT NULL,   -- booked / cancelled / completed / no_show
  cancel_reason   VARCHAR(16),
  close_note      VARCHAR(200),   -- 停诊 / 退号备注
  cancelled_at    TIMESTAMPTZ,   -- 取消时间（已取消时必填）
  created_at      TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at      TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 挂号单号唯一（A + 毫秒时间戳）
  CONSTRAINT appointments_pkey PRIMARY KEY (id),
  -- 10 位随机预约单号全局唯一，患者凭它查询
  CONSTRAINT uq_appt_no UNIQUE (appointment_no),
  -- 同一个半天里号序不重复；退号留下的空号不回收，历史单据的「第几号」永远不变
  CONSTRAINT uq_appt_schedule_seq UNIQUE (schedule_id, seq_no),
  -- 挂号单必须属于真实的就诊人；有挂号记录的档案不能直接删（后台删除会先走退号流程）
  CONSTRAINT appointments_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
  -- 挂号费防篡改：挂号费必须是这位医生执行过的价格，一元挂号单无论从哪条路径写入都会被拒绝；医生调价后旧单据仍引用旧价格
  CONSTRAINT fk_appt_doctor_fee FOREIGN KEY (doctor_id, fee) REFERENCES doctor_fee_history(doctor_id, fee),
  -- 复合外键：挂号单上的医生必须就是这条排班的医生，不会出现「挂张医生的号、单子上写李医生」；有挂号的排班不能删
  CONSTRAINT fk_appt_schedule FOREIGN KEY (schedule_id, doctor_id) REFERENCES schedules(id, doctor_id) ON DELETE RESTRICT,
  -- 「已取消」当且仅当有取消时间，取消必须留痕，也不会出现有取消时间却仍待就诊的矛盾数据
  CONSTRAINT ck_appt_cancel_pair CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
  -- 区分患者自己取消、后台退号、停诊退号；防黄牛只统计患者自己取消的次数
  CONSTRAINT ck_appt_cancel_reason CHECK ((cancel_reason IS NULL) OR (cancel_reason IN ('patient', 'admin', 'closure'))),
  -- 挂号费不能为负
  CONSTRAINT ck_appt_fee CHECK (fee >= 0),
  -- 号序从 1 开始
  CONSTRAINT ck_appt_seq CHECK (seq_no > 0),
  -- 挂号状态只有待就诊、已取消、已完成、爽约四种
  CONSTRAINT ck_appt_status CHECK (status IN ('booked', 'cancelled', 'completed', 'no_show'))
);
CREATE INDEX idx_appt_doctor ON appointments (doctor_id);
CREATE INDEX idx_appt_patient_created ON appointments (patient_id, created_at DESC);
CREATE INDEX idx_appt_schedule_status ON appointments (schedule_id, status);
-- 同一个人对同一号源只能有一张有效单；只约束有效单，所以取消后还能重新挂
CREATE UNIQUE INDEX uq_appt_active_slot ON appointments (schedule_id, patient_id) WHERE (status IN ('booked', 'completed'));

-- waitlist：候补队列
CREATE TABLE waitlist (
  id                        VARCHAR(16) NOT NULL,
  schedule_id               VARCHAR(32) NOT NULL,
  patient_id                VARCHAR(16) NOT NULL,
  position                  INTEGER NOT NULL,
  status                    VARCHAR(12) DEFAULT 'waiting' NOT NULL,
  offered_at                TIMESTAMPTZ,
  offer_expires_at          TIMESTAMPTZ,
  converted_appointment_id  VARCHAR(16),
  created_at                TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at                TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 候补编号唯一
  CONSTRAINT waitlist_pkey PRIMARY KEY (id),
  -- 同一排班的排队序号不重复，先来后到明确
  CONSTRAINT uq_waitlist_schedule_pos UNIQUE (schedule_id, "position"),
  -- 候补转正后记下生成的挂号单，便于追溯
  CONSTRAINT waitlist_converted_appointment_id_fkey FOREIGN KEY (converted_appointment_id) REFERENCES appointments(id) ON DELETE SET NULL,
  -- 候补必须属于真实的就诊人
  CONSTRAINT waitlist_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE RESTRICT,
  -- 候补必须对应真实排班；有人排队的排班不能删
  CONSTRAINT waitlist_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES schedules(id) ON DELETE RESTRICT,
  -- 状态和时间戳必须对得上，不会出现「已通知」却没有通知时间的数据
  CONSTRAINT ck_waitlist_offer_pair CHECK (
CASE
    WHEN (status = 'waiting') THEN (offered_at IS NULL)
    WHEN (status IN ('offered', 'converted', 'expired')) THEN (offered_at IS NOT NULL)
    ELSE true
END),
  -- 「为你保留 2 小时」的窗口不能是倒着的
  CONSTRAINT ck_waitlist_offer_window CHECK ((offer_expires_at IS NULL) OR (offered_at IS NULL) OR (offer_expires_at > offered_at)),
  -- 排队序号从 1 开始
  CONSTRAINT ck_waitlist_position CHECK ("position" > 0),
  -- 候补状态：排队中、已通知保留、已转挂号、已过期、已放弃
  CONSTRAINT ck_waitlist_status CHECK (status IN ('waiting', 'offered', 'converted', 'expired', 'cancelled'))
);
CREATE INDEX idx_waitlist_patient ON waitlist (patient_id, created_at DESC);
CREATE INDEX idx_waitlist_queue ON waitlist (schedule_id, status, "position");
-- 同一个人对同一号源只能有一条进行中的候补，不能重复排队占位
CREATE UNIQUE INDEX uq_waitlist_active ON waitlist (schedule_id, patient_id) WHERE (status IN ('waiting', 'offered'));

-- users：后台账号
CREATE TABLE users (
  id             VARCHAR(16) NOT NULL,
  username       VARCHAR(32) NOT NULL,
  password_hash  VARCHAR(200) NOT NULL,
  display_name   VARCHAR(50) NOT NULL,
  role           VARCHAR(12) DEFAULT 'admin' NOT NULL,   -- admin / auditor / desk
  status         VARCHAR(12) DEFAULT 'active' NOT NULL,
  last_login_at  TIMESTAMPTZ,   -- 最近登录
  created_at     TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at     TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 账号编号唯一
  CONSTRAINT users_pkey PRIMARY KEY (id),
  -- 登录名唯一
  CONSTRAINT uq_users_username UNIQUE (username),
  -- 角色只有管理员、审计员、窗口三种，接口按角色控制权限
  CONSTRAINT ck_users_role CHECK (role IN ('admin', 'auditor', 'desk')),
  -- 账号可以停用而不删除，保留操作记录
  CONSTRAINT ck_users_status CHECK (status IN ('active', 'disabled')),
  -- 登录名格式统一，避免空格、中文等造成登录混乱
  CONSTRAINT ck_users_username CHECK (username ~ '^[A-Za-z0-9_]{3,32}$')
);

-- user_sessions：登录会话（令牌）
CREATE TABLE user_sessions (
  token       VARCHAR(64) NOT NULL,   -- 随机令牌
  user_id     VARCHAR(16) NOT NULL,   -- 所属用户（ON DELETE CASCADE）
  expires_at  TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 登录令牌唯一
  CONSTRAINT user_sessions_pkey PRIMARY KEY (token),
  -- 会话属于真实账号；账号删除时会话一起失效
  CONSTRAINT user_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  -- 过期时间必须晚于创建时间
  CONSTRAINT ck_session_expiry CHECK (expires_at > created_at)
);
CREATE INDEX idx_sessions_expires ON user_sessions (expires_at);
CREATE INDEX idx_sessions_user ON user_sessions (user_id);

-- patient_sessions：患者凭证
CREATE TABLE patient_sessions (
  token_hash  VARCHAR(64) NOT NULL,
  patient_id  VARCHAR(16) NOT NULL,
  expires_at  TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 凭证只存 SHA-256 散列，散列唯一
  CONSTRAINT patient_sessions_pkey PRIMARY KEY (token_hash),
  -- 凭证属于真实的就诊人；档案删除时凭证一起作废
  CONSTRAINT patient_sessions_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE
);
CREATE INDEX idx_patient_sessions_patient ON patient_sessions (patient_id);

-- citizen_registry：模拟公安人口库
CREATE TABLE citizen_registry (
  id_card     VARCHAR(40) NOT NULL,
  name        VARCHAR(50) NOT NULL,
  source      VARCHAR(8) DEFAULT 'auto' NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 一个证件键只登记一个真实姓名
  CONSTRAINT citizen_registry_pkey PRIMARY KEY (id_card),
  -- 与就诊人的证件键格式一致，避免大小写不同被当成两个证件
  CONSTRAINT ck_registry_doc_key CHECK ((id_card = upper(id_card)) AND ((char_length(id_card) >= 5) AND (char_length(id_card) <= 40))),
  -- 区分初始导入的数据和首次实名校验时自动登记的数据
  CONSTRAINT ck_registry_source CHECK (source IN ('seed', 'auto'))
);

-- identity_verify_log：实名校验日志
CREATE TABLE identity_verify_log (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  id_card     VARCHAR(40) NOT NULL,
  name_input  VARCHAR(50) NOT NULL,
  passed      BOOLEAN NOT NULL,
  reason      VARCHAR(16) NOT NULL,
  purpose     VARCHAR(16) DEFAULT 'booking' NOT NULL,
  client_ip   VARCHAR(64),
  created_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 日志编号（自增）
  CONSTRAINT identity_verify_log_pkey PRIMARY KEY (id),
  -- 每次校验的结果只有三种：姓名一致、首次登记、姓名不符
  CONSTRAINT ck_ivl_reason CHECK (reason IN ('match', 'new', 'name_mismatch'))
);
CREATE INDEX idx_ivl_id_card ON identity_verify_log (id_card, created_at DESC);

-- verification_codes：验证码（备用）
CREATE TABLE verification_codes (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  target      VARCHAR(120) NOT NULL,
  code_hash   VARCHAR(64) NOT NULL,
  purpose     VARCHAR(20) DEFAULT 'lookup' NOT NULL,
  expire_at   TIMESTAMPTZ NOT NULL,
  used        BOOLEAN DEFAULT FALSE NOT NULL,
  attempts    INTEGER DEFAULT 0 NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 验证码记录编号（自增）；只存答案散列，一次有效，由应用层控制
  CONSTRAINT verification_codes_pkey PRIMARY KEY (id)
);
CREATE INDEX idx_vc_target ON verification_codes (target, created_at DESC);

-- blacklist：黑名单（v3）
CREATE TABLE blacklist (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  id_card     VARCHAR(40) NOT NULL,
  patient_id  VARCHAR(16),
  reason      VARCHAR(200) NOT NULL,
  until       TIMESTAMPTZ,
  created_by  VARCHAR(32) NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 记录编号（自增）
  CONSTRAINT blacklist_pkey PRIMARY KEY (id),
  -- 同一个证件只拉黑一次
  CONSTRAINT uq_blacklist_idcard UNIQUE (id_card),
  -- 关联档案（可选）；档案删除后拉黑记录仍按证件键生效
  CONSTRAINT blacklist_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE SET NULL,
  -- 与就诊人证件键格式一致，挂号触发器才能比对得上
  CONSTRAINT ck_blacklist_doc_key CHECK ((id_card = upper(id_card)) AND ((char_length(id_card) >= 5) AND (char_length(id_card) <= 40))),
  -- 拉黑必须写明原因，便于申诉和审计
  CONSTRAINT ck_blacklist_reason CHECK (length(btrim(reason)) >= 2)
);

-- appointment_log：挂号操作日志
CREATE TABLE appointment_log (
  id              BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  appointment_id  VARCHAR(16) NOT NULL,
  action          VARCHAR(16) NOT NULL,
  old_status      VARCHAR(12),
  new_status      VARCHAR(12),
  operator        VARCHAR(50),
  changed_at      TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 日志编号（自增）
  CONSTRAINT appointment_log_pkey PRIMARY KEY (id),
  -- 日志属于真实的挂号单；挂号单被删除时日志一起删
  CONSTRAINT appointment_log_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES appointments(id) ON DELETE CASCADE,
  -- 日志只记录新建、取消、完成、爽约四种动作，由触发器写入
  CONSTRAINT ck_log_action CHECK (action IN ('insert', 'cancel', 'complete', 'no_show'))
);
CREATE INDEX idx_log_appt ON appointment_log (appointment_id, changed_at DESC);

-- access_log：隐私访问日志（v3）
CREATE TABLE access_log (
  id           BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  user_id      VARCHAR(16),
  username     VARCHAR(32) NOT NULL,
  action       VARCHAR(24) NOT NULL,
  target_type  VARCHAR(16) NOT NULL,
  target_id    VARCHAR(32) NOT NULL,
  patient_id   VARCHAR(16),
  reason       VARCHAR(120),
  client_ip    VARCHAR(45),
  created_at   TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 日志编号（自增）
  CONSTRAINT access_log_pkey PRIMARY KEY (id),
  -- 记录被查看的是谁；档案删除后日志保留，审计不能断
  CONSTRAINT access_log_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE SET NULL,
  -- 记录是谁操作的；账号删除后日志保留
  CONSTRAINT access_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL,
  -- 只允许记录规定的几类敏感操作
  CONSTRAINT ck_access_action CHECK (action IN ('reveal_idcard', 'view_patient', 'export_records', 'view_audit', 'blacklist', 'create_patient', 'edit_patient', 'delete_patient')),
  -- 被访问对象的类型
  CONSTRAINT ck_access_target CHECK (target_type IN ('patient', 'appointment', 'waitlist'))
);
CREATE INDEX idx_access_patient ON access_log (patient_id, created_at DESC);
CREATE INDEX idx_access_user ON access_log (user_id, created_at DESC);

-- notification_outbox：通知发件箱（v3）
CREATE TABLE notification_outbox (
  id              BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  channel         VARCHAR(8) NOT NULL,
  template        VARCHAR(24) NOT NULL,
  dedupe_key      VARCHAR(120) NOT NULL,
  recipient       VARCHAR(160) NOT NULL,
  subject         VARCHAR(200) NOT NULL,
  body            TEXT NOT NULL,
  status          VARCHAR(10) DEFAULT 'pending' NOT NULL,
  attempts        INTEGER DEFAULT 0 NOT NULL,
  scheduled_at    TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  sent_at         TIMESTAMPTZ,
  last_error      VARCHAR(300),
  appointment_id  VARCHAR(16),
  waitlist_id     VARCHAR(16),
  created_at      TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- 通知编号（自增）
  CONSTRAINT notification_outbox_pkey PRIMARY KEY (id),
  -- 防重复发送：同一条提醒（如「某挂号单的次日提醒」）只会生成一次，定时任务每分钟扫描也不会重复
  CONSTRAINT uq_outbox_dedupe UNIQUE (dedupe_key),
  -- 就诊提醒属于某张挂号单；单子删除时待发提醒一起删
  CONSTRAINT notification_outbox_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES appointments(id) ON DELETE CASCADE,
  -- 候补通知属于某条候补
  CONSTRAINT notification_outbox_waitlist_id_fkey FOREIGN KEY (waitlist_id) REFERENCES waitlist(id) ON DELETE CASCADE,
  -- 渠道只有邮件和站内信
  CONSTRAINT ck_outbox_channel CHECK (channel IN ('email', 'inapp')),
  -- 待发、已发、失败、跳过
  CONSTRAINT ck_outbox_status CHECK (status IN ('pending', 'sent', 'failed', 'skipped')),
  -- 通知类型固定，便于统计和排查
  CONSTRAINT ck_outbox_template CHECK (template IN ('waitlist_offer', 'waitlist_expired', 'reminder_t1', 'reminder_t0', 'booking_done'))
);
CREATE INDEX idx_outbox_pending ON notification_outbox (status, scheduled_at) WHERE (status = 'pending');

-- dept_keywords：科室搜索词典（v3.4）
CREATE TABLE dept_keywords (
  id          INTEGER GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  term        VARCHAR(60) NOT NULL,
  kind        VARCHAR(8) NOT NULL,
  dept_id     VARCHAR(8),
  other_dept  VARCHAR(20),
  weight      INTEGER DEFAULT 100 NOT NULL,
  pinyin      VARCHAR(200) DEFAULT '' NOT NULL,
  abbr        VARCHAR(60) DEFAULT '' NOT NULL,
  -- 词条编号（自增）
  CONSTRAINT dept_keywords_pkey PRIMARY KEY (id),
  -- 同一个词对同一科室只录一次，重复导入不会产生重复词条
  CONSTRAINT uq_dk_term UNIQUE NULLS NOT DISTINCT (term, kind, dept_id, other_dept),
  -- 词条指向真实科室；科室删除时它的词条一起删
  CONSTRAINT dept_keywords_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES departments(id) ON DELETE CASCADE,
  -- 词条类型：科室名、疾病、症状
  CONSTRAINT ck_dk_kind CHECK (kind IN ('dept', 'disease', 'symptom')),
  -- 每个词要么指向本院科室，要么指向本院没有的科室（如急诊），不能都空或都填
  CONSTRAINT ck_dk_target CHECK ((dept_id IS NULL) <> (other_dept IS NULL)),
  -- 权重必须为正，搜索打分才有意义
  CONSTRAINT ck_dk_weight CHECK (weight > 0)
);
CREATE INDEX idx_dk_abbr ON dept_keywords (abbr text_pattern_ops);
CREATE INDEX idx_dk_dept ON dept_keywords (dept_id);
CREATE INDEX idx_dk_pinyin ON dept_keywords (pinyin text_pattern_ops);
CREATE INDEX idx_dk_term_trgm ON dept_keywords USING gin (term ext.gin_trgm_ops);



-- ============================================================================
--  第 4 部分  视图
-- ============================================================================

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
    p.id AS patient_id,
    p.name AS patient_name,
    p.id_card,
    p.phone,
    doc.id AS doctor_id,
    doc.name AS doctor_name,
    doc.title AS doctor_title,
    d.id AS dept_id,
    d.name AS dept_name,
    d.location,
    s.id AS schedule_id,
    s.room,
    s.work_date,
    s.weekday,
    s.time_slot,
    s.start_time,
    s.end_time
   FROM appointments a
     JOIN patients p ON p.id::text = a.patient_id::text
     JOIN schedules s ON s.id::text = a.schedule_id::text
     JOIN doctors doc ON doc.id::text = a.doctor_id::text
     JOIN departments d ON d.id::text = doc.dept_id::text;

CREATE VIEW v_appointment_public AS
SELECT a.id,
    a.seq_no,
    a.status,
    p.name AS patient_name,
    fn_mask_doc(p.id_card::text) AS id_card_masked,
    OVERLAY(p.phone PLACING '****'::text FROM 4 FOR 4) AS phone_masked,
    doc.name AS doctor_name,
    d.name AS dept_name,
    s.work_date,
    s.time_slot,
    a.fee
   FROM appointments a
     JOIN patients p ON p.id::text = a.patient_id::text
     JOIN schedules s ON s.id::text = a.schedule_id::text
     JOIN doctors doc ON doc.id::text = a.doctor_id::text
     JOIN departments d ON d.id::text = doc.dept_id::text;

CREATE VIEW v_available_schedules AS
SELECT s.id AS schedule_id,
    d.id AS dept_id,
    d.name AS dept_name,
    doc.id AS doctor_id,
    doc.name AS doctor_name,
    doc.title AS doctor_title,
    doc.fee,
    s.work_date,
    s.weekday,
    s.time_slot,
    s.start_time,
    s.end_time,
    s.max_quota,
    s.booked_count,
    s.max_quota - s.booked_count AS remain
   FROM schedules s
     JOIN doctors doc ON doc.id::text = s.doctor_id::text
     JOIN departments d ON d.id::text = s.dept_id::text
  WHERE s.closed = false AND doc.is_active = true AND s.work_date >= CURRENT_DATE AND NOT (s.work_date + s.end_time - '00:30:00'::interval) <= (now() AT TIME ZONE 'Asia/Shanghai'::text) AND (s.max_quota - s.booked_count) > 0;

CREATE VIEW v_doctor_workload AS
SELECT doc.id AS doctor_id,
    doc.name AS doctor_name,
    d.id AS dept_id,
    d.name AS dept_name,
    s.work_date,
    count(a.id) AS total_count,
    count(*) FILTER (WHERE a.status::text = 'booked'::text) AS booked_count,
    count(*) FILTER (WHERE a.status::text = 'cancelled'::text) AS cancelled_count,
    count(*) FILTER (WHERE a.status::text = 'completed'::text) AS completed_count,
    count(*) FILTER (WHERE a.status::text = 'no_show'::text) AS no_show_count,
    COALESCE(sum(a.fee) FILTER (WHERE a.status IN ('booked', 'completed')), 0::numeric) AS revenue
   FROM schedules s
     JOIN doctors doc ON doc.id::text = s.doctor_id::text
     JOIN departments d ON d.id::text = s.dept_id::text
     LEFT JOIN appointments a ON a.schedule_id::text = s.id::text
  GROUP BY doc.id, doc.name, d.id, d.name, s.work_date;

CREATE VIEW v_waitlist_detail AS
SELECT w.id,
    w."position",
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
    s.max_quota - s.booked_count AS remain,
    s.closed,
    doc.id AS doctor_id,
    doc.name AS doctor_name,
    doc.title AS doctor_title,
    doc.fee,
    d.id AS dept_id,
    d.name AS dept_name,
    p.id AS patient_id,
    p.name AS patient_name,
    p.phone,
    p.email,
    fn_mask_doc(p.id_card::text) AS id_card_masked
   FROM waitlist w
     JOIN schedules s ON s.id::text = w.schedule_id::text
     JOIN doctors doc ON doc.id::text = s.doctor_id::text
     JOIN departments d ON d.id::text = s.dept_id::text
     JOIN patients p ON p.id::text = w.patient_id::text;



-- ============================================================================
--  第 5 部分  函数
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_appt_after_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  UPDATE schedules
     SET booked_count = booked_count + 1
   WHERE id = NEW.schedule_id;

  INSERT INTO appointment_log (appointment_id, action, old_status, new_status, operator)
  VALUES (NEW.id, 'insert', NULL, NEW.status,
          NULLIF(current_setting('app.operator', true), ''));
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_appt_after_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION fn_appt_before_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status = 'booked' THEN
    UPDATE schedules
       SET booked_count = GREATEST(booked_count - 1, 0)
     WHERE id = OLD.schedule_id;
  END IF;
  RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_appt_before_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  sc      schedules%ROWTYPE;
  v_next  INTEGER;
  v_held  INTEGER;
  v_mine  BOOLEAN;
  v_limit CHAR(1);
  v_sex   CHAR(1);
BEGIN
  -- ★ 先锁患者行，再锁排班行（全系统同一顺序，不会死锁）。
  --   同一患者的两笔挂号在这里排队：后一笔等前一笔提交后再做下面的限挂检查，
  --   才能看到前一笔 —— 否则两条连接同时挂不同科室，「同日最多 2 个号」会被突破。
  PERFORM 1 FROM patients WHERE id = NEW.patient_id FOR UPDATE;

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

  -- 当天的半天：结束前 30 分钟停止挂号（上午 11:30、下午 16:30），按北京时间比较
  IF sc.work_date + sc.end_time - INTERVAL '30 minutes' <= (NOW() AT TIME ZONE 'Asia/Shanghai') THEN
    RAISE EXCEPTION '该时段已停止挂号（当天上午 11:30、下午 16:30 截止）';
  END IF;

  IF sc.booked_count >= sc.max_quota THEN
    RAISE EXCEPTION '该时段号源已挂完，请选择其他时段';
  END IF;

  -- 候补「保留 2 小时」要真的占住名额：已通知且未过期的候补数算作预留。
  -- 本人就是被通知的那位，可以用掉给他留的那一个。
  SELECT COUNT(*) FILTER (WHERE w.patient_id <> NEW.patient_id),
         COALESCE(bool_or(w.patient_id = NEW.patient_id), FALSE)
    INTO v_held, v_mine
    FROM waitlist w
   WHERE w.schedule_id = NEW.schedule_id
     AND w.status = 'offered'
     AND w.offer_expires_at > clock_timestamp();
  IF NOT v_mine AND sc.booked_count + v_held >= sc.max_quota THEN
    RAISE EXCEPTION '该时段剩余号源已为候补患者保留，请选择其他时段或加入候补';
  END IF;

  -- 科室性别限制：妇产科只接诊女性、男科只接诊男性（departments.sex_limit）
  SELECT d.sex_limit, p.sex INTO v_limit, v_sex
    FROM departments d, patients p
   WHERE d.id = sc.dept_id AND p.id = NEW.patient_id;
  IF v_limit IS NOT NULL AND v_sex IS DISTINCT FROM v_limit THEN
    RAISE EXCEPTION '该科室仅接诊%患者', CASE v_limit WHEN 'F' THEN '女性' ELSE '男性' END;
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

  -- 挂号费只能按医生现行价格收：价目历史表里的旧价格（外键允许）不能用来新挂号
  IF NEW.fee IS DISTINCT FROM (SELECT d.fee FROM doctors d WHERE d.id = NEW.doctor_id) THEN
    RAISE EXCEPTION '挂号费必须按医生现行价格收取';
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
$function$;

CREATE OR REPLACE FUNCTION fn_appt_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION fn_appt_close_waitlist()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- 排队中（waiting）直接挂上号的也算转正：补上 offered_at，满足 ck_waitlist_offer_pair
  UPDATE waitlist
     SET status = 'converted',
         converted_appointment_id = NEW.id,
         offered_at = COALESCE(offered_at, clock_timestamp())
   WHERE schedule_id = NEW.schedule_id
     AND patient_id  = NEW.patient_id
     AND status IN ('waiting','offered');
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_appt_guard_before_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_idcard VARCHAR(40);
  v_cancel INTEGER;
  v_noshow INTEGER;
  v_same_day INTEGER;
  v_work_date DATE;
BEGIN
  SELECT doc_key INTO v_idcard FROM patients WHERE id = NEW.patient_id;   -- 证件键，护照也适用
  SELECT work_date INTO v_work_date FROM schedules WHERE id = NEW.schedule_id;

  -- 1) 黑名单
  IF EXISTS (SELECT 1 FROM blacklist b
              WHERE b.id_card = v_idcard
                AND (b.until IS NULL OR b.until > NOW())) THEN
    RAISE EXCEPTION '该就诊人已被限制挂号，请联系门诊服务台';
  END IF;

  -- 2) 频繁取消：只统计患者自己退的，管理员退号 / 停诊退号不算在他头上
  SELECT COUNT(*) INTO v_cancel
    FROM appointments a
   WHERE a.patient_id = NEW.patient_id
     AND a.status = 'cancelled'
     AND COALESCE(a.cancel_reason, 'patient') = 'patient'
     AND a.created_at > NOW() - INTERVAL '30 days';
  IF v_cancel >= 5 THEN
    RAISE EXCEPTION '近 30 天已取消 % 次挂号，超出限制，请到院窗口办理', v_cancel;
  END IF;

  -- 3) 爽约
  SELECT COUNT(*) INTO v_noshow
    FROM appointments a
   WHERE a.patient_id = NEW.patient_id
     AND a.status = 'no_show'
     AND a.created_at > NOW() - INTERVAL '180 days';
  IF v_noshow >= 3 THEN
    RAISE EXCEPTION '近 180 天爽约 % 次，已暂停线上挂号，请到院窗口办理', v_noshow;
  END IF;

  -- 4) 同一天跨科室最多 2 个有效号
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
$function$;

CREATE OR REPLACE FUNCTION fn_appt_promote_waitlist()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status = 'booked'
     AND NEW.status = 'cancelled'
     AND COALESCE(NEW.cancel_reason, 'patient') <> 'closure' THEN
    PERFORM fn_offer_next_waitlist(NEW.schedule_id);
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_doctor_before_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM schedules WHERE doctor_id = OLD.id) THEN
    RAISE EXCEPTION '医生 % 仍有排班记录，不能删除；离职请把 is_active 置为 FALSE', OLD.name;
  END IF;
  RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_doctor_fee_history()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.fee = OLD.fee THEN
    RETURN NEW;
  END IF;
  UPDATE doctor_fee_history SET valid_to = NOW()
   WHERE doctor_id = NEW.id AND valid_to IS NULL AND fee <> NEW.fee;
  INSERT INTO doctor_fee_history (doctor_id, fee) VALUES (NEW.id, NEW.fee)
  ON CONFLICT (doctor_id, fee) DO UPDATE SET valid_to = NULL;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION fn_offer_next_waitlist(p_schedule character varying)
 RETURNS character varying
 LANGUAGE plpgsql
AS $function$
DECLARE
  sc  schedules%ROWTYPE;
  w   waitlist%ROWTYPE;
  p   patients%ROWTYPE;
  v_when TEXT;
BEGIN
  SELECT * INTO sc FROM schedules WHERE id = p_schedule FOR UPDATE;
  IF NOT FOUND OR sc.closed OR sc.work_date < CURRENT_DATE
     OR sc.work_date + sc.end_time - INTERVAL '30 minutes' <= (NOW() AT TIME ZONE 'Asia/Shanghai') THEN
    RETURN NULL;
  END IF;
  -- 没被占用、也没给别的候补留着的号才能再通知一位
  IF sc.booked_count + (SELECT COUNT(*) FROM waitlist x
                         WHERE x.schedule_id = p_schedule AND x.status = 'offered'
                           AND x.offer_expires_at > clock_timestamp()) >= sc.max_quota THEN
    RETURN NULL;                       -- 号又被别人抢走了，谁也不用通知
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

  -- 站内消息：不管有没有邮箱都发一条，患者登录后能看到
  INSERT INTO notification_outbox
        (channel, template, dedupe_key, recipient, subject, body, waitlist_id)
  VALUES ('inapp', 'waitlist_offer', 'waitlist_offer:inapp:' || w.id,
          p.id,
          '候补有号了：' || v_when,
          format('您候补的 %s（%s %s）空出一个号，请在 2 小时内确认，逾期顺延给下一位。',
                 v_when, (SELECT name FROM doctors WHERE id = sc.doctor_id), sc.time_slot),
          w.id)
  ON CONFLICT (dedupe_key) DO NOTHING;

  -- 邮件：只有填了邮箱才发
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
$function$;

CREATE OR REPLACE FUNCTION fn_schedule_before_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION fn_schedule_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.max_quota < OLD.booked_count THEN
    RAISE EXCEPTION '号源总数不能小于已预约数（当前已约 % 个）', OLD.booked_count;
  END IF;

  IF NEW.max_quota < OLD.max_quota AND NEW.max_quota < OLD.booked_count +
     (SELECT COUNT(*) FROM waitlist WHERE schedule_id=OLD.id AND status='offered'
        AND offer_expires_at > clock_timestamp()) THEN
    RAISE EXCEPTION '号源总数不能小于已预约数与有效候补预留数之和';
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
$function$;

CREATE OR REPLACE FUNCTION fn_search_departments(p_q text)
 RETURNS TABLE(dept_id character varying, other_dept character varying, score numeric, hits text[])
 LANGUAGE sql
 STABLE
AS $function$
  WITH q AS (
    -- 去空白、转小写；「疼」统一成「痛」（词典入库时做了同样的替换）；
    -- 口语换成医学常用说法：拉肚子 → 腹泻，肚子 → 腹（肚子痛 → 腹痛），嗓子 → 咽（嗓子痛 → 咽痛）
    SELECT replace(replace(replace(
             regexp_replace(lower(regexp_replace(coalesce(p_q, ''), '\s', '', 'g')), '疼(?!痛)', '痛', 'g'),
             '拉肚子', '腹泻'), '肚子', '腹'), '嗓子', '咽') AS q
  ), m AS (
    SELECT k.dept_id, k.other_dept, k.kind, k.term, k.weight,
           CASE
             WHEN k.term = q.q                                        THEN 100
             WHEN q.q ~ '^[a-z]+$' AND (k.pinyin = q.q OR k.abbr = q.q) THEN 80
             WHEN char_length(k.term) >= 2 AND position(k.term IN q.q) > 0 THEN 60
             WHEN k.term LIKE q.q || '%'                                THEN 40
             WHEN q.q ~ '^[a-z]+$'                                      THEN 30
             ELSE 20
           END AS s
      FROM dept_keywords k, q
     WHERE q.q <> ''
       AND char_length(q.q) <= 60
       AND q.q !~ '^[a-z0-9]$'                      -- 单个字母或数字太宽泛，不搜
       AND ( k.term LIKE '%' || q.q || '%'
          OR (char_length(k.term) >= 2 AND position(k.term IN q.q) > 0)
          OR (q.q ~ '^[a-z]+$'
              AND (k.pinyin LIKE q.q || '%' OR k.abbr LIKE q.q || '%')) )
  ), per_term AS (                                 -- 同一个词既是疾病又是症状时只算一次
    SELECT m.dept_id, m.other_dept, m.term, bool_or(m.kind = 'dept') AS is_dept,
           max(m.s * m.weight) AS pts
      FROM m
     GROUP BY m.dept_id, m.other_dept, m.term
  ), agg AS (
    SELECT t.dept_id, t.other_dept,
           round(sum(t.pts) / 100.0, 1) AS score,
           (array_agg(t.term ORDER BY t.pts DESC, char_length(t.term))
              FILTER (WHERE NOT t.is_dept))[1:3] AS hits
      FROM per_term t
     GROUP BY t.dept_id, t.other_dept
  )
  SELECT a.dept_id, a.other_dept, a.score, coalesce(a.hits, '{}')
    FROM agg a
   WHERE a.score >= 0.15 * (SELECT max(score) FROM agg)
   ORDER BY a.score DESC
   LIMIT 8;
$function$;

CREATE OR REPLACE FUNCTION fn_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_verify_identity(p_name text, p_id_card text, p_purpose text DEFAULT 'booking'::text, p_ip text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
-- p_id_card 传的是证件键 doc_key（居民身份证就是身份证号本身）
DECLARE
  v_name TEXT;
  v_new  BOOLEAN := FALSE;
  v_ok   BOOLEAN;
BEGIN
  p_id_card := upper(btrim(p_id_card));
  p_name := regexp_replace(btrim(p_name), '\s+', ' ', 'g');

  SELECT name INTO v_name FROM citizen_registry WHERE id_card = p_id_card;
  IF NOT FOUND THEN
    -- 模拟「查询成功」：第一次出现的证件按本次姓名登记，此后只认这个姓名
    INSERT INTO citizen_registry (id_card, name, source)
    VALUES (p_id_card, p_name, 'auto')
    ON CONFLICT (id_card) DO NOTHING;            -- 并发时主键保证只登记一次
    v_new := FOUND;
    SELECT name INTO v_name FROM citizen_registry WHERE id_card = p_id_card;
  END IF;

  v_ok := fn_norm_name(v_name) = fn_norm_name(p_name);

  INSERT INTO identity_verify_log (id_card, name_input, passed, reason, purpose, client_ip)
  VALUES (p_id_card, p_name, v_ok,
          CASE WHEN NOT v_ok THEN 'name_mismatch' WHEN v_new THEN 'new' ELSE 'match' END,
          p_purpose, p_ip);
  RETURN v_ok;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_waitlist_before_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  sc schedules%ROWTYPE;
  v_next INTEGER;
  v_limit CHAR(1);
  v_sex   CHAR(1);
BEGIN
  -- 锁住排班行：既防止并发下序号重复，也保证「还有没有号」的判断是准的
  SELECT * INTO sc FROM schedules WHERE id = NEW.schedule_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '排班不存在，请刷新后重试';
  END IF;

  IF sc.closed THEN
    RAISE EXCEPTION '该医生已停诊，无法候补';
  END IF;

  -- 科室性别限制：妇产科只接诊女性、男科只接诊男性（departments.sex_limit）
  SELECT d.sex_limit, p.sex INTO v_limit, v_sex
    FROM departments d, patients p
   WHERE d.id = sc.dept_id AND p.id = NEW.patient_id;
  IF v_limit IS NOT NULL AND v_sex IS DISTINCT FROM v_limit THEN
    RAISE EXCEPTION '该科室仅接诊%患者', CASE v_limit WHEN 'F' THEN '女性' ELSE '男性' END;
  END IF;

  IF sc.work_date < CURRENT_DATE
     OR sc.work_date + sc.end_time - INTERVAL '30 minutes' <= (NOW() AT TIME ZONE 'Asia/Shanghai') THEN
    RAISE EXCEPTION '该时段已停止挂号，不能再排候补';
  END IF;

  -- 还有（没被候补预留的）号就直接挂，不该排队 —— 否则候补队列会变成「慢一点再挂号」的通道
  IF sc.booked_count + (SELECT COUNT(*) FROM waitlist w
                         WHERE w.schedule_id = NEW.schedule_id AND w.status = 'offered'
                           AND w.offer_expires_at > clock_timestamp()) < sc.max_quota THEN
    RAISE EXCEPTION '该时段还有号源，请直接挂号';
  END IF;

  IF EXISTS (SELECT 1 FROM appointments a
              WHERE a.schedule_id = NEW.schedule_id
                AND a.patient_id  = NEW.patient_id
                AND a.status IN ('booked','completed')) THEN
    RAISE EXCEPTION '您已预约该时段，无需候补';
  END IF;

  -- 同一排班内的排队序号：在该排班的全部历史行里取最大值 + 1，永久递增。
  -- （uq_waitlist_schedule_pos 管的是全部历史；只看进行中的行，取消后会撞号。）
  -- 「前面还有几人」由接口按进行中的行另算，不用这个序号直接展示。
  SELECT COALESCE(MAX(position), 0) + 1 INTO v_next
    FROM waitlist
   WHERE schedule_id = NEW.schedule_id;
  NEW.position := v_next;

  IF NEW.status IS DISTINCT FROM 'waiting' THEN
    RAISE EXCEPTION '新建候补的状态只能是 waiting';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION fn_waitlist_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
         (OLD.status = 'waiting'   AND NEW.status IN ('offered','converted','cancelled','expired'))
      OR (OLD.status = 'offered'   AND NEW.status IN ('converted','cancelled','expired'))
    ) THEN
      RAISE EXCEPTION '非法候补状态流转：% → %', OLD.status, NEW.status;
    END IF;
  END IF;

  IF NEW.status = 'offered' THEN
    NEW.offered_at       := COALESCE(NEW.offered_at, clock_timestamp());
    NEW.offer_expires_at := COALESCE(NEW.offer_expires_at,
                                     clock_timestamp() + INTERVAL '2 hours');
  END IF;

  -- 转正之后必须挂上挂号单号，否则「补位成功」这件事无法追溯
  IF NEW.status = 'converted' AND NEW.converted_appointment_id IS NULL THEN
    RAISE EXCEPTION '候补转正必须关联挂号单号';
  END IF;

  -- 排队位置、排班、患者不允许改（换号等于插队）
  IF NEW.position <> OLD.position
     OR NEW.schedule_id <> OLD.schedule_id
     OR NEW.patient_id  <> OLD.patient_id THEN
    RAISE EXCEPTION '候补的排队序号 / 排班 / 就诊人不允许修改';
  END IF;

  RETURN NEW;
END;
$function$;



-- ============================================================================
--  第 6 部分  触发器
-- ============================================================================

CREATE TRIGGER trg_appt_after_insert AFTER INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_after_insert();
CREATE TRIGGER trg_appt_after_update AFTER UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_after_update();
CREATE TRIGGER trg_appt_before_delete BEFORE DELETE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_before_delete();
CREATE TRIGGER trg_appt_before_insert BEFORE INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_before_insert();
CREATE TRIGGER trg_appt_before_update BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_before_update();
CREATE TRIGGER trg_appt_close_waitlist AFTER INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_close_waitlist();
CREATE TRIGGER trg_appt_guard BEFORE INSERT ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_guard_before_insert();
CREATE TRIGGER trg_appt_promote_waitlist AFTER UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_appt_promote_waitlist();
CREATE TRIGGER trg_appt_touch BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_dept_touch BEFORE UPDATE ON departments FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_doctor_before_delete BEFORE DELETE ON doctors FOR EACH ROW EXECUTE FUNCTION fn_doctor_before_delete();
CREATE TRIGGER trg_doctor_fee_history AFTER INSERT OR UPDATE OF fee ON doctors FOR EACH ROW EXECUTE FUNCTION fn_doctor_fee_history();
CREATE TRIGGER trg_doctor_touch BEFORE UPDATE ON doctors FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_patient_touch BEFORE UPDATE ON patients FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_schedule_before_delete BEFORE DELETE ON schedules FOR EACH ROW EXECUTE FUNCTION fn_schedule_before_delete();
CREATE TRIGGER trg_schedule_before_update BEFORE UPDATE ON schedules FOR EACH ROW EXECUTE FUNCTION fn_schedule_before_update();
CREATE TRIGGER trg_schedule_touch BEFORE UPDATE ON schedules FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_users_touch BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_waitlist_before_insert BEFORE INSERT ON waitlist FOR EACH ROW EXECUTE FUNCTION fn_waitlist_before_insert();
CREATE TRIGGER trg_waitlist_before_update BEFORE UPDATE ON waitlist FOR EACH ROW EXECUTE FUNCTION fn_waitlist_before_update();
CREATE TRIGGER trg_waitlist_touch BEFORE UPDATE ON waitlist FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();


-- ============================================================================
--  第 7 部分  基础数据装载
-- ============================================================================

-- 业务数据（就诊人、挂号、候补等）初始为空，由患者在系统中产生。

-- 科室（13 个）：sex_limit 为 F 只接诊女性、M 只接诊男性
INSERT INTO departments (id, name, description, location, sex_limit) VALUES
  ('D01', '内科', '感冒发热、高血压、糖尿病等常见内科疾病', '门诊楼 2 层东区', NULL),
  ('D02', '外科', '外伤处理、体表肿物、术后复查', '门诊楼 3 层', NULL),
  ('D03', '儿科', '0-14 岁儿童常见病、生长发育咨询', '门诊楼 1 层北侧（儿童医学中心）', NULL),
  ('D04', '骨科', '骨折、关节疼痛、颈腰椎疾病', '门诊楼 3 层西区', NULL),
  ('D05', '眼科', '视力检查、结膜炎、白内障筛查', '门诊楼 4 层', NULL),
  ('D06', '妇产科', '月经不调、妇科炎症、孕期检查与产后复查', '门诊楼 4 层东区', 'F'),
  ('D07', '皮肤科', '湿疹、痤疮、皮炎、荨麻疹、真菌感染', '门诊楼 4 层西区', NULL),
  ('D08', '耳鼻喉科', '鼻炎、咽喉炎、中耳炎、听力下降', '门诊楼 5 层东区', NULL),
  ('D09', '口腔科', '牙痛、龋齿、牙周病、口腔溃疡', '门诊楼 5 层西区', NULL),
  ('D10', '中医科', '中医调理、针灸推拿、慢性病调养', '门诊楼 6 层', NULL),
  ('D11', '精神心理科', '失眠、焦虑、抑郁、心理咨询', '门诊楼 6 层南侧', NULL),
  ('D12', '肿瘤科', '肿瘤筛查、放化疗随访、肿瘤综合治疗', '医技楼 3 层', NULL),
  ('D13', '男科', '前列腺疾病、男性泌尿生殖问题', '门诊楼 5 层南侧', 'M');

-- 医生（26 位）：挂号费必须等于 fn_doctor_fee(职称, 科室)，否则违反 ck_doctor_fee_rule；
-- 插入时触发器 trg_doctor_fee_history 自动把这个价格登记进价目历史
INSERT INTO doctors (id, dept_id, name, title, fee) VALUES
  ('DR01', 'D01', '张建国', '主任医师', 21.50),
  ('DR02', 'D01', '李慧敏', '副主任医师', 14.50),
  ('DR03', 'D01', '王振宇', '主治医师', 4.50),
  ('DR04', 'D02', '陈国强', '主任医师', 21.50),
  ('DR05', 'D02', '刘文博', '主治医师', 4.50),
  ('DR06', 'D03', '赵晓萍', '副主任医师', 14.50),
  ('DR07', 'D03', '孙宁', '主治医师', 4.50),
  ('DR08', 'D04', '周海涛', '主任医师', 21.50),
  ('DR09', 'D04', '吴磊', '主治医师', 4.50),
  ('DR10', 'D05', '郑晓岚', '副主任医师', 14.50),
  ('DR11', 'D06', '林雅琴', '主任医师', 23.50),
  ('DR12', 'D06', '何静', '主治医师', 6.50),
  ('DR13', 'D07', '许文华', '副主任医师', 14.50),
  ('DR14', 'D07', '彭悦', '主治医师', 4.50),
  ('DR15', 'D08', '方立新', '主任医师', 21.50),
  ('DR16', 'D08', '宋佳', '主治医师', 4.50),
  ('DR17', 'D09', '唐明远', '副主任医师', 16.50),
  ('DR18', 'D09', '韩雪', '主治医师', 6.50),
  ('DR19', 'D10', '黄德昌', '主任医师', 21.50),
  ('DR20', 'D10', '邓欣', '主治医师', 11.50),
  ('DR21', 'D11', '曹蕾', '副主任医师', 14.50),
  ('DR22', 'D11', '罗晨', '主治医师', 4.50),
  ('DR23', 'D12', '魏东升', '主任医师', 21.50),
  ('DR24', 'D12', '蒋婷', '主治医师', 4.50),
  ('DR25', 'D13', '冯志刚', '副主任医师', 14.50),
  ('DR26', 'D13', '薛凯', '主治医师', 4.50);

-- 后台账号：初始口令见 server/seed_data.py（存的是 scrypt 散列，明文不入库），正式使用前请修改。
INSERT INTO users (id, username, password_hash, display_name, role, status) VALUES
  ('U01', 'admin', 'scrypt$e6d07f9a828c11f162e456b3ed6ec7bb$d16a2a939f8824f03da4c03b96133f53262925122e33e78291eb0adfe28fda24d8bf98f2004ac719aff2f4d442bf8923adc48e7d8676d2ce1b433634e4eb05e5', '系统管理员', 'admin', 'active');

-- 排班：从今天起 14 天 × 每位医生 × 上午 / 下午；号源按职称分档，诊室号按医生编号推导（DR01 → 诊室 01）
INSERT INTO schedules (id, doctor_id, dept_id, work_date, weekday, time_slot, start_time, end_time, room, max_quota)
SELECT 'SC_' || doc.id || '_' || to_char(day, 'YYYY-MM-DD') || '_' || p.code,
       doc.id, doc.dept_id, day::date,
       (ARRAY['周日','周一','周二','周三','周四','周五','周六'])[EXTRACT(DOW FROM day)::int + 1],
       p.slot, p.start_time, p.end_time,
       '诊室 ' || lpad(substring(doc.id FROM 3)::int::text, 2, '0'),
       CASE doc.title WHEN '主任医师' THEN 20 WHEN '副主任医师' THEN 25 WHEN '主治医师' THEN 30 END
  FROM doctors doc
 CROSS JOIN generate_series(CURRENT_DATE, CURRENT_DATE + 13, INTERVAL '1 day') AS day
 CROSS JOIN (VALUES ('AM', '上午', TIME '08:00', TIME '12:00'),
                    ('PM', '下午', TIME '13:30', TIME '17:00'))
            AS p(code, slot, start_time, end_time)
 ORDER BY day, doc.id, p.code;

-- 科室搜索词典（约 1.9 万条「疾病 / 症状 → 科室」，来自开源医疗知识图谱，由 tools/build_dept_keywords.py 整理）
\copy dept_keywords (term, kind, dept_id, other_dept, weight, pinyin, abbr) FROM 'server/data/dept_keywords.csv' WITH (FORMAT csv, HEADER true, NULL '')


-- ============================================================================
--  第 8 部分  检查与验证
-- ============================================================================

-- 8.1 数据装载结果
SELECT 'departments' AS 表名, COUNT(*) AS 行数 FROM departments
UNION ALL SELECT 'doctors',            COUNT(*) FROM doctors
UNION ALL SELECT 'doctor_fee_history', COUNT(*) FROM doctor_fee_history
UNION ALL SELECT 'users',              COUNT(*) FROM users
UNION ALL SELECT 'schedules',          COUNT(*) FROM schedules
UNION ALL SELECT 'dept_keywords',      COUNT(*) FROM dept_keywords;

-- 8.2 数据库对象数量（应为：表 18 / 视图 5 / 函数 24 / 触发器 21 / 索引 53）
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
-- ROLLBACK;
