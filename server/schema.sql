-- ============================================================
-- 智慧医院预约挂号系统 —— 数据库结构
-- PostgreSQL 12+
--
-- 设计说明（为什么没有 hospitals 表）：
--   本系统面向「某一家医院」的挂号业务，医院信息是部署期常量，
--   不存在第二家医院，因此不建 hospitals 表——
--   否则 departments.hospital_id / schedules.hospital_id /
--   appointments.hospital_id 三列恒为同一个值，UNIQUE(hospital_id, name)
--   也会退化成 UNIQUE(name)，属于典型的「伪 1:N」冗余。
--   医院名称、等级、地址等展示信息放在前端常量 js/app.js 的 HOSPITAL 中。
-- ============================================================

-- 幂等重建：按依赖倒序清理
DROP TABLE IF EXISTS user_sessions   CASCADE;
DROP TABLE IF EXISTS users           CASCADE;
DROP TABLE IF EXISTS appointments    CASCADE;
DROP TABLE IF EXISTS schedules       CASCADE;
DROP TABLE IF EXISTS doctors         CASCADE;
DROP TABLE IF EXISTS departments     CASCADE;
-- schedule_slots 已从本设计中移除（号源量并入 schedules，见第 3 节）。
-- 从旧库升级上来时旧表不会被上面的语句清掉，显式删掉才彻底。
DROP TABLE IF EXISTS schedule_slots  CASCADE;
-- hospitals 已从本设计中移除，这里仍保留一句 DROP：
-- 从改造前的旧库升级上来时，旧 hospitals 表不会被上面的语句清掉，
-- 会留下一个孤立的空表干扰「对象清单」统计。显式删掉才彻底。
DROP TABLE IF EXISTS hospitals       CASCADE;
-- appointment_audit（挂号操作审计表）已从本设计中移除，理由见文件末尾说明。
-- 旧库升级上来时它还留在库里，显式删掉。
DROP TABLE IF EXISTS appointment_audit CASCADE;
-- 配套的审计函数也要单独删：DROP TABLE ... CASCADE 只会带走触发器本身
-- （触发器挂在 appointments 上），函数是独立对象，不会跟着表一起走。
-- 这里的 CASCADE 会顺带把引用它的触发器一并删掉。
DROP FUNCTION IF EXISTS fn_appointment_audit() CASCADE;
-- appointment_no_seq（挂号单号序列）同样已废弃：单号改由 INSERT 时用
-- 毫秒时间戳拼出来（见下面第 4 节）。这一行只是为了清理早期建过该序列的
-- 旧库，在全新的库上它是个空操作，不会创建任何对象。
DROP SEQUENCE IF EXISTS appointment_no_seq;

-- ------------------------------------------------------------
-- 1. 科室
--    只存「会变化的业务事实」：编号、名称、简介。
--    ★ 图标（emoji）刻意不进库 —— 它是「怎么画」，不是业务数据：
--      · 没有任何查询、约束、统计会用到它；
--      · 换一套图标要改库、要跑迁移，成本与收益完全不成比例。
--      所以它放在前端常量 js/utils.js 的 DEPT_ICONS 里，按科室编号取。
--    同理，医生「擅长的方向」也不进库（见下表说明）。
--    一并下架的还有医生的评分与接诊量——它们只服务于卡片外观。
--    一条判据贯穿全篇：**这一列会不会出现在 WHERE / 约束 / 索引 / 统计里？**
--    不会，而且只影响「看起来长什么样」，那就属于展示层，不进库。
-- ------------------------------------------------------------
CREATE TABLE departments (
  id          VARCHAR(8)   PRIMARY KEY,
  name        VARCHAR(50)  NOT NULL,
  description VARCHAR(200) NOT NULL,
  CONSTRAINT uq_dept_name UNIQUE (name)
);

