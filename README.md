# 智慧医院预约挂号系统

一个可直接运行的医院挂号系统，包含**患者端**预约挂号全流程与**管理端**号源调度后台。

前端为原生 JS 单页应用（无构建步骤、无框架、无 CDN），后端为 **Python + Flask + PostgreSQL**。数据全部持久化在 PostgreSQL 中，支持并发挂号且不会超卖。

> **后端换过一次语言**：2026-10-17 之前是 **Node + Express**，之后整体改写成 **Python + Flask**。
> 数据库、表结构、接口路径、请求/响应字段、前端页面**一样都没变** —— 前端一行没改，
> 库里已有的数据也没迁。旧版源码归档在 `legacy-node/`，可随时对照或回滚。
> 改写时把两个版本同时跑在两个空库上逐接口比对，54 项响应完全一致（含 JSON 字段顺序）。
>
> **代码风格**：2026-10-13 做过一次「**初学风化**」重写 —— 全部代码改成了**初学者能一行一行读懂的写法**：
> 页面骨架写在 `index.html` 里、`onclick` 直接写在标签上、状态就是几个全局变量、提示用 `alert` / `confirm`。
> **前端只有一个 JS 文件** `js/app.js`（分十二节）；**后端按职责拆成 5 个 Python 文件**
> （`app.py` / `db.py` / `init_db.py` / `seed_data.py` / `validators.py`），每个文件只干一件事。
> 写前端时还有两条硬规矩：**不用 `.map` / `.filter` / `.find` / `.reduce`，一律写 `for` 循环**；
> **不写嵌套的三元表达式，要判断就写 `if / else`**。
> 2026-10-14 又做了一次「** HTML 归 HTML**」：原先在 JS 里用字符串拼出来的**静态结构**
> （管理端两个子页签的筛选栏、表格表头、加载中 / 空数据提示）全部搬回 `index.html`，
> JS 只负责往写好的容器里填数据和切显隐 —— 想改页面长什么样，改 HTML 就行，不用去翻 JS。
> 重写前的「进阶版」完整保留在 `legacy/2026-10-13-初学风化前/`，可对照阅读。
> 详见下方《关于「为什么前端只有一个文件」》《关于「后端为什么拆成 5 个文件」》。
>
> **2026-10-28 数据库升级到 v2**（按课程设计的约束 / 索引 / 视图 / 触发器清单补齐）：
> 新增 `patients` 患者表与 `appointment_log` 审计表；号源列改名 `max_quota` / `booked_count`；
> 时段列 `period` → `time_slot`，并补 `start_time` / `end_time`；
> 挂号状态由 `active / cancelled / closed` 改为 `booked / cancelled / completed / no_show` 四态；
> 补 4 个视图、9 个函数、14 个触发器。
> **接口 JSON 字段一个没变**（前端只改了 3 处状态值判断），已有数据由 `server/migrate_v2.py`
> 在一个事务里原样迁过来，29 条历史挂号、5 份患者档案、52 条审计记录全部保留。
> 详见下方《数据库对象：为什么这一版有视图和触发器》。

---

## 快速开始

### 1. 前置条件

- **Python** ≥ 3.9（本项目在 Python 3.13 上开发验证）
- **PostgreSQL** 已安装并启动（本项目在 PostgreSQL 18 上开发验证）

### 2. 安装与初始化

```bash
cd hospital-registration

# 建虚拟环境（可选，但推荐：依赖装在项目里，不污染系统 Python）
python -m venv .venv
.venv\Scripts\activate          # Windows
# source .venv/bin/activate     # macOS / Linux

# 安装依赖（只有 Flask 和 psycopg 两个直接依赖）
pip install -r requirements.txt

# 建库、建表、灌入示例数据
python server/app.py --init
```

数据库连接参数**直接写在 `server/db.py` 开头的 `DB_CONFIG` 里**，没有 `.env`、没有配置文件。
本机 PostgreSQL 密码不是 `123456` 的话，改那一处就行：

```python
# server/db.py
DB_CONFIG = {
    "host": "127.0.0.1",
    "port": 5432,
    "user": "postgres",
    "password": "123456",   # ← 改成你本机的 PostgreSQL 密码
}
```

### 3. 启动

```bash
python server/app.py
# 浏览器打开 http://127.0.0.1:3000/
```

Windows 下也可以直接双击 **`启动.bat`**：它会自动建虚拟环境、装依赖、初始化数据库，
然后启动服务并打开浏览器。**第一次运行需要联网**（装依赖），之后完全离线可用。

### 4. 管理后台账号

`--init` 会创建一个后台账号，密码用 **scrypt** 派生后存库（明文不落库）：

| 用户名 | 密码 | 说明 |
|--------|------|------|
| `admin` | `admin123` | 系统管理员：挂号记录、排班号源、调号源、停诊、退号 |

> 早期版本还有一个 `triage`（门诊值班员）只读账号，配套 `users.role` 角色列与
> `requireRole` 中间件 —— 已随 2026-10-12 的简化一起删除，只留一个管理员账号。
>
> ⚠️ **正式部署请立即修改默认密码**：改 `server/seed_data.py` 里的 `USERS` 常量，再 `python server/app.py --force`。
> 患者端预约挂号**不需要登录**。

---

## 数据库连接配置

连接参数写死在 `server/db.py` 里，建表和启动复用同一份，**没有 `.env`、没有 dotenv**：

| 参数 | 值 | 写在哪 |
|------|-----|--------|
| 主机 / 端口 / 用户 / 密码 | `127.0.0.1` / `5432` / `postgres` / `123456` | `server/db.py` → `DB_CONFIG` |
| 库名 | `hospital_registration` | `server/db.py` → `DB_NAME`（库不存在会自动创建） |
| 服务端口 | `3000` | `server/app.py` → `PORT` |
| 会话有效期 | 12 小时 | `server/seed_data.py` → `SESSION_TTL_HOURS` |

另外还有三个可选环境变量，**平时完全不用管**，不写就是默认值：

| 变量 | 作用 |
|------|------|
| `PGDATABASE` | 临时换一个库名，不动代码也能连别的库 |
| `PORT` | 临时换一个端口，3000 被占了就换一个 |
| `HOST` | 监听地址。默认 `127.0.0.1`（只本机）；设成 `0.0.0.0` 可让局域网内的手机访问 |

