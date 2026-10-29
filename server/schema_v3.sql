-- ============================================================
-- 智慧医院预约挂号系统 —— v3 增量结构
-- PostgreSQL 12+（在 v2 的 schema.sql 之上叠加，不删不改任何 v2 对象）
--
-- 这一版回答六个需求：
--   ① 候补与自动补位   → waitlist + fn_offer_next_waitlist + 取消后自动补位触发器
--   ② 就诊前一天 / 当天提醒 → patients.email + notification_outbox（发信由应用层做）
--   ③ 适老化 / 无障碍  → 不涉及表结构，只在前端与接口层（代约记 cancel_reason 之外的来源）
--   ④ 挂号审计         → v2 已有 appointment_log；这里补「谁看过这条记录」的 access_log
--   ⑤ 防黄牛           → blacklist + fn_appt_guard_before_insert（黑名单 / 取消爽约计数 / 每日上限）
--   ⑥ 权限控制         → users.role + access_log（查看患者信息必须留痕）
--
-- 设计原则和 v2 一致：能在数据库里表达的规则就写进数据库。
-- 应用层仍然校验一遍，那是为了给用户友好提示；数据库这一层是「绕过也写不进去」。
--
-- ★ 幂等：本文件可以反复执行。表用 IF NOT EXISTS，约束 / 触发器包在 DO 块里，
--   函数用 CREATE OR REPLACE。
-- ============================================================