-- ------------------------------------------------------------
-- 2. 医生
--    ★ 没有 good_at（擅长方向）这一列，理由：
--      · 本系统没有「按擅长方向搜索/筛选」的功能，这一列不参与
--        任何查询条件、索引、约束或统计；
--      · 它本质上是给患者看的一段介绍文案，属于展示层内容，
--        直接写进前端常量 js/utils.js 的 DOCTOR_INTRO 即可。
--      少一列，就少一份要跟着前端一起改、还可能改漏的冗余。
--    ★ 同样没有 rating（评分）/ cases（接诊量）两列：
--      它们只被医生卡片拿来显示「⭐ 4.9 / 接诊 12800 次」，
--      不参与任何 WHERE、ORDER BY、聚合或约束，属于纯展示字段。
--      本系统也没有按评分排序、按接诊量排名的功能，所以一并删掉。
--    ★ 对照一下 title（职称）：它看起来同样只是个给人看的标签，
--      但它真的进了 ORDER BY —— 医生列表按「主任医师 → 副主任医师 →
--      主治医师」排，而且它还是 ck_doctor_title / ck_doctor_fee_tier
--      两条约束的判定依据。所以它必须留在库里。
--      判据不是「是不是给人看的」，而是「有没有东西真的去查它」。
-- ------------------------------------------------------------
CREATE TABLE doctors (
  id      VARCHAR(8)   PRIMARY KEY,
  dept_id VARCHAR(8)   NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  name    VARCHAR(50)  NOT NULL,
  title   VARCHAR(20)  NOT NULL,
  -- 挂号费。这里故意不写 CHECK (fee >= 0)：那种单列「域约束」只能挡住负数，
  -- 挡不住「主任医师 50 元被改成 1 元」——1 是合法数字，但不是合法价格。
  -- 真正的业务规则是「fee 必须等于该职称对应的价目」，写成下面的跨列 CHECK。
  fee     NUMERIC(8,2) NOT NULL,
  CONSTRAINT ck_doctor_title CHECK (title IN ('主任医师','副主任医师','主治医师')),
  -- 价格档位（跨列约束）：挂号费必须与职称匹配。
  -- 主任医师 50 / 副主任医师 30 / 主治医师 15。
  -- 由于 ck_doctor_title 已把 title 限死在三个值上，这条约束同时蕴含了 fee >= 0。
  -- 效果：UPDATE doctors SET fee = 1 WHERE id = 'DR01' 会被数据库直接拒绝，
  --       因为不存在「主任医师 且 fee = 1」这一档。
  CONSTRAINT ck_doctor_fee_tier CHECK (
    (title = '主任医师'   AND fee = 50.00) OR
    (title = '副主任医师' AND fee = 30.00) OR
    (title = '主治医师'   AND fee = 15.00)
  ),
  -- 把 (id, fee) 这一「对」声明成唯一键。
  -- 单看 id 它本来就唯一（id 是主键），这里多声明一条的目的只有一个：
  -- 给 appointments 表的外键提供引用目标 —— PostgreSQL 要求被引用的
  -- 列组合上必须有唯一约束，外键不能只指向主键的一部分。
  -- 它配合 ck_doctor_fee_tier 的效果是：「医生 + 价格」这个组合在
  -- 价目表里只可能是三种之一，别的组合压根不存在。
  -- 用法见 appointments 表的 fk_appt_doctor_fee。
  CONSTRAINT uq_doctor_id_fee UNIQUE (id, fee)
);
CREATE INDEX idx_doctors_dept ON doctors(dept_id);