```bash
# 例子：连另一个库、跑在 3100
PGDATABASE=hms_test PORT=3100 python server/app.py
```

> 不带这些变量时，行为和不写一样。
> 想要 100% 写死，把 `os.environ.get(...)` 那几行去掉即可。

---

## 命令行用法

后端只有一个入口 `server/app.py`，**命令行参数决定它干什么**：

| 命令 | 作用 |
|------|------|
| `python server/app.py` | 启动服务 |
| `python server/app.py --init` | 建库建表 + 灌入示例数据。**幂等且安全**：先探测表结构与数据，缺什么补什么，**不会删除已有数据** |
| `python server/app.py --force` | **清空重建**，会删掉所有表和挂号记录，慎用 |

> `--init` 与 `--force` 的区别很重要：日常只想「补建缺失的表」用 `--init`；
> 只有确定要丢弃全部数据时才用 `--force`。
>
> 在已经跑起来的正式库上执行 `--init` 是**纯读操作**：表结构完整、基础数据齐全、
> 排班已有数据，三处判断都会跳过，只额外跑一次号源一致性校验。

---

## 功能一览

### 患者端

| 模块 | 说明 |
|------|------|
| **预约挂号** | 打开首页就是 4 步向导：选科室 → 选医生 → 选日期与上下午 → 确认信息并提交（系统按单院区部署，只有一家医院，无需选医院） |
| **号源实时显示** | 就诊时间只呈现「上午 / 下午」两个半天，每段显示大致时间范围与剩余号源总数；约满自动置灰不可点。数据库里号源的最小单位就是这半天，没有更细的格子 |
| **实名校验** | 身份证号 18 位 + 校验位算法验证，手机号格式验证，姓名中文字符验证（**前端只查非空，合法性由服务端判断**） |
| **挂号凭证** | 挂号成功后就地显示凭证，含取号序号、就诊时间、费用、挂号单号 |
| **我的挂号** | **只列出「待就诊」的挂号**（2026-10-13 起去掉了状态筛选条），支持取消挂号。取消后该条即从列表消失、号源立即释放。退号只校验单号、不校验归属 —— 2026-10-14 起单号改为 `A + 毫秒时间戳`（16 位），不再是连号、猜中一个有效单号的难度明显提高，但**这仍不等于归属校验** |

### 管理端（需登录）

| 模块 | 说明 |
|------|------|
| **登录** | 用户名 + 密码登录，签发服务端会话令牌；可注销（令牌立即失效） |
| **挂号记录** | 记录表格，支持按科室 / 日期筛选 + 姓名/手机号/单号/身份证搜索，可后台退号 |
| **排班号源** | 按日期查看医生排班，按半天调整号源总量（−/＋ 或直接输入），支持停诊 / 恢复出诊 |
| **工作量报表（接口）** | `GET /api/stats/doctors` 读视图 `v_doctor_workload`，按医生 / 日期统计预约、取消、完成、爽约与收入。v2 新增，**目前只提供接口，页面没有入口**（避免又变成「没人调用的视图」） |

管理端**只剩这两个页签**。早期版本还有两个，都已下线：

- **「数据看板」** —— 有效挂号数、号源使用率、剩余号源、费用合计、科室挂号排行、医生挂号量 TOP 8；
- **「操作日志」** —— 读 `appointment_audit` 审计表，展示每次挂号状态变更的动作、旧值→新值、操作人与时间。

理由见下方《为什么管理端只剩两个页签》。

---

## 认证与鉴权

管理端不是"所有人都能进"的：

| 层次 | 措施 |
|------|------|
| **口令存储** | Node 内置 `crypto.scrypt`（N=16384/r=8/p=1）派生，每条独立随机盐，格式 `scrypt$<salt>$<hash>`；校验用 `timingSafeEqual` 定长比较，避免时序侧信道 |
| **会话** | 登录签发 256 bit 随机令牌，落库到 `user_sessions`（含过期时间）。**不用 JWT** —— 令牌落库才能真的注销、踢下线、审计登录历史 |
| **接口保护** | 写操作在每个接口开头调一次 `getLoginUser(req)`，取不到用户就直接 401 —— 没有中间件，一眼能看出哪些接口要登录 |
| **错误提示** | 登录失败统一回「用户名或密码错误」，不区分账号不存在与密码错误 |
| **越权防护** | 匿名查询挂号列表必须带 `idCard`，且返回的证件号做脱敏；写操作需要令牌。~~退号需提供身份证号确认归属~~ 已移除 |

受保护的接口（**全部只需登录，不再区分角色** —— 只有一个管理员账号）：

```
GET    /api/auth/me                        当前登录用户        需登录
POST   /api/auth/logout                    注销                需登录
PATCH  /api/schedules/:sid/quota           调整号源            需登录
POST   /api/schedules/:sid/toggle          停诊 / 恢复出诊      需登录
```

公开接口：科室 / 医生 / 排班查询、挂号、退号。
退号**不强制登录** —— 匿名也能退自己的号；带了令牌时服务端把操作人写进 `close_note`。
`GET /api/appointments` 匿名调用**必须带 `idCard`**（否则 401），带令牌时返回全部记录。

**退号留痕** —— 管理端退号时会把操作人写进 `appointments.close_note`（形如「管理端退号（admin）」），配合 `cancelled_at` 时间戳，足以回答「这条号是谁什么时候退的」。审计表与触发器已删除，当前状态以 `appointments.status` 为准。

---

## 关于「为什么不建 hospitals 表」

本系统面向**某一家医院**的挂号业务，医院是部署期常量，不存在第二家医院，因此：

- 不建 `hospitals` 表，医院名称 / 等级 / 地址放在前端常量 `js/app.js` 的 `HOSPITAL` 里，换医院只改一处
- `departments` / `schedules` / `appointments` 上都没有 `hospital_id` 外键

如果硬留这张表，`hospital_id` 三列会恒为同一个值，`UNIQUE (hospital_id, name)` 也会退化成 `UNIQUE (name)` —— 这是典型的**伪 1:N 冗余**：多了一张表、三个外键、一个索引，却没有换来任何约束能力。