-- ------------------------------------------------------------
-- 0. 患者补一个邮箱（提醒用）
--    允许为空：挂号本身不需要邮箱，只有想收提醒的人才填。
--    格式校验放在数据库，接口层还有一遍（validators.check_email）。
-- ------------------------------------------------------------
ALTER TABLE patients ADD COLUMN IF NOT EXISTS email VARCHAR(120);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_patients_email') THEN
    ALTER TABLE patients ADD CONSTRAINT ck_patients_email
      CHECK (email IS NULL OR email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');
  END IF;
END $$;

-- ------------------------------------------------------------
-- 1. 后台角色
--    admin   系统管理员：全部权限
--    auditor 审计员：只能看报表与审计日志，不能改号源、不能看完整患者信息
--    desk    窗口人员：可代约、可看挂号记录（脱敏），不能改号源、不能看审计
--
--    ★ 为什么角色放库里而不是写死在代码：换人 / 加人只改一行数据，
--      代码里只判断「这个角色允不允许」，不判断「这个人是谁」。
-- ------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS role VARCHAR(12) NOT NULL DEFAULT 'admin';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_users_role') THEN
    ALTER TABLE users ADD CONSTRAINT ck_users_role
      CHECK (role IN ('admin','auditor','desk'));
  END IF;
END $$;

-- ------------------------------------------------------------
-- 1.5 科室位置（③ 的位置信息：方便患者快速找到科室）
--     为什么不进库其实也可以（它不参与查询 / 约束），但科室位置属于
--    会变化的业务事实（医院搬迁、楼层调整），放前端常量每次改两处容易漏，
--     所以和 name / description 一起进 departments 表。
--    老库已经有 departments 但没有 location 列 → ALTER 补上，再回填，
--     最后加一条「位置不能空」的 CHECK（回填之后再加，不会卡住旧数据）。
-- ------------------------------------------------------------
ALTER TABLE departments ADD COLUMN IF NOT EXISTS location VARCHAR(120);

-- 给已有的 5 个科室补上位置。新库此时还没有行，本句是空操作；
-- 用「只有当前为空才更新」保证可以反复执行，不会覆盖管理员后来改的值。
UPDATE departments SET location = '门诊楼 2 层东区'   WHERE id = 'D01' AND (location IS NULL OR location = '');
UPDATE departments SET location = '门诊楼 3 层'       WHERE id = 'D02' AND (location IS NULL OR location = '');
UPDATE departments SET location = '门诊楼 1 层北侧（儿童医学中心）' WHERE id = 'D03' AND (location IS NULL OR location = '');
UPDATE departments SET location = '门诊楼 3 层西区'   WHERE id = 'D04' AND (location IS NULL OR location = '');
UPDATE departments SET location = '门诊楼 4 层'       WHERE id = 'D05' AND (location IS NULL OR location = '');

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_dept_location') THEN
    ALTER TABLE departments ADD CONSTRAINT ck_dept_location
      CHECK (location IS NOT NULL AND length(btrim(location)) >= 2);
  END IF;
END $$;

-- ------------------------------------------------------------
-- 2. 候补队列
--    一个患者对一条排班最多只能排一个「还在生效」的候补；
--    号源空出来时按 position 从小到大依次通知，先到先得。
--
--    ★ 为什么 position 单独存一列，而不是用 created_at 排序：
--      同一毫秒内可能有多个人排队（脚本并发），时间戳会打平；
--      整数序号在事务里由 FOR UPDATE 串行分配，顺序绝对确定。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS waitlist (
  id         VARCHAR(16) PRIMARY KEY,            -- 'W' + YYMMDDHH24MISSMS
  schedule_id VARCHAR(32) NOT NULL REFERENCES schedules(id) ON DELETE RESTRICT,
  patient_id  VARCHAR(16) NOT NULL REFERENCES patients(id)  ON DELETE RESTRICT,
  position    INTEGER     NOT NULL,              -- 该排班下的排队序号，触发器分配
  status      VARCHAR(12) NOT NULL DEFAULT 'waiting',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  offered_at       TIMESTAMPTZ,                  -- 通知发出的时间
  offer_expires_at TIMESTAMPTZ,                  -- 保留到什么时候，过期顺延给下一位
  converted_appointment_id VARCHAR(16) REFERENCES appointments(id) ON DELETE SET NULL,

  CONSTRAINT ck_waitlist_status CHECK (
    status IN ('waiting','offered','converted','expired','cancelled')
  ),
  -- 状态与时间必须自洽：
  --   waiting              还没通知，不能有通知时间
  --   offered/converted/expired  一定通知过，必须有通知时间（转正和过期都是通知之后的事，
  --                         offered_at 要留着当历史，不能清掉）
  --   cancelled            可能从 waiting 直接放弃（没通知过），也可能放弃了一个 offered，
  --                        所以两种情况都合法
  CONSTRAINT ck_waitlist_offer_pair CHECK (
    CASE
      WHEN status = 'waiting' THEN offered_at IS NULL
      WHEN status IN ('offered','converted','expired') THEN offered_at IS NOT NULL
      ELSE TRUE
    END
  ),
  CONSTRAINT ck_waitlist_offer_window CHECK (
    offer_expires_at IS NULL OR offered_at IS NULL OR offer_expires_at > offered_at
  ),
  CONSTRAINT ck_waitlist_position CHECK (position > 0),
  -- 同一排班内排队序号唯一
  CONSTRAINT uq_waitlist_schedule_pos UNIQUE (schedule_id, position)
);

-- 同一患者同一排班，只能有一个「排队中 / 已通知」的候补。
-- 转正、过期、自己取消之后可以重新排 —— 所以用部分唯一索引而不是全表唯一。
CREATE UNIQUE INDEX IF NOT EXISTS uq_waitlist_active
  ON waitlist(schedule_id, patient_id)
  WHERE status IN ('waiting','offered');

-- 补位时按 (排班, 状态, 序号) 取最早的一位
CREATE INDEX IF NOT EXISTS idx_waitlist_queue ON waitlist(schedule_id, status, position);
CREATE INDEX IF NOT EXISTS idx_waitlist_patient ON waitlist(patient_id, created_at DESC);

-- 上一版脚本把 offer_pair 写成了「offered 当且仅当 offered_at 非空」，
-- 结果「转正」时 status 变了而 offered_at 还留着，直接被判违规 —— 转正永远失败。
-- 这里识别旧定义（没有 CASE 分支）并换掉，保证已经升级过的库也能修正。
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conname = 'ck_waitlist_offer_pair'
       AND c.conrelid = 'waitlist'::regclass
       AND position('CASE' IN pg_get_constraintdef(c.oid)) = 0
  ) THEN
    ALTER TABLE waitlist DROP CONSTRAINT ck_waitlist_offer_pair;
    ALTER TABLE waitlist ADD CONSTRAINT ck_waitlist_offer_pair CHECK (
      CASE
        WHEN status = 'waiting' THEN offered_at IS NULL
        WHEN status IN ('offered','converted','expired') THEN offered_at IS NOT NULL
        ELSE TRUE
      END
    );
  END IF;