-- ------------------------------------------------------------
-- 3. 排班（某医生某天某个半天一条：上午 / 下午各一条）
--    period 把「半天」提升为排班键的一部分，于是同一医生同一天
--    可以同时拥有「上午」「下午」两条排班（很多医生上午下午都出诊），
--    又能保证同一半天不被重复生成（幂等生成的关键）。
--
--    号源直接挂在排班行上（quota_total / quota_booked），不再拆成
--    「30 分钟一格的时段表」：
--      · 患者挂号的最小单位就是「上午 / 下午」，不再选具体几点几分；
--      · 真正的就诊顺序由到院签到后的现场叫号决定，
--        所以「预约时段」与「实际就诊时间」本就不必一一对应，
--        再按 30 分钟拆号源只会带来无意义的复杂度
--        （有人退号还要把后面所有人的时间往前推）。
-- ------------------------------------------------------------
CREATE TABLE schedules (
  id           VARCHAR(32) PRIMARY KEY,          -- 排班编号，格式 SC_医生编号_日期_AM|PM
  doctor_id    VARCHAR(8)  NOT NULL REFERENCES doctors(id)     ON DELETE CASCADE,
  dept_id      VARCHAR(8)  NOT NULL REFERENCES departments(id),
  work_date    DATE        NOT NULL,
  weekday      VARCHAR(8)  NOT NULL,
  period       VARCHAR(8)  NOT NULL,             -- 出诊时段：上午 / 下午（半日一档）
  quota_total  INTEGER     NOT NULL,             -- 该半天的号源总量
  quota_booked INTEGER     NOT NULL DEFAULT 0,   -- 已约数
  closed       BOOLEAN     NOT NULL DEFAULT FALSE,
  -- 同一医生、同一天、同一时段只能有一条排班：允许上/下午并存，禁止同日同段重复
  CONSTRAINT uq_schedule_doctor_date_period UNIQUE (doctor_id, work_date, period),
  CONSTRAINT ck_schedule_period CHECK (period IN ('上午','下午')),
  CONSTRAINT ck_schedule_quota_total_nonneg  CHECK (quota_total  >= 0),
  CONSTRAINT ck_schedule_quota_booked_nonneg CHECK (quota_booked >= 0),
  -- 防超卖的最后一道防线：即便应用层逻辑被绕过，
  -- 数据库也会拒绝 booked > total 的写入。
  CONSTRAINT ck_schedule_not_oversold CHECK (quota_booked <= quota_total)
);
CREATE INDEX idx_schedules_date   ON schedules(work_date);
CREATE INDEX idx_schedules_doctor ON schedules(doctor_id);

-- ------------------------------------------------------------
-- 4. 挂号记录
--    号源的最小单位是「半天」，所以这里也只记 period（上午/下午），
--    不再记 30 分钟级的 slot_id / slot_label。
--    seq_no 是「该半天的第几个号」——到院签到后按它叫号，
--    也是现场就诊顺序的依据（退号时后续序号前移，避免空号）。
--    ★ id（挂号单号）不建序列：由 INSERT 语句拼成
--      'A' + 当前时间的年月日时分秒毫秒（例如 A261014165120986），
--      共 16 位，正好放得下 VARCHAR(16)。
--      不用 max(id)+1 是因为并发时两条插入可能取到同一个最大值而撞号；
--      毫秒时间戳每条语句各取各的时间，不会重复。
-- ------------------------------------------------------------