---

## 关于「号源为什么不按 30 分钟拆分」

早期版本把号源拆成 S1–S12 十二个 30 分钟格子，存在 `schedule_slots` 表里。后来删掉了，理由：

- **患者挂号时选的最小单位本来就是「上午 / 下午」**，再细的格子只是系统内部的东西，患者根本没选过；
- **具体几点几分就诊，由到院签到后的现场叫号决定**，与预约时选的格子并不一一对应 —— 硬把两者绑在一起是伪精确；
- **代价却是真实的**：多一张表、多一层 JOIN、多一份要同步的状态。最典型的是有人退号，
  如果时间按格子推，后面所有人的就诊时间都得跟着往前挪。

合并之后：`schedules` 一行 = 某医生某天某个半天，号源量就是这一行的
`quota_total` / `quota_booked` 两列；挂号与退号只在这两个数字上加减。
`appointments` 也去掉了 `slot_id` / `slot_label`，只保留 `period`（上午 / 下午）这一列快照。

代价是"取号序号"的语义变了：它现在是**该半天的第几个号**（到院后按它叫号的顺序），
而不是"某个 30 分钟格子里的第几个"。退号时后续序号前移的规则保持不变。

> 迁移脚本 `server/migrations/` 目录已在 2026-10-12 的后端瘦身中整体删除 ——
> `schema.sql` 就是最终形态，不需要再跑迁移；重跑旧迁移反而会把已经删掉的列加回来。

---

## 关于「哪些字段不该进数据库」

判据只有一条：**这一列会不会出现在 `WHERE` / 约束 / 索引 / 统计里？**

不会、而且它只服务于"看起来长什么样"，那它就属于展示层。本系统按这条原则处理了四样东西：

| 内容 | 原表 / 原列 | 现在的去向 |
|------|-------------|-----------|
| 医院名称、等级、地址 | ~~`hospitals` 表~~ | `js/app.js` 的 `HOSPITAL` |
| 科室图标（emoji） | ~~`departments.icon`~~ | `js/app.js` 的 `DEPT_ICONS`（按科室编号取） |
| 医生擅长方向 | ~~`doctors.good_at`~~ | `js/app.js` 的 `DOCTOR_INTRO`（按医生编号取，页面作为简介展示） |
| 医生评分 / 接诊量 | ~~`doctors.rating` / `doctors.cases`~~ | 整列删除，界面也不再显示 |

理由分别是：

- **医院**：只服务一家医院，`hospital_id` 会恒为同一个值，`UNIQUE (hospital_id, name)` 退化成 `UNIQUE (name)` —— 典型的伪 1:N 冗余。
- **科室图标**：图标是"怎么画"。换一套图标不该需要改库、跑迁移，而它也确实不参与任何查询。
- **医生擅长方向**：本系统**没有「按擅长方向搜索 / 筛选」的功能**，这段文字永远不会出现在 `WHERE` 里，它只是一段给患者看的介绍文案。
- **医生评分 / 接诊量**：它们只被医生卡片拿来显示"⭐ 4.9 / 接诊 12800 次"。全项目搜下来，只出现在建表、种子数据、`INSERT`、mapper 和那两行卡片文字里 —— 没有一处是查询条件或排序依据。管理端的"医生排行"排的是挂号笔数（`ORDER BY COUNT(*) DESC`），医生列表排的是职称档位，两条都和它们无关。既然用户明确不要，就整列删掉，界面也一并去掉。

**对照反例**最能说明分界线在哪：`doctors.title`（职称）看起来同样只是个给人看的标签，但它**真的进了 `ORDER BY`** —— 医生列表按「主任医师 → 副主任医师 → 主治医师」排，而且它还是 `ck_doctor_title` / `ck_doctor_fee_tier` 两条约束的判定依据，所以它**必须留在库里**。

判据不是"是不是给人看的"，而是"有没有东西真的去查它"。

改前面三样东西时，只需要改 `js/app.js`，不用碰数据库、不用跑迁移。

---

## 数据库对象：为什么这一版有视图和触发器

v1 的判据是「这个对象有没有人真的调用？」—— 没人调的视图 / 函数 / 触发器一律删掉。
所以 2026-10-12 到 10-27 之间，库里确实只有「6 张表 + 约束 + 索引」，README 当时还专门写了一节论证这件事。

2026-10-28 按课程设计的清单补回了视图和触发器，但**不是把删掉的东西原样搬回来**：
每个对象都得先有调用方，才允许存在。

| 视图 | 谁在用 |
|------|--------|
| `v_available_schedules` | `GET /api/departments/<id>/doctors` 的余号统计（视图里已经过滤好「今天及以后 / 没停诊 / 还有余号」） |
| `v_appointment_detail` | `GET /api/appointments`、`GET /api/appointments/<id>`、新建挂号后的回显 |
| `v_doctor_workload` | `GET /api/stats/doctors`（管理端报表接口） |
| `v_appointment_public` | 脱敏场景备用：身份证中间 8 位、手机号中间 4 位替换成星号 |

触发器守的是另一件事：**绕过接口也写不进坏数据**。接口可以被跳过（psql、导入脚本、别的服务），触发器跳不过去。

| 触发器 | 作用 |
|--------|------|
| `trg_appt_before_insert` | `SELECT … FOR UPDATE` 锁排班行，校验停诊 / 日期已过 / 号源已满 / 重复预约，然后分配号序 |
| `trg_appt_after_insert` | 号源 +1，写一条 `appointment_log` |
| `trg_appt_before_update` | 只允许 `booked → cancelled / completed / no_show`；冻结单号 / 号序 / 排班 / 医生 / 患者 / 费用；自动写 `cancelled_at` |
| `trg_appt_after_update` | 号源 -1，写一条审计日志 |
| `trg_appt_before_delete` | 物理删除时回收号源（规范做法是软删除，但物理删除这条路也得堵住） |
| `trg_schedule_before_update` | 号源总数不得小于已约数；已有预约时不许改日期 / 时段 / 医生 |
| `trg_schedule_before_delete` | 有预约的排班不许删 |
| `trg_doctor_before_delete` | 有排班的医生不许删，提示改用 `is_active` 软删除 |
| `trg_*_touch` × 6 | 自动维护 `updated_at`（用 `clock_timestamp()`，不是事务开始时间的 `NOW()`） |