END $$;

-- ------------------------------------------------------------
-- 3. 通知发件箱
--    ★ 为什么不在触发器里直接发邮件：数据库不该依赖网络。
--      触发器只负责「产生一条待发通知」，真正发信交给应用层的 worker。
--      好处：发信失败可以重试，数据库事务不会被 SMTP 超时拖住；
--      坏处：多一个进程要跑（--worker），这个代价在报告里如实写。
--
--    dedupe_key 是幂等的关键：
--      reminder_t1:<挂号单号>  前一天提醒，一张单只会有一封
--      reminder_t0:<挂号单号>  当天提醒
--      waitlist_offer:<候补号> 候补通知
--    重复扫描时 ON CONFLICT DO NOTHING，不会给患者连发三封。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notification_outbox (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  channel    VARCHAR(8)  NOT NULL,               -- email / inapp
  template   VARCHAR(24) NOT NULL,
  dedupe_key VARCHAR(120) NOT NULL,
  recipient  VARCHAR(160) NOT NULL,
  subject    VARCHAR(200) NOT NULL,
  body       TEXT NOT NULL,
  status     VARCHAR(10) NOT NULL DEFAULT 'pending',
  attempts   INTEGER     NOT NULL DEFAULT 0,
  scheduled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sent_at      TIMESTAMPTZ,
  last_error   VARCHAR(300),
  appointment_id VARCHAR(16) REFERENCES appointments(id) ON DELETE CASCADE,
  waitlist_id    VARCHAR(16) REFERENCES waitlist(id)     ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT ck_outbox_channel CHECK (channel IN ('email','inapp')),
  CONSTRAINT ck_outbox_status  CHECK (status  IN ('pending','sent','failed','skipped')),
  CONSTRAINT ck_outbox_template CHECK (
    template IN ('waitlist_offer','waitlist_expired','reminder_t1','reminder_t0','booking_done')
  ),
  CONSTRAINT uq_outbox_dedupe UNIQUE (dedupe_key)
);

-- worker 只捞 pending，而且按计划时间先后发 —— 部分索引正好覆盖这个查询
CREATE INDEX IF NOT EXISTS idx_outbox_pending
  ON notification_outbox(status, scheduled_at) WHERE status = 'pending';

-- ------------------------------------------------------------
-- 4. 患者信息访问日志（⑥ 权限控制）
--    v2 的 appointment_log 记的是「挂号单发生了什么」，
--    这张表记的是「谁、因为什么、看了谁的隐私信息」。
--    两者合起来才是完整的审计：前者防业务抵赖，后者防内部越权。
--
--    ★ 只记「查看完整身份证 / 手机号」这类敏感动作，不记每一次列表查询，
--      否则日志会被正常业务淹没，真正该查的时候反而找不到。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS access_log (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  user_id    VARCHAR(16) REFERENCES users(id) ON DELETE SET NULL,
  username   VARCHAR(32) NOT NULL,               -- 冗余存一份：用户被删了也能追溯
  action     VARCHAR(24) NOT NULL,
  target_type VARCHAR(16) NOT NULL,
  target_id  VARCHAR(32) NOT NULL,
  patient_id VARCHAR(16) REFERENCES patients(id) ON DELETE SET NULL,
  reason     VARCHAR(120),
  client_ip  VARCHAR(45),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT ck_access_action CHECK (
    action IN ('reveal_idcard','view_patient','export_records','view_audit','blacklist')
  ),
  CONSTRAINT ck_access_target CHECK (target_type IN ('patient','appointment','waitlist'))
);