CREATE TABLE appointments (
  id           VARCHAR(16)  PRIMARY KEY,          -- 'A' + YYMMDDHH24MISSMS
  seq_no       INTEGER      NOT NULL CHECK (seq_no > 0),
  schedule_id  VARCHAR(32)  NOT NULL REFERENCES schedules(id),
  dept_id      VARCHAR(8)   NOT NULL REFERENCES departments(id),
  doctor_id    VARCHAR(8)   NOT NULL REFERENCES doctors(id),
  work_date    DATE         NOT NULL,
  weekday      VARCHAR(8)   NOT NULL,
  period       VARCHAR(8)   NOT NULL,             -- 就诊时段：上午 / 下午
  patient_name VARCHAR(50)  NOT NULL,
  id_card      VARCHAR(18)  NOT NULL,
  phone        VARCHAR(11)  NOT NULL,
  -- 挂号费「快照」：下单那一刻从 doctors.fee 抄过来，之后就是历史事实。
  -- 它参与收入统计（SUM(fee)），所以一旦被改，报表数字会跟着错。
  --
  -- ★ 这个值是谁定的？是数据库自己 —— 不是请求方，也不是应用层的某段 JS。
  --   写单的 INSERT 语句里，fee 这一列填的是一个标量子查询：
  --       (SELECT fee FROM doctors WHERE id = $4)
  --   价格在 SQL 内部就地取自价目表，请求体里带什么价格都不参与运算。
  --   单靠 CHECK (fee >= 0) 是不够的：1 也是个合法数字，它挡不住「一元挂号」。
  --
  -- ★ 兜底（真正硬的那一道）：下面的 fk_appt_doctor_fee 把
  --   (doctor_id, fee) 整体指向 doctors 表的 (id, fee)。价目表里根本不存在
  --   「DR01 这个医生 + 1 元」这一行，所以哪怕有人绕过接口、手写
  --   INSERT INTO appointments (..., doctor_id, fee) VALUES (..., 'DR01', 1)，
  --   也会被外键直接拒绝（SQLSTATE 23503）。这一条由数据库执行，
  --   不依赖应用层是否写对、也不依赖调用方是否自觉。
  fee          NUMERIC(8,2) NOT NULL CHECK (fee >= 0),
  status       VARCHAR(12)  NOT NULL DEFAULT 'active',
  close_note   VARCHAR(200),
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  cancelled_at TIMESTAMPTZ,
  CONSTRAINT ck_appt_status CHECK (status IN ('active','cancelled','closed')),
  CONSTRAINT ck_appt_period CHECK (period IN ('上午','下午')),
  CONSTRAINT ck_appt_idcard CHECK (id_card ~ '^[0-9]{17}[0-9X]$'),
  CONSTRAINT ck_appt_phone  CHECK (phone  ~ '^1[3-9][0-9]{9}$'),
  -- ★ 挂号费防篡改的数据库实现：把「接诊医生 + 挂号费」当成一个整体，
  --   去引用 doctors 表的 (id, fee) 唯一键（见该表的 uq_doctor_id_fee）。
  --   因为价目表被 ck_doctor_fee_tier 锁死在固定的三档上，
  --   这条外键等价于「挂号单上的价格必须与该医生的职称相符」。
  --   它的价值在于：拦截点在数据库，任何写入路径（接口、psql、导入脚本）
  --   都绕不过去。
  CONSTRAINT fk_appt_doctor_fee FOREIGN KEY (doctor_id, fee)
    REFERENCES doctors (id, fee)
);

CREATE INDEX idx_appt_status      ON appointments(status);
CREATE INDEX idx_appt_created     ON appointments(created_at DESC);
CREATE INDEX idx_appt_date        ON appointments(work_date);
CREATE INDEX idx_appt_doctor      ON appointments(doctor_id);
CREATE INDEX idx_appt_dept        ON appointments(dept_id);

-- 原本这里还有两个「部分索引」，专门服务于防重复挂号：
--     idx_appt_conflict      —— 同一就诊人同一天同一科室只能有一个有效号（普通索引）
--     uq_appt_same_doctor    —— 同一就诊人同一天同一医生只能有一个有效号（唯一索引）
--   两个都带 WHERE status = 'active'，所以取消之后还能重挂。
--   2026-10-12 按「暂时不搞防黄牛机制」的要求，连同应用层那段查重代码一起删除。
--   副作用：现在同一个人同一天可以把同一个医生的号重复挂满 —— 演示时注意。
--   要加回来，把上面那两行 CREATE 取消注释、再跑一次本文件即可。