> **挂号费那道守卫仍然是外键，不是触发器**：`fk_appt_doctor_fee` 要求挂号单上的 `(doctor_id, fee)`
> 必须能在 `doctors` 表里找到同一对。价目表被 `ck_doctor_fee_tier` 锁死在三个档位上，
> 所以 `UPDATE appointments SET fee = 1` 会因「价目表里不存在 DR01 + 1 元这一档」被直接拒绝（SQLSTATE `23503`）。
> 声明式约束能做的事，就不要写 PL/pgSQL。

**v2 的完整性清单**（数字与 `python server/app.py --init` 打印的对象清单一致）：

- **8 张表**：departments / doctors / patients / schedules / appointments / users / user_sessions / appointment_log
- **40 个约束**：8 主键、8 外键、7 唯一、17 CHECK（另有 56 个 NOT NULL，PostgreSQL 18 把它们也记在 `pg_constraint` 里）
- **25 个索引**：10 个显式创建（含 1 个部分唯一索引 `uq_appt_active_slot`），其余 15 个由主键 / 唯一约束自动生成
- **4 个视图 / 9 个函数 / 14 个触发器 / 1 个序列**（`appointment_log.id` 的 identity 序列）

> 部分唯一索引 `uq_appt_active_slot` 建在 `(schedule_id, patient_id) WHERE status IN ('booked','completed')` 上：
> 同一患者不能对同一个号源留两张有效单，但**取消之后还能重挂**。
> 若做成全表唯一，一次误取消就永久封死了这个号源。

---

## 关于「为什么挂号接口只有基本功能」

判断标准只有一条：**这一步不做，挂号还能不能成？**

挂号真正核心的只有四件事：

1. 校验就诊人信息（姓名 / 身份证 / 手机号），并按身份证 upsert 一份患者档案
2. **写一条 `INSERT` 就完成挂号** —— 号源怎么扣、号序怎么排，全在触发器里（详见《并发安全》一节）
3. 挂号费由**数据库自己**确定 —— 写单的 `INSERT` 语句里 `fee` 一列填的是子查询 `(SELECT fee FROM doctors …)`，请求体传什么价格都不参与运算
4. 退号：把状态改成 `cancelled`，触发器把号源加回去

其余属于「防黄牛」加码，与挂号主流程无关，v1 曾按「暂时不搞防黄牛机制」的要求**全部移除**；
v2 按课程设计清单恢复了其中与数据完整性直接相关的两条（见下表）。

| 项目 | 原来做什么 | 现在 |
|--------|-----------|------|
| 挂号接口限流 `bookLimiter` | 同一「IP + 身份证前6位」每分钟 ≤ 8 次 | 仍然没有（属于运维层，不属于数据库设计） |
| 同日囤号上限 `DAILY_APPT_CAP` | 同一人当天最多 2 个号 | 仍然没有 |
| 同人同日同科室查重 | 防一人占满一个科室 | **v2 已恢复**：`trg_appt_before_insert` 里一条 `EXISTS` 判断 |
| 同人同日同医生查重 | 防同一医生被重复占号 | **v2 已恢复**：部分唯一索引 `uq_appt_active_slot` + 触发器双保险 |
| 退号归属校验 | 退号须提供挂号人身份证号 | 仍然没有 —— 只凭单号就能退 |
| `friendlyPgError` | 把 PG 错误码翻译成中文 | `server/db.py` 的 `db_error()` 统一处理；v2 起 `P0001` 直接把触发器里的中文提示透传出去 |

**没动的**：`ck_schedule_booked_range`（防超卖）、以及「挂号费不由请求方决定」这条规则本身
（SQL 子查询 + `fk_appt_doctor_fee` 外键双重承担）。

> ⚠️ **一个已知副作用**：**只凭单号就能退任意号** —— 单号是 `A + 毫秒时间戳`（16 位），
> 猜中一个有效单号比序列时代难得多，但退号接口**仍然没有归属校验**，拿到单号就能退。

---

## 关于「为什么管理端只剩两个页签」

2026-10-12 又做了一轮收口，判据是：**这个功能不做，我还能不能挂上号？**

只保留「登录 + 挂号记录 + 退号 + 调号源」，其余全部删除：

| 删除项 | 原来做什么 | 处置 |
|--------|-----------|------|
| **数据看板** | 号源使用率进度条、科室挂号排行、医生挂号量 TOP 8 | 前端渲染函数与 `.stat-grid` 等样式一并删除 |
| `GET /api/stats` | 经营统计（收入、两个排行） | 删 |
| `GET /api/stats/overview` | 公开概览（聚合计数） | 删 |
| `GET /api/stats/daily` | 科室日报表 | 删 |
| `GET /api/stats/doctor-workload` | 医生工作量 | 删 |
| `POST /api/admin/reset` | 重置示例数据 | 删（管理端「重置示例数据」按钮一并去掉） |
| `POST /api/admin/regenerate` | 补齐排班 | 删 |
| `GET /api/admin/consistency` | 号源一致性自检 | 删 |
| `users.role` 列 + `staff` 账号 + `requireRole` | 管理员 / 门诊值班员两级权限 | 删 —— 只留一个管理员账号，角色永远只有一个取值，这一列不做查询条件也不参与统计 |
| `POST /api/auth/password` | 登录后自助改密 | 删（改密码直接改 `server/seed_data.py` 里的 `USERS` 常量再 `--force`） |
| 登录失败锁定 | 同一 IP + 用户名 5 次失败锁 5 分钟 | 删 |
| 顶部实时时钟 | 每秒刷新的时间显示 | 删（连带 `setInterval` 定时器） |
| `GET /api/doctors/:id` | 单个医生详情 | 删 —— 全项目零调用方，前端只用列表接口 |
| `GET /api/doctors/:id/schedules/:date` | 单个日期的排班 | 删 —— 零调用方，前端只用「未来 N 天」那个接口 |