-- 表可能是上一版脚本建的，动作枚举里没有 blacklist。
-- 这里比对一次约束定义，不一致就重建 —— 保证老库升级后也能记拉黑动作。
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conname = 'ck_access_action'
       AND c.conrelid = 'access_log'::regclass
       AND pg_get_constraintdef(c.oid) NOT LIKE '%blacklist%'
  ) THEN
    ALTER TABLE access_log DROP CONSTRAINT ck_access_action;
    ALTER TABLE access_log ADD CONSTRAINT ck_access_action CHECK (
      action IN ('reveal_idcard','view_patient','export_records','view_audit','blacklist')
    );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_access_patient ON access_log(patient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_access_user    ON access_log(user_id,    created_at DESC);

-- ------------------------------------------------------------
-- 5. 黑名单（⑤ 防黄牛 第 4 档，锦上添花）
--    until 为 NULL 表示永久。解封就是删行或把 until 改成过去。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS blacklist (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  id_card    VARCHAR(18) NOT NULL,
  patient_id VARCHAR(16) REFERENCES patients(id) ON DELETE SET NULL,
  reason     VARCHAR(200) NOT NULL,
  until      TIMESTAMPTZ,
  created_by VARCHAR(32) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_blacklist_idcard UNIQUE (id_card),
  CONSTRAINT ck_blacklist_idcard CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_blacklist_reason CHECK (length(btrim(reason)) >= 2)
);

-- ------------------------------------------------------------
-- 6. 候补队列视图（页面直接查这个）
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_waitlist_detail AS
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
       doc.id   AS doctor_id,
       doc.name AS doctor_name,
       doc.title AS doctor_title,
       doc.fee,
       d.id     AS dept_id,
       d.name   AS dept_name,
       p.id     AS patient_id,
       p.name   AS patient_name,
       p.phone,
       p.email,
       -- 身份证只在库内用于核对，出接口前一律脱敏
       overlay(p.id_card PLACING '********' FROM 7 FOR 8) AS id_card_masked
  FROM waitlist w
  JOIN schedules   s   ON s.id   = w.schedule_id
  JOIN doctors     doc ON doc.id = s.doctor_id
  JOIN departments d   ON d.id   = s.dept_id
  JOIN patients    p   ON p.id   = w.patient_id;

-- ============================================================
-- 7. 函数
-- ============================================================

-- 7.1 候补排队前校验（BEFORE INSERT）
--     四条拒绝理由，全部写成人话（P0001，应用层原样回给用户）。
CREATE OR REPLACE FUNCTION fn_waitlist_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  sc schedules%ROWTYPE;
  v_next INTEGER;
BEGIN
  -- 锁住排班行：既防止并发下序号重复，也保证「还有没有号」的判断是准的
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

  -- 还有号就直接挂，不该排队 —— 否则候补队列会变成「慢一点再挂号」的通道
  IF sc.booked_count < sc.max_quota THEN
    RAISE EXCEPTION '该时段还有 % 个号源，请直接挂号', sc.max_quota - sc.booked_count;
  END IF;

  IF EXISTS (SELECT 1 FROM appointments a
              WHERE a.schedule_id = NEW.schedule_id
                AND a.patient_id  = NEW.patient_id
                AND a.status IN ('booked','completed')) THEN
    RAISE EXCEPTION '您已预约该时段，无需候补';
  END IF;

  -- 同一排班内的排队序号：最大值 + 1。已过期 / 已转正的行不参与，
  -- 否则序号会一路涨上去，前端显示「您排在第 37 位」而实际只有 3 个人。
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

-- 7.2 候补状态流转保护（BEFORE UPDATE）
CREATE OR REPLACE FUNCTION fn_waitlist_before_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
         (OLD.status = 'waiting'   AND NEW.status IN ('offered','cancelled','expired'))
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
$$;

-- 7.3 给某条排班补一位候补（被 7.4 和 worker 共用）
--     返回被通知的候补号；没人可补就返回 NULL。
--
--     ★ FOR UPDATE SKIP LOCKED：两个 worker 同时扫，不会通知同一个人两次，
--       后到的那个直接跳过去看下一位，不会互相等锁。
CREATE OR REPLACE FUNCTION fn_offer_next_waitlist(p_schedule VARCHAR) RETURNS VARCHAR
LANGUAGE plpgsql AS $$
DECLARE
  sc  schedules%ROWTYPE;
  w   waitlist%ROWTYPE;
  p   patients%ROWTYPE;
  v_when TEXT;
BEGIN
  SELECT * INTO sc FROM schedules WHERE id = p_schedule;
  IF NOT FOUND OR sc.closed OR sc.work_date < CURRENT_DATE THEN
    RETURN NULL;
  END IF;
  IF sc.booked_count >= sc.max_quota THEN
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
$$;

-- 7.4 有人退号 → 立刻把号让给排在最前面的人（AFTER UPDATE）
--     ★ 只处理「booked 变成终态」这一种情况：
--       停诊批量退号（cancel_reason = closure）不补位 —— 医生不来了，
--       补上也看不了病，这时候该做的是通知所有人改约。
CREATE OR REPLACE FUNCTION fn_appt_promote_waitlist() RETURNS trigger
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

-- 7.5 防黄牛（BEFORE INSERT on appointments）
--     四道闸，从便宜到贵：
--       1) 黑名单；
--       2) 近 30 天「自己取消」次数 ≥ 5 —— 恶意占号的人通常是挂了又退；
--       3) 近 180 天爽约次数 ≥ 3 —— 爽约比取消更恶劣，阈值更严；
--       4) 同一天全科最多 2 个有效号 —— 防止一个人把多个科室的号一起占住。
--
--     ★ 为什么阈值写死在函数里而不是配置表：课程设计里它就是业务规则的一部分，
--       写死便于答辩时说清「为什么是 5 和 3」；真要可配，加一张 rule_config 表即可。
CREATE OR REPLACE FUNCTION fn_appt_guard_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_idcard VARCHAR(18);
  v_cancel INTEGER;
  v_noshow INTEGER;
  v_same_day INTEGER;
  v_work_date DATE;