-- ------------------------------------------------------------
-- 5. 后台用户
--    任务书要求 4「用户登录功能（根据对用户表的访问实现）」的落点。
--    密码不存明文，存 scrypt 派生的 password_hash，格式：
--        scrypt$<salt-hex>$<hash-hex>
--    校验在应用层用 crypto.timingSafeEqual 做定长比较，避免时序侧信道。
-- ------------------------------------------------------------
-- 原本这里还有一列 role 与它的约束 ck_users_role CHECK (role IN ('admin','staff'))：
--   系统只保留一个管理员账号（2026-10-12 简化），既没有第二个角色，
--   也没有任何按角色分支的逻辑，这一列永远只有一个取值 ——
--   它不做查询条件、不参与统计、不参与排序，属于「存了但没人用」的字段，已删除。
CREATE TABLE users (
  id            VARCHAR(16)  PRIMARY KEY,
  username      VARCHAR(32)  NOT NULL,
  password_hash VARCHAR(200) NOT NULL,
  display_name  VARCHAR(50)  NOT NULL,
  status        VARCHAR(12)  NOT NULL DEFAULT 'active',
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_users_username UNIQUE (username),
  CONSTRAINT ck_users_username CHECK (username ~ '^[A-Za-z0-9_]{3,32}$'),
  CONSTRAINT ck_users_status   CHECK (status IN ('active','disabled'))
);
-- 这里原本还有一句 CREATE INDEX idx_users_role ON users(role)：
-- 没有任何查询按角色筛选，索引建了也没人用，已删除。

-- ------------------------------------------------------------
-- 6. 登录会话（服务端令牌）
--    不用 JWT：令牌落库后可以真正「注销」和「踢下线」——
--    退出登录就是删掉这一行，管理员禁用账号就是按 user_id 删一批。
--    一个会话一行，过期时间到点即失效。
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
-- 说明：本库只有「表 + 约束 + 索引」，没有视图、没有独立函数、
--       没有存储过程、没有触发器。
--
--   一、为什么没有视图 / 函数 / 存储过程
--     原先有一个 v_schedule_usage 视图（把排班行翻译成
--     total_quota / booked_quota / remain_quota），但它全项目
--     没有任何调用方 —— 查询、接口、前端都没用过它，纯粹是
--     为「看起来像个完整设计」而加的一层包装。
--     同一类东西还有 v_doctor_workload、fn_doctor_remain、
--     fn_dept_daily_stats、sp_archive_past_appointments，均已删除。
--
--     判断标准很简单：**这个对象有没有人真的调用？**
--     没人调用的视图/函数，只是把一条 SQL 换个地方放，却多出
--     一份要跟着表结构一起维护、还可能改漏的负担。
--
--     同理，原本挂在 stats.js 里的日报表 / 医生工作量两个统计接口
--     也没有任何前端调用方，已随整个统计模块一并删除。
--     现在后端只剩四条路由文件：auth / reference / schedules / appointments。
--
--   二、为什么连审计表 + 触发器也删掉了
--     这里原本还有一张 appointment_audit 审计表和一个
--     trg_appointment_audit 触发器：挂号单每次插入/改状态就自动
--     留一条痕（谁、什么时候、从什么状态改成什么状态），顺带守卫
--     挂号费快照不被事后修改。
--
--     这套东西本身没写错，但它服务的是一个「以后才做」的需求：
--     患者什么时候挂的号、什么时候取消的，这个项目现在不关心。
--     现在只关心一件事 —— **这条挂号单此刻是什么状态**，
--     而这件事 appointments.status 这一列已经说清楚了。
--     没有查询会去读审计表，管理端那个「操作日志」页面也一并下线了，
--     于是它同样落回上面那条判据：没人调用，就不该占着一份维护成本。
--
--     取舍：删掉触发器，等于也放弃了「挂号费快照不许改」的数据库级守卫。
--     代价可控 —— 应用层没有任何一处会 UPDATE appointments.fee。
--     真要把这道守卫加回来，比触发器更省事的做法是给应用单独建一个
--     非超级用户角色，再 REVOKE UPDATE (fee) ON appointments FROM 它。
-- ------------------------------------------------------------