**没动的**：登录鉴权、带条件的 `UPDATE`、`ck_schedule_not_oversold` 约束、「挂号费不由请求方决定」（现由 SQL 子查询 + 外键承担）、退号回滚号源与序号前移。
这些不是「功能」，是挂号**正确性**本身。

### 顺带简化的示例数据生成

原来用 FNV-1a 伪随机造「哪些医生周末值班 / 哪天更忙」，还要**合成一大批历史挂号记录**（再反算 `quota_booked`），一个 230 行的生成器。

现在是一段直白的三层循环 —— 每位医生 × 未来 14 天 × 上午/下午，全部出诊，号源量按职称取 `QUOTA_BY_TITLE`：

```js
function buildSchedules(days = 14, from = null) {
  const out = [];
  buildDateRange(days, from).forEach((d) => {
    DOCTORS.forEach((doc) => {
      PERIODS.forEach((p) => {
        out.push({ /* 一条半天排班 */ quotaTotal: QUOTA_BY_TITLE[doc.title] });
      });
    });
  });
  return out;
}
```

**代价（已知取舍）**：不再合成历史挂号记录，所以 `quota_booked` 从 `0` 开始，挂号记录页一开始是空的。
库里的旧数据已随 `python server/app.py --force` 清空 —— 重置前的完整快照在
`backups/hospital_registration_pre_simplify_20261012.sql`。

**当前库规模**：6 张表 / 0 视图 / 0 函数 / 0 存储过程 / 0 触发器 / 19 个索引（无部分索引）。
10 位医生 × 14 天 × 上午下午 = **280 条排班**。

---

## 关于「为什么前端只有一个文件」

`js/` 现在只有 `app.js` 一个文件。判断标准和后端那条一样：
**这个文件有没有独立存在的必要。**

2026-10-13 把原来**五个文件合并成了一个 `js/app.js`**：

| 原来的文件 | 内容去哪了 | 为什么合并 |
|---|---|---|
| `utils.js`（176 行） | 并入第一 ~ 四节 | 常量、日期工具、本地存储。本来就只有页面逻辑在用，单独放着反而要来回跳 |
| `api.js`（116 行） | 并入第五节 | 13 个请求函数，读第六节以后的代码时天天要用 |
| `patient.js`（350 行） | 并入第八、九节 | 患者端逻辑 |
| `admin.js`（225 行） | 并入第十、十一节 | 管理端逻辑 |
| `app.js`（121 行） | 并入第六、七、十二节 | 页面切换、登录、启动 |

合并后的 `js/app.js` 按 **十二节** 排布，从上往下就是一条直线：

```
一、写死的常量      二、全局变量        三、小工具（日期/金额/转义）
四、本地存储        五、跟后端打交道     六、页面切换
七、登录 / 注销      八、患者端：挂号 4 步  九、患者端：我的挂号
十、管理端：挂号记录  十一、管理端：排班号源  十二、启动
```

`index.html` 里原来有 5 个 `<script>` 标签，现在只剩 1 个：

```html
<script src="js/app.js"></script>
```

### 这次还额外做了两件事

**1. 把所有 `.map` / `.filter` / `.find` / `.reduce` 换成了 `for` 循环。**
例如「某个科室下面有哪些医生」，原来是一行：

```js
return doctors.filter((d) => d.deptId === deptId);
```

现在是这样，多几行但一眼能看懂：

```js
function doctorsOf(deptId) {
  const list = [];
  for (let i = 0; i < doctors.length; i++) {
    if (doctors[i].deptId === deptId) list.push(doctors[i]);
  }
  return list;
}
```

**2. 把拼 HTML 时嵌在模板字符串里的三元表达式拆成了 `if / else`。**
原来医生卡片那一段长这样 —— 一个 `${}` 里套三元、三元里再套一个模板字符串：

```js
`<div class="card${soldOut ? ' disabled' : ''}"
      ${soldOut ? '' : `onclick="pickDoctor('${d.id}')"`}>`
```

现在先把要变的三个值算出来，再拼：

```js
let cls = 'card';
let click = `onclick="pickDoctor('${d.id}')"`;
let feeLine = '挂号费 ' + money(d.fee) + ' · 剩 ' + d.remain + ' 号';

if (soldOut) {
  cls = 'card disabled';
  click = '';
  feeLine = '挂号费 ' + money(d.fee) + ' · 已约满';
}
```

**没动的东西**：函数名一个没改。`index.html` 里 `onclick="goHome()"` 这类写法依赖全局函数名，
所以 `pickDept` / `pickDoctor` / `pickDate` / `pickPeriod` / `cancelMine` / `adminCancel` /
`doSearch` / `clearFilters` / `changeQuota` / `toggleSchedule` 全部保持原名。

---

## 关于「后端为什么拆成 5 个文件」

`server/` 现在是 5 个 Python 文件 + 1 个 SQL。判断标准只有一条：
**这个文件有没有独立存在的必要 —— 它是不是「一件事」。**

| 文件 | 管什么 | 为什么单独存在 |
|---|---|---|
| `app.py` | Flask 应用 + 15 个接口 + 启动入口 | 接口本来就该待在同一处，从上往下读完就是全部对外行为 |
| `db.py` | 连接池、`query()`、错误翻译、行 → JSON | 被所有接口共用；单独放才能一眼看清「数据库怎么连、出错怎么翻」 |
| `init_db.py` | 建库、建表、灌数据、一致性自检 | 只在 `--init` / `--force` 时用，正常启动根本不会导入它 |
| `seed_data.py` | 科室 / 医生 / 账号常量 + 排班生成规则 | 是「数据」不是「逻辑」，改内容不用碰代码 |
| `validators.py` | 口令散列、身份证 / 手机号 / 姓名校验 | 纯函数，没有任何 I/O，最容易单独验证 |

`app.py` 内部按 **九节** 排布，从上往下就是一条直线：

```
一、应用与静态文件        二、判断「这次请求是谁在操作」
三、登录 / 注销 / 当前用户  四、科室 / 医生 / 排班（只读）
五、挂号 / 退号 / 挂号记录  六、管理端调号源 / 停诊
七、健康检查              八、404 与兜底错误处理        九、启动
```