BEGIN
  SELECT id_card INTO v_idcard FROM patients WHERE id = NEW.patient_id;
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
$$;

-- 7.6 候补转正时，把候补行标成 converted（AFTER INSERT on appointments）
--     不需要应用层再写一句 UPDATE：挂号单一落地，对应的候补自动闭环。
CREATE OR REPLACE FUNCTION fn_appt_close_waitlist() RETURNS trigger
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

-- ============================================================
-- 8. 触发器挂载（CREATE OR REPLACE 需要 PG14+；PG18 没问题）
-- ============================================================
DROP TRIGGER IF EXISTS trg_waitlist_touch ON waitlist;
CREATE TRIGGER trg_waitlist_touch BEFORE UPDATE ON waitlist
  FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();

DROP TRIGGER IF EXISTS trg_waitlist_before_insert ON waitlist;
CREATE TRIGGER trg_waitlist_before_insert BEFORE INSERT ON waitlist
  FOR EACH ROW EXECUTE FUNCTION fn_waitlist_before_insert();

DROP TRIGGER IF EXISTS trg_waitlist_before_update ON waitlist;
CREATE TRIGGER trg_waitlist_before_update BEFORE UPDATE ON waitlist
  FOR EACH ROW EXECUTE FUNCTION fn_waitlist_before_update();

-- 退号 → 补位
DROP TRIGGER IF EXISTS trg_appt_promote_waitlist ON appointments;
CREATE TRIGGER trg_appt_promote_waitlist AFTER UPDATE ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_promote_waitlist();

-- 挂号成功 → 候补闭环
DROP TRIGGER IF EXISTS trg_appt_close_waitlist ON appointments;
CREATE TRIGGER trg_appt_close_waitlist AFTER INSERT ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_close_waitlist();

-- 防黄牛：BEFORE INSERT 按触发器名字母序执行，
-- trg_appt_before_insert（v2 的校验）在 trg_appt_guard 之前，先分配 seq_no 再判额度，
-- 两者互不依赖，顺序不影响结果。
DROP TRIGGER IF EXISTS trg_appt_guard ON appointments;
CREATE TRIGGER trg_appt_guard BEFORE INSERT ON appointments
  FOR EACH ROW EXECUTE FUNCTION fn_appt_guard_before_insert();

-- ------------------------------------------------------------
-- 1.6 诊室号（room）
--     排班挂的是「某医生某半天」，同一医生每天在哪间诊室相对固定，
--     把诊室号直接记在排班行上，挂号成功页就能直接告诉患者「去几号诊室」。
--     纯展示字段，不参与任何业务规则，所以不加约束。
-- ------------------------------------------------------------
ALTER TABLE schedules ADD COLUMN IF NOT EXISTS room VARCHAR(24) NOT NULL DEFAULT '';

-- 已有的排班补一个稳定的诊室号（按医生编号推导，DR01 → 诊室 01）
UPDATE schedules
   SET room = '诊室 ' || lpad(substring(doctor_id FROM 3)::int::text, 2, '0')
 WHERE room IS NULL OR room = '';

-- ------------------------------------------------------------
-- 预约单号（appointment_no）—— 患者查询用
-- 必须在 v_appointment_detail 重建之前完成，因为视图要引用这一列。
-- ------------------------------------------------------------

ALTER TABLE appointments ADD COLUMN IF NOT EXISTS appointment_no VARCHAR(16);

/* 为已有记录回填随机单号（仅在列刚添加且值为 NULL 时执行） */
DO $$
DECLARE
  rec RECORD;
  chars TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  new_no TEXT;
BEGIN
  IF EXISTS (SELECT 1 FROM appointments WHERE appointment_no IS NULL LIMIT 1) THEN
    FOR rec IN SELECT id FROM appointments WHERE appointment_no IS NULL LOOP
      LOOP
        new_no := '';
        FOR i IN 1..10 LOOP
          new_no := new_no || substr(chars, 1 + floor(random() * 36)::int, 1);
        END LOOP;
        EXIT WHEN NOT EXISTS (SELECT 1 FROM appointments WHERE appointment_no = new_no);
      END LOOP;
      UPDATE appointments SET appointment_no = new_no WHERE id = rec.id;
    END LOOP;
  END IF;
END $$;

/* 加唯一约束和非空约束 */
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_appt_no') THEN
    ALTER TABLE appointments ADD CONSTRAINT uq_appt_no UNIQUE (appointment_no);
  END IF;
END $$;

ALTER TABLE appointments ALTER COLUMN appointment_no SET NOT NULL;

-- v_appointment_detail 顺手把科室位置（location）和诊室号（room）带出来，
-- 前端确认页 / 成功页就不用再各自 JOIN 一次。没有任何对象依赖这个视图，
-- 所以 DROP + CREATE 是幂等安全的。
DROP VIEW IF EXISTS v_appointment_detail;
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

-- ============================================================
-- 9. 设计说明（答辩用）
--
--   一、候补为什么不用「轮询 + 应用层抢」
--      退号是低频事件，但抢号是高频事件。把「谁来补位」写进触发器，
--      退号的那一刻（同一个事务里）就已经把人选定了，不存在
--      「号空着 30 秒没人知道」的窗口期；也不需要定时任务去扫。
--      定时任务只负责两件数据库不适合做的事：发邮件、处理过期。
--
--   二、候补保留 2 小时是怎么来的
--      太短：患者在工作 / 在车上，看不到消息就白排了；
--      太长：一个号被锁 2 小时，后面的人干等，反而降低利用率。
--      真实医院普遍是 1–3 小时，取 2 小时作为折中，写进函数里便于调整。
--
--   三、防黄牛为什么不直接在接口里判
--      接口可以被绕过（psql、脚本、别的服务）。取消次数、爽约次数、
--      黑名单都是「这个人还能不能挂号」的硬规则，写在触发器里，
--      任何写入路径都绕不过去。限流和验证码才放在接口层 ——
--      那两件事本质是「挡住机器请求」，数据库管不了。
--
--   四、审计为什么要两张表
--      appointment_log：这张单子发生了什么（业务事实）。
--      access_log    ：谁看了这张单子里的隐私（访问事实）。
--      只看前者，内部人员批量翻患者信息是查不出来的。
-- ============================================================