**为什么不干脆学旧版塞进一个 `app.py`？** 因为 Python 和 JS 的模块机制不一样：
Node 里 `require` 是运行时按需解析，一个 1150 行的文件也能凑合；
Python 的 `import` 在文件顶部、循环导入会直接报错，而且 `init_db` 依赖 `validators`
（要 `hash_password` 建初始账号）、`app` 又依赖 `db` —— 硬塞进一个文件反而要
在函数内部做局部导入，比拆开更绕。

拆开之后还多了一个好处：`init_db.py` 里的 `SCHEMA_FILE`、`seed_data.py` 里的
`DEPARTMENTS`，改的时候**不用在 1000 行里找**。

### 没有 `route()` 包装函数，也没有 `requireAuth` 中间件

这两样东西不是简化，而是**给初学者添乱** —— 它们把「谁需要登录」「出错怎么办」藏到了别处。

**1. 每个接口自己写 `try / except`。** 错误怎么翻译、回什么状态码，就在这个接口里：

```python
@app.post("/api/auth/login")
def auth_login():
    try:
        # ...接口正文...
    except Exception as err:
        app.logger.error("[登录] %s", err)
        status, msg = db_error(err)          # 23514/23505/23503 → 中文提示
        return jsonify(error=msg), status
```

多写 4 行，换来的是「这个接口出错会怎么回」就在这个接口里，不用去翻别处。
（Flask 本身会捕获异常，`@app.errorhandler(Exception)` 是最后一道兜底，
但每个接口仍然自己兜住 —— 否则日志里看不出是哪个接口挂的。）

**2. 没有 `@login_required` 装饰器。** 需要登录的接口，开头就两行：

```python
user = get_login_user()
if not user:
    return jsonify(error="未登录或登录已过期，请重新登录"), 401
```

哪个接口要登录，看接口本身就知道，不用回头数装饰器。
**退号**和**挂号列表**这两个接口故意不这么写 —— 它们匿名也能用
（`get_login_user()` 取不到用户就返回 `None`，当作患者本人在操作）。

### 口令散列与「和旧版兼容」

`hash_password` / `verify_password` 在 `validators.py` 里，格式是 `scrypt$<盐>$<散列>`。

> **改写时踩到的一个真问题**：库里已有的账号是 Node 用
> `crypto.scryptSync(password, salt, 64)` 算出来的，参数是 `N=16384, r=8, p=1`，
> 而且它把**盐的十六进制字符串本身**当字节用（不是把它解码成 16 字节）。
> Python 的 `hashlib.scrypt` 默认参数虽然相同，但盐要显式 `.encode("ascii")` 才能对上。
> 改完第一件事就是拿库里真实的那条散列验证 —— `admin123` 能过、`admin124` 不过，
> 才算真的兼容，**不用重置密码、不用迁移数据**。

---

## 关于「初学风化」这次重写

2026-10-13，把**前后端全部代码**按「初学者写法」重写了一遍。所谓初学者写法，指的是：

| 方面 | 现在的做法 | 重写前的做法（进阶版） |
|------|-----------|----------------------|
| 页面骨架 | 4 个步骤 + 登录页 + 管理页**全部是 `index.html` 里的静态 HTML**（`#step1` ~ `#step4`、`#page-*`） | JS 拼字符串 `innerHTML` 重画整个视图 |
| 步骤切换 | `style.display = '' / 'none'` | 每次重绘 + 重新绑定事件 |
| 状态 | 十几个平铺的全局变量（`step` / `deptId` / `doctorId` / `date` / `period` / `scheduleId` …） | 一个 `state` 对象 + `resetBooking()` |
| 事件绑定 | 直接写在标签上：`onclick="pickDept('D01')"` | `querySelectorAll('[data-dept]').forEach(n => n.onclick = …)` 事件委托 |
| 提示 | 原生 `alert()` / `confirm()` | 自制 Toast 组件 + 自制 Modal 组件 |
| 前端取数 | `js/app.js` 第五节：一个接口一个函数，页面直接调用 | `js/store.js` 再包一层缓存层 |
| 后端结构 | **后端按职责拆成 5 个 Python 文件**（`app.py` / `db.py` / `init_db.py` / `seed_data.py` / `validators.py`），15 个接口与全部 SQL 都在 `app.py` 里 | 拆成 `routes/schedules.js` + `routes/appointments.js`，用工厂函数注入中间件 |
| 数据库连接 | 直接写在 `server/db.py` 的 `DB_CONFIG` 里 | `.env` + `dotenv` |
| 事务 | **不用事务**，靠一条自带条件的 `UPDATE` 防超卖 | `withTransaction` + `SELECT … FOR UPDATE` |
| 样式 | 朴素：无渐变、无阴影、无动画，`border-radius: 4px` | 卡片化 + 轻阴影 + 渐变主色 |

> **前端结构后来又收了一次口**（2026-10-13 第十七轮）：上面这张表里的前端部分，
> 当时还是分散在 `utils.js` / `api.js` / `patient.js` / `admin.js` / `app.js` **五个文件**里；
> 现在已合并成 **`js/app.js` 一个文件**，并且把 `.map` / `.filter` / `.find` / `.reduce`
> 全部换成了 `for` 循环、把嵌套三元拆成了 `if / else` —— 详见《关于「为什么前端只有一个文件」》。

**被拒绝的三条「初学者写法」**（这三条不是简化，是错误）：

1. **SQL 用字符串拼接代替 `%s` 占位符** —— 这是 SQL 注入。用户把身份证号填成 `' OR '1'='1` 就能把整张表读走。`server/db.py` 的 `query()` 上方专门写了注释说明为什么必须用占位符。
2. **删掉数据库约束** —— 那 15 条 `CHECK` + 3 条 `UNIQUE` 是数据正确性的最后一道防线，删了就是让错数据能写进去。
3. ~~删掉事务~~ —— 这一条用户**确认要删**，所以额外做了补偿（见下一节）。

### 事务删了，怎么保证不超卖？

老写法是「开事务 → `SELECT … FOR UPDATE` 锁住排班行 → 判断 → 扣 1 → 写单」。
新写法只有一条 SQL：