-- ------------------------------------------------------------
-- 11. 验证码表（查询挂号 / 取消 时的身份验证）
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS verification_codes (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  target     VARCHAR(120) NOT NULL,              -- 手机号或邮箱
  code_hash  VARCHAR(64)  NOT NULL,              -- 验证码哈希（不存明文）
  purpose    VARCHAR(20)  NOT NULL DEFAULT 'lookup', -- lookup / cancel
  expire_at  TIMESTAMPTZ  NOT NULL,
  used       BOOLEAN      NOT NULL DEFAULT FALSE,
  attempts   INTEGER      NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_vc_target ON verification_codes (target, created_at DESC);

-- ------------------------------------------------------------
-- 12. 大小写不敏感唯一索引（身份证号 X/x、邮箱统一处理）
-- ------------------------------------------------------------

/* 身份证号最后一位 X/x 必须视为同一号码。
   应用层已在所有入口调用 .upper() + check_id_card，
   数据库再加一层 UPPER 表达式唯一索引，防止绕过应用层时出现重复。 */
CREATE UNIQUE INDEX IF NOT EXISTS idx_patients_id_card_ci ON patients (UPPER(id_card));
CREATE UNIQUE INDEX IF NOT EXISTS idx_blacklist_id_card_ci ON blacklist (UPPER(id_card));

-- ------------------------------------------------------------
-- 13. 患者凭证（患者端没有账号，靠它证明「我是这个就诊人」）
--
-- 以前患者端只凭身份证号就能查挂号、退号、改手机号 ——
-- 身份证号不是秘密，等于谁都能动别人的单子。
-- 现在：首次建档时发一个，或向档案登记的手机/邮箱发验证码换一个。
-- 只存 SHA-256，库泄露也拿不到能用的凭证。
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS patient_sessions (
  token_hash VARCHAR(64) PRIMARY KEY,
  patient_id VARCHAR(16) NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_patient_sessions_patient ON patient_sessions (patient_id);

-- ------------------------------------------------------------
-- 14. 模拟实名校验（「公安二要素」：姓名 + 身份证号）
--
-- 真实系统要调公安 / 运营商接口，课程设计里用一张表模拟「公安人口库」：
--   · 库里有这个身份证号 → 姓名必须一致才通过；
--   · 库里没有 → 模拟「查询成功」，把这一对登记进库，
--     此后这个身份证号只认这个姓名（先到先得，一号一名）。
-- 校验逻辑写成存储函数，挂号、查记录、改资料都走同一个函数；
-- 每一次校验都记进 identity_verify_log，后台可追溯。
-- 前提假设：身份证号与姓名未泄露，二者一致即视为本人。
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS citizen_registry (
  id_card    VARCHAR(18) PRIMARY KEY,
  name       VARCHAR(50) NOT NULL,
  source     VARCHAR(8)  NOT NULL DEFAULT 'auto',    -- seed = 初始导入，auto = 首次校验时登记
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_registry_id_card CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_registry_source  CHECK (source IN ('seed', 'auto'))
);

CREATE TABLE IF NOT EXISTS identity_verify_log (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  id_card    VARCHAR(18) NOT NULL,
  name_input VARCHAR(50) NOT NULL,
  passed     BOOLEAN     NOT NULL,
  reason     VARCHAR(16) NOT NULL,                   -- match / new / name_mismatch
  purpose    VARCHAR(16) NOT NULL DEFAULT 'booking', -- booking / auth
  client_ip  VARCHAR(64),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT ck_ivl_reason CHECK (reason IN ('match', 'new', 'name_mismatch'))
);

CREATE INDEX IF NOT EXISTS idx_ivl_id_card ON identity_verify_log (id_card, created_at DESC);

-- 已有就诊人档案导入「人口库」：档案里的姓名就是已核实的姓名
INSERT INTO citizen_registry (id_card, name, source)
SELECT UPPER(id_card), name, 'seed' FROM patients
ON CONFLICT (id_card) DO NOTHING;

CREATE OR REPLACE FUNCTION fn_verify_identity(
  p_name TEXT, p_id_card TEXT, p_purpose TEXT DEFAULT 'booking', p_ip TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
  v_name   TEXT;
  v_new    BOOLEAN := FALSE;
  v_ok     BOOLEAN;
BEGIN
  p_name    := TRIM(p_name);
  p_id_card := UPPER(TRIM(p_id_card));

  SELECT name INTO v_name FROM citizen_registry WHERE id_card = p_id_card;
  IF NOT FOUND THEN
    -- 模拟「公安库查询成功」：登记这一对。并发下两人同时登记同一号，
    -- 主键保证只进一条，另一方重新读出来按「已登记」比对。
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