```sql
UPDATE schedules SET quota_booked = quota_booked + 1
 WHERE id = $1 AND quota_booked < quota_total
RETURNING quota_booked
```

`WHERE` 里的条件和 `SET` 里的加一**是同一条语句的一部分**，PostgreSQL 执行时会给那一行加锁，
所以「判断」和「扣减」之间不存在任何空隙 —— 20 个人同时抢最后 1 个号，只有 1 个人能更新成功。

- `rowCount = 1` → 抢到了，`RETURNING` 回来的 `quota_booked` 正好当**取号序号**用
- `rowCount = 0` → 号满了，直接回 409「该时段号源已挂完」

**没有事务就必须自己补偿**，所以另外补了两处：

- 号扣成功了、但紧接着写 `appointments` 失败 → `UPDATE schedules SET quota_booked = quota_booked - 1`，把号还回去；
- 退号路由的 `UPDATE … WHERE` 里重复写上 `AND status = 'active'` —— 重复退号时第二次会命中 0 行，直接回 409，**不会把号源退两次**。

代价是 `ck_schedule_not_oversold` 从「最后一道保险」变成了**数据库层唯一的兜底**。

---

## 核心业务规则

系统不是"能点就行"的空壳，以下规则均已在数据库与代码层实现（★ = v2 起由数据库触发器承担）：

- ★ **号源自动增减** —— 挂号成功 +1，退号 / 完成 / 爽约 / 物理删除 -1；应用层不再手写 `UPDATE schedules`
- ★ **号序自动分配** —— 触发器取 `MAX(seq_no) + 1`，应用层传什么都无效
- **号源超卖保护** —— 行锁 + `ck_schedule_booked_range`；管理端调整号源总数不得小于已约数（接口与触发器双层拦截）
- **挂号费由数据库定价** —— 写单的 `INSERT` 里 `fee` 一列填的是子查询，请求体传值不参与运算；外键 `fk_appt_doctor_fee` 再兜一道底
- **不重排序号** —— 退号后后续患者的序号**不前移**。v1 会前移，v2 加了 `uq_appt_schedule_seq`（同排班号序唯一）之后前移必然撞号；真实医院本来也留空号
- **停诊联动退号** —— 医生停诊时，该排班下所有「待就诊」自动转 `cancelled` + `cancel_reason = 'closure'`，接口再把它还原成前端的「已停诊」
- **日期边界** —— 不可预约已过去的日期；就诊当日之后不可取消
- **退号** —— 只改状态；`cancelled_at` 与号源由触发器维护；管理端退号需登录，操作人写进 `close_note` 与审计日志
- ★ **审计留痕** —— 创建 / 取消 / 完成 / 爽约各写一条 `appointment_log`（谁、何时、旧状态、新状态），任何写入路径都绕不过
- ★ **状态流转受限** —— 只有 `booked` 能变；`cancelled` 不能复活、`completed` 不能反悔成爽约

> ⚠️ **「只凭单号就能退任意号」仍然存在** —— 退号接口没有归属校验。
> 属于权限设计问题，不在本次数据库改造范围内。

---

## 并发安全

挂号是典型的「读-判断-写」：若不加锁，两个请求可能同时读到「还剩 1 个号」，然后都写入，造成**超卖**。

v2 的做法：**把判断和占用放进同一个事务，用排班行锁把它们串起来。**

1. **`SELECT … FOR UPDATE` 锁住排班行** —— `fn_appt_before_insert` 一进来就锁这一行。
   第二个并发请求会卡在这里等第一个提交；等它拿到锁，读到的 `booked_count` 已经是加过 1 的值，
   所以「还有没有号」的判断永远基于最新数据。
2. **只锁一行** —— 号源就挂在排班行上，全程一把锁，没有加锁顺序问题，死锁面为零。
3. **CHECK 兜底** —— `ck_schedule_booked_range` 保证 `booked_count` 不可能大于 `max_quota`，
   即使有人禁用触发器手工改库也写不进去。
4. **唯一索引兜底** —— `uq_appt_active_slot` 保证同一个人不可能对同一个号源留下两张有效单。

并发实测（临时库，脚本 `.tmp/test_triggers_v2.py`，20 个线程同时抢最后 1 个号）：

```
20 并发只有 1 个成功  → 成功 1，失败 19
号源没有超卖          → booked_count = 1，实际单数 = 1
失败原因一致          → 「该时段号源已挂完，请选择其他时段」
```

> 复现方式：`PGDATABASE=临时库 python .tmp/test_triggers_v2.py`。**务必用临时库** —— 这个测试会改号源总数。

---

## 项目结构

```
hospital-registration/
├── index.html              全部页面骨架：顶栏 + 挂号向导 4 步 + 我的挂号 + 登录 + 管理后台
├── css/style.css           全部样式（朴素风，约 230 行）
├── js/app.js               ★ **前端全部代码**（分十二节：常量 / 全局变量 / 小工具 / 本地存储 / 请求 / 页面切换 / 登录 / 患者端挂号 4 步 / 我的挂号 / 管理端挂号记录 / 管理端排班号源 / 启动）
├── server/                 ★ 后端：6 个 Python 文件 + 1 个 SQL
│   ├── app.py              Flask 应用 + 16 个接口 + 启动入口（内部分九节）
│   ├── db.py               连接池、query()、约束错误 → 中文提示、数据库行 → 前端对象
│   ├── init_db.py          建库 / 建表 / 灌基础数据 / 铺排班 / 号源一致性自检 / 对象清单
│   ├── seed_data.py        科室、医生、账号等常量 + 排班生成规则
│   ├── validators.py       口令散列（scrypt）+ 身份证 / 手机号 / 姓名校验
│   ├── migrate_v2.py       v1 → v2 一次性迁移（单事务，保留全部既有数据）
│   └── schema.sql          8 张表 + 约束 + 索引 + 4 视图 + 9 函数 + 14 触发器
├── requirements.txt        两个直接依赖：Flask、psycopg[binary]
├── 启动.bat                Windows 一键启动（自动建 venv、装依赖、初始化）
├── .venv/                  虚拟环境（首次运行自动创建，已被 .gitignore 忽略）
└── legacy-node/            旧版 Node + Express 源码，仅留档（见该目录 README）
```

工作区里还有两个不属于项目本体的归档目录：

```
legacy/2026-10-13-初学风化前/      重写前的「进阶版」全部源码（前端 + 后端 + .env + 测试脚本）
legacy/2026-10-13-测试工具删除前/   删掉的 e2e 脚本、check.js，以及它们跑出来的日志
```

---

## 架构说明

### 分层

```
浏览器
  └─ js/app.js 的第五节「跟后端打交道」   唯一的 fetch 出口：注入 Authorization 令牌，
                                          非 2xx 统一转成带中文提示的 Error
       └─ js/app.js 其余各节              页面逻辑：调用第五节的函数拿数据，往固定的 DOM 容器里填
            └─ Flask 路由（server/app.py，需要登录的接口自己校验令牌）
                 └─ db.query()（server/db.py：从连接池取连接、执行、归还）→ PostgreSQL
```

### 数据缓存策略

- **科室 / 医生**（5 + 10 条，几乎不变）在页面打开时一次性拉回来，存进 `js/app.js` 里的两个全局数组
  `departments` / `doctors`，并提供同步 getter：`deptName(id)` / `doctorName(id)` / `doctorTitle(id)` /
  `doctorFee(id)` / `doctorsOf(deptId)`。
  这样绝大多数渲染函数不必写成 `async`。
- **排班 / 挂号**（会变）按需异步拉取，每次都打接口。
- 字段名在 `server/db.py` 的映射函数里统一转成 camelCase，前端引用无需改写。
- **医院信息**不进缓存也不进数据库 —— 它是前端常量 `HOSPITAL`。

### 前端渲染模式

**页面骨架在 HTML 里，JS 只负责填内容。**

- 四个页面（`#page-home` / `#page-mine` / `#page-login` / `#page-admin`）和挂号向导的四个步骤
  （`#step1` ~ `#step4`）都是 `index.html` 里的静态标签，切换靠 `style.display`。
- JS 只在列表容器（`#deptList` / `#doctorList` / `#dateList` / `#periodList` / `#mineList` / `#adminBody`）
  里写 `innerHTML`。
- 事件不靠委托，而是直接写在标签上：`onclick="pickDept('D01')"`。所有函数都在全局作用域，所以标签里能直接调。

### 启动流程

`window.onload` 里三步：

1. 拉科室和医生（失败就 `alert` 提示「请确认后端已启动」，然后 return）；
2. 本地 `localStorage` 里如果存着令牌，问一次 `GET /api/auth/me` 确认还有效，无效就静默清掉；
3. `goHome()` 进首页，显示挂号向导第一步。

---

## 手工冒烟

项目里**没有测试脚本**。起服务后直接打接口看返回即可：

```bash
curl http://127.0.0.1:3000/api/health
curl http://127.0.0.1:3000/api/departments
curl -X POST http://127.0.0.1:3000/api/auth/login \
     -H "Content-Type: application/json" \
     -d '{"username":"admin","password":"admin123"}'
```

想确认「已下线的接口真的都 404」，随手挑几个即可：
`/api/stats`、`/api/stats/overview`、`/api/admin/reset`、`/api/doctors/DR01`
—— 它们都应返回 404。

> 项目里原本还有一套 `check.js`（前端静态检查）和 `e2e/`（真实浏览器端到端），
> 因为不属于课程设计要交的范围，已经归档到 `legacy/2026-10-13-测试工具删除前/`。
> 现在这个项目的验证方式就是：**起服务，用浏览器点一遍**。
>
> 改写成 Python 时另外做过两轮更严格的验证（脚本在工作区 `.tmp/` 下，不随项目提交）：
> **`test_py_api.py`** —— 90 项断言覆盖全部 15 个接口的正常与异常分支，
> 含 20 个请求并发抢 5 个号的防超卖测试（结果恰好 5 成功 15 失败、序号 1~5 不重复）；
> **`test_parity.py`** —— 把 Node 旧版和 Python 新版同时跑在两个从零建的空库上，
> 同一串请求打过去比对响应，**54 项全部一致**（连 JSON 字段顺序都一样）。

---

## 设计说明

**视觉风格** —— 朴素为主：白色卡片 + 浅灰背景（`#f5f6f8`），1px 边框，`border-radius: 4px`，
**没有渐变、没有阴影、没有动画**。主色是蓝色 `#2563eb`，只用在「确认挂号」这类主动作按钮上。
管理端表格用绿底标签标「待就诊」、灰底标「已取消 / 已停诊」。

**交互细节** —— 挂号流程靠标题文字（「选择就诊科室」→「选择接诊医生」→「选择就诊时间」）
加每步底部的「← 返回上一步」按钮定位当前位置；不可选项置灰并写明原因（「已约满」「无号」）；
破坏性操作（退号、停诊）走原生 `confirm()` 二次确认；结果用原生 `alert()` 反馈。

**响应式** —— 确认页的两栏布局在 700px 以下自动改成一栏；卡片网格用 `flex-wrap` 自动换行。

---

## 说明

- **挂号记录接口默认最多返回 500 条**（上限 2000）。建议用科室 / 日期筛选或搜索缩小范围，避免一次渲染过多 DOM。
- 科室、医生与患者数据均为**虚构示例**，不指向任何真实医疗机构。
- 后台账号密码为演示用默认值，**正式部署请立即修改**。
- 数据库密码写在 `server/db.py` 里（这是课程设计项目，本机演示用）。
  **真要放到公开仓库前，记得先把 `password` 换成环境变量或配置文件的读法。**
- `python server/app.py --force` 会清空所有业务数据（含后台账号，会重新灌入默认账号），仅用于演示环境。
- 依赖只有 2 个：`Flask`、`psycopg[binary]`（见 `requirements.txt`）。
  没有装 `cors` 之类的跨域中间件 —— 前后端同源，页面由 Flask 一起发出去，不需要跨域头。
- 没有用 ORM。SQL 全部手写，因为要演示的正是约束、外键、原子 `UPDATE` 这些数据库本身的行为；
  用 ORM 会把 SQL 藏起来，答辩时反而说不清数据库到底做了什么。
