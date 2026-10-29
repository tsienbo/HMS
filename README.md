# 智慧医院预约挂号系统

单院区门诊的在线预约挂号系统：患者在网页上完成「选科室 → 选医生 → 选时段 → 实名确认」全流程，
工作人员在后台管理号源、处理挂号与候补、审计隐私访问。

**设计重心在数据库**：号源增减、号序分配、状态流转、防超卖、限挂规则、候补补位、实名校验都由
PostgreSQL 的约束、触发器和存储函数实现。应用层只负责参数校验和转发 —— 即使绕过接口直接写库，
也写不进不合规的数据。

| 层 | 技术 |
|---|---|
| 前端 | 原生 HTML / CSS / JavaScript 单页应用，无构建步骤；移动端优先的响应式布局 |
| 后端 | Python 3.13 + Flask 3.1 |
| 数据库 | PostgreSQL 18（psycopg 3 驱动，自带连接池） |

---

## 快速开始

### 前置条件

- Python ≥ 3.9
- PostgreSQL 已安装并启动，`postgres` 账号可登录

### 一键启动（Windows）

```bash
python start.py
```

首次运行会自动创建虚拟环境、安装依赖、初始化数据库，然后启动服务并打开浏览器
（`http://127.0.0.1:3000/`）。首次需要联网安装依赖，之后可离线运行。

### 手动启动

```bash
python -m venv .venv
.venv\Scripts\activate              # macOS / Linux: source .venv/bin/activate
pip install -r requirements.txt
python server/app.py --init         # 建库、建表、灌入示例数据（幂等）
python server/app.py                # 启动服务
```

### 数据库连接

连接参数在 `server/db.py` 的 `DB_CONFIG`（默认 `127.0.0.1:5432`，用户 `postgres`，密码 `123456`），
库名默认 `hospital_registration`，不存在时自动创建。本机密码不同时改这一处即可。

可选环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `PGDATABASE` | `hospital_registration` | 连接其他库（如测试库） |
| `PORT` | `3000` | 服务端口 |
| `HOST` | `127.0.0.1` | 监听地址；设为 `0.0.0.0` 可让局域网内手机访问 |
| `CAPTCHA_REMAIN_THRESHOLD` | `3` | 余号 ≤ 该值时挂号需完成验证码 |
| `DEMO_CODE` | `1` | 短信验证码演示模式；设为 `0` 关闭（见「安全与隐私」） |

### 后台账号

| 用户名 | 密码 | 角色 |
|---|---|---|
| `admin` | `admin123` | 管理员 |

账号定义在 `server/seed_data.py` 的 `USERS`。正式使用前请修改默认密码。
患者端无需注册登录。

---

## 命令行

后端只有一个入口 `server/app.py`，参数决定行为：

| 命令 | 作用 |
|---|---|
| `python server/app.py` | 启动 Web 服务 |
| `python server/app.py --init` | 建库建表、补齐缺失对象和基础数据。**幂等，不删除已有数据** |
| `python server/app.py --force` | **清空重建**全部表和数据，慎用 |
| `python server/app.py --migrate` | 只执行 v3 增量升级（`schema_v3.sql`），不动已有数据 |
| `python server/app.py --worker [--interval 60]` | 常驻后台任务：就诊提醒、候补过期顺延、发信 |
| `python server/app.py --remind [--force]` | 手动跑一轮上述任务（`--force` 忽略发送时间窗） |
| `python server/app.py --flush-mail [--limit 50]` | 发送发件箱中待发邮件 |
| `python server/app.py --test-mail [地址]` | 发一封测试邮件，检查 SMTP 配置 |

> 提醒与候补顺延由 `--worker` 驱动，Web 服务本身不启动后台线程。
> 不运行 worker 时，管理端「通知发件箱」页签的「立即扫描一轮」按钮可手动触发。

---

## 目录结构

```
hospital-registration/
├── web/                    前端（服务端只公开这一个目录）
│   ├── index.html          页面骨架与弹窗
│   ├── css/style.css       样式（含移动端适配）
│   └── js/app.js           前端逻辑
├── server/                 后端
│   ├── app.py              Flask 应用、全部接口、命令行入口
│   ├── db.py               连接池、query()、数据库错误 → 中文提示、行 → JSON 映射
│   ├── guard.py            限流（滑动窗口）与放号验证码
│   ├── validators.py       口令散列（scrypt）与身份证 / 手机号 / 姓名 / 邮箱校验
│   ├── mailer.py           发信（SMTP；未配置时 dry-run 写 .mail-outbox.log）
│   ├── reminder.py         就诊提醒扫描、候补过期顺延
│   ├── init_db.py          建库、建表、灌数据、对象清单与一致性自检
│   ├── seed_data.py        科室、医生、账号等基础数据与排班生成规则
│   ├── schema.sql          v2 全量建库脚本（含 DROP，仅用于全新安装）
│   ├── schema_v3.sql       v3 增量对象（全部 IF NOT EXISTS / OR REPLACE，可重复执行）
│   ├── migrate_v2.py       v1 → v2 一次性迁移
│   ├── migrate_v3.py       v2 → v3 增量迁移与自检
│   └── mail.env            SMTP 配置（含授权码，已加入 .gitignore）
├── start.py                一键启动脚本
└── requirements.txt        Flask、psycopg[binary]
```

---

## 功能

### 患者端

| 功能 | 说明 |
|---|---|
| 预约挂号 | 四步向导：选科室（支持拼音首字母搜索）→ 选医生与日期 → 确认信息 → 预约成功；已完成的步骤可点回修改 |
| 号源展示 | 按「上午 / 下午」半天展示余号，按余量显示「有号 / 紧张 / 已满」 |
| 实名校验 | 挂号时校验姓名与身份证号是否一致（模拟公安二要素，见下文） |
| 放号验证码 | 余号 ≤ 3 时需完成算术验证码，防脚本抢号 |
| 候补 | 号源已满时可排候补；有人退号自动按顺序补位，保留 2 小时，超时顺延 |
| 我的预约 | 按待就诊 / 已完成 / 已取消分组，可取消、改约 |
| 就诊提醒 | 就诊前一天 18 点、当天 7 点生成提醒（站内信 + 邮件） |
| 我的资料 | 修改姓名、手机号、邮箱 |
| 大字版 | 一键放大全站字号，方便老年患者 |

### 管理端（需登录，按角色授权）

| 页签 | 说明 | 角色 |
|---|---|---|
| 挂号记录 | 按科室 / 日期筛选、关键字搜索；退号；查看挂号时间线；查看完整证件号需填写理由并留痕 | 全部（明文仅管理员 / 审计员） |
| 排班号源 | 调整每个半天的号源总量；停诊 / 恢复出诊（停诊自动退掉该时段全部待就诊号） | 查看：全部；修改：管理员、窗口 |
| 候补队列 | 全院当前排队情况 | 全部 |
| 窗口代约 | 工作人员替电话 / 到院患者挂号 | 管理员、窗口 |
| 访问日志 | 谁、何时、因何查看了哪位患者的隐私信息 | 管理员、审计员 |
| 通知发件箱 | 提醒与候补通知的投递状态；手动触发一轮扫描 | 管理员、审计员 |
| 黑名单 | 限制特定就诊人线上挂号 | 管理员（审计员只读） |

角色：`admin` 管理员（全部）、`auditor` 审计员（只读报表与审计）、`desk` 窗口人员（代约、查看脱敏记录）。

---

## 数据库设计

### 对象总览

| 类别 | 数量 |
|---|---|
| 表 | 16 |
| 视图 | 5 |
| 函数 | 16（触发器函数 14 + 普通函数 2：候补补位 `fn_offer_next_waitlist`、实名校验 `fn_verify_identity`） |
| 触发器 | 20 |
| 约束 | 主键 16、外键 17、唯一 11、CHECK 33 |
| 索引 | 48（含部分唯一索引、表达式唯一索引） |

### 表

| 分组 | 表 | 说明 |
|---|---|---|
| 基础数据 | `departments` | 科室 |
| | `doctors` | 医生；职称与挂号费档位由 CHECK 绑定 |
| | `schedules` | 排班：一行 = 某医生某天某半天，号源总量 / 已约数就在这一行上 |
| 业务 | `patients` | 就诊人档案，身份证号唯一（大小写不敏感） |
| | `appointments` | 挂号单 |
| | `waitlist` | 候补队列 |
| 审计 | `appointment_log` | 挂号状态变更日志，由触发器写入 |
| | `access_log` | 后台查看患者隐私的访问记录 |
| 身份与安全 | `users` / `user_sessions` | 后台账号与会话令牌 |
| | `patient_sessions` | 患者凭证（只存 SHA-256） |
| | `citizen_registry` | 模拟公安人口库（身份证号 → 姓名） |
| | `identity_verify_log` | 实名校验日志 |
| | `verification_codes` | 短信 / 邮件验证码（只存哈希） |
| | `blacklist` | 挂号黑名单 |
| 通知 | `notification_outbox` | 发件箱：提醒、候补通知，带去重键与重试计数 |

### 视图

| 视图 | 用途 |
|---|---|
| `v_appointment_detail` | 挂号单 + 患者 + 医生 + 科室 + 排班的完整一行；挂号列表、详情、回显都查它 |
| `v_appointment_public` | 脱敏版：身份证、手机号中间位替换为星号 |
| `v_available_schedules` | 今天及以后、未停诊、仍有余号的排班 |
| `v_doctor_workload` | 按医生 / 日期统计预约、取消、完成、爽约与收入 |
| `v_waitlist_detail` | 候补 + 患者 + 排班明细 |

### 触发器

| 表 | 触发器 | 作用 |
|---|---|---|
| `appointments` | `trg_appt_guard` | 限挂规则：黑名单、30 天取消 ≥ 5 次、180 天爽约 ≥ 3 次、同日最多 2 个号 |
| | `trg_appt_before_insert` | `SELECT … FOR UPDATE` 锁排班行；校验停诊 / 过期 / 满号 / 重复预约；分配号序 |
| | `trg_appt_after_insert` | 已约数 +1，写审计日志 |
| | `trg_appt_before_update` | 状态机：只有 `booked` 可变更；冻结单号、号序、排班、医生、患者、费用 |
| | `trg_appt_after_update` | 离开 `booked` 时已约数 −1，写审计日志 |
| | `trg_appt_promote_waitlist` | 有号释放时通知候补队首 |
| | `trg_appt_close_waitlist` | 候补转正后把候补标记为已转正 |
| | `trg_appt_before_delete` | 物理删除有效单时回收号源 |
| `waitlist` | `trg_waitlist_before_insert` / `before_update` | 只允许满号时候补；候补状态机；冻结排队号 |
| `schedules` | `trg_schedule_before_update` | 号源总量不得小于已约数；有预约后不得改日期 / 时段 / 医生 |
| | `trg_schedule_before_delete` | 有挂号记录的排班不得删除 |
| `doctors` | `trg_doctor_before_delete` | 有排班的医生不得删除（改用 `is_active` 软删除） |
| 7 张表 | `trg_*_touch` | 自动维护 `updated_at` |

### 关键约束

- **挂号费由数据库定价**：写单时 `fee` 取自 `doctors` 子查询；外键 `fk_appt_doctor_fee (doctor_id, fee) → doctors (id, fee)`
  保证挂号单上的价格必然是该医生的现价档位，`UPDATE appointments SET fee = 1` 会被直接拒绝。
- **同一号源不重复预约**：部分唯一索引 `uq_appt_active_slot (schedule_id, patient_id) WHERE status IN ('booked','completed')`，
  取消后可以重新预约。
- **号序唯一**：`uq_appt_schedule_seq (schedule_id, seq_no)`；退号留空号，不重排后续号序。
- **已约数范围**：`ck_schedule_booked_range` 保证 `0 ≤ booked_count ≤ max_quota`。
- **身份证大小写不敏感唯一**：`UNIQUE INDEX ON patients (UPPER(id_card))`，末位 `x` / `X` 视为同一人。
- **预约单号唯一**：`uq_appt_no`，10 位随机字符，供患者凭单号查询。

---

## 业务规则

以下规则全部在数据库层强制执行：

| 规则 | 实现 |
|---|---|
| 号源自动增减；号序自动分配 | `trg_appt_after_insert` / `after_update`、`trg_appt_before_insert` |
| 不能预约已过去的日期、已停诊的排班 | `trg_appt_before_insert` |
| 同一号源不能重复预约 | 部分唯一索引 `uq_appt_active_slot` |
| 同一天同一科室只能有一个有效号 | `trg_appt_before_insert` |
| 同一天最多 2 个有效号 | `trg_appt_guard` |
| 近 30 天患者自行取消 ≥ 5 次、近 180 天爽约 ≥ 3 次，暂停线上挂号 | `trg_appt_guard`（管理员退号、停诊退号不计入） |
| 黑名单内的就诊人不能线上挂号 | `trg_appt_guard` |
| 状态只能 `booked → cancelled / completed / no_show` | `trg_appt_before_update` |
| 停诊时该时段全部待就诊号自动取消 | 接口批量更新，触发器逐条回收号源、写日志 |
| 满号才能候补；退号自动补位，保留 2 小时，超时顺延 | `waitlist` 触发器 + `fn_offer_next_waitlist` |
| 每次状态变更留痕（谁、何时、旧值、新值） | `appointment_log` + 会话变量 `app.operator` |

---

## 并发控制

挂号是「读余号 → 判断 → 写入」，若不加锁，两个请求可能同时读到「还剩 1 个号」并都写入，造成超卖。

1. `trg_appt_before_insert` 首先 `SELECT … FOR UPDATE` 锁住排班行，并发请求在此排队，后来者读到的已约数一定是最新值；
2. 号源挂在排班行上，全程只锁一行，不存在加锁顺序问题；
3. `ck_schedule_booked_range` 与 `uq_appt_active_slot` 作为最后一道防线，即使禁用触发器也写不进超卖数据。

实测：20 个线程同时抢最后 1 个号，成功 1 个、失败 19 个，`booked_count = 1`。

---

## 安全与隐私

| 方面 | 做法 |
|---|---|
| 实名校验 | `fn_verify_identity(姓名, 身份证号)` 模拟公安二要素：人口库 `citizen_registry` 中有该身份证号则比对姓名；没有则模拟查询成功并登记，此后一号一名。每次校验写 `identity_verify_log` |
| 患者凭证 | 实名校验通过后签发 30 天有效的随机凭证（请求头 `X-Patient-Token`，库中只存 SHA-256）。查看 / 取消挂号、修改资料、候补、站内信都必须持有本人凭证，不再凭身份证号放行 |
| 后台认证 | scrypt 口令散列（独立随机盐，定长比较）；登录签发随机令牌并落库，可真正注销 |
| 后台授权 | 按角色校验（`require_role`），前端隐藏无权限页签，服务端再拦一次 |
| 隐私脱敏 | 后台列表默认脱敏；查看明文需管理员 / 审计员角色并填写理由，写入 `access_log` |
| 防刷 | 滑动窗口限流（挂号 / 候补 20 次每分钟、登录与患者验证 10 次每分钟、其他 300 次）；余号紧张时启用算术验证码 |
| 静态文件 | Flask 只公开 `web/` 目录，源码、配置、`.git`、日志不可通过 HTTP 访问 |
| 敏感配置 | `mail.env`（SMTP 授权码）与发信日志已加入 `.gitignore` |

**短信验证码（备用）**：`/api/patient-auth/request` 与 `/verify` 保留了「验证码发到档案登记手机 / 邮箱」的流程。
目前未接入短信平台、邮件为 dry-run，因此处于演示模式：验证码随响应返回并由前端自动填入。
接入真实通道后演示模式自动关闭，也可通过 `DEMO_CODE=0` 强制关闭。

---

## 接口一览

### 公开

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/departments` | 科室列表 |
| GET | `/api/departments/<id>/doctors` | 科室下的医生及余号 |
| GET | `/api/doctors` | 医生列表 |
| GET | `/api/doctors/<id>/schedules?days=14` | 医生未来排班 |
| GET | `/api/captcha` | 放号验证码 |
| POST | `/api/appointments` | 挂号（含实名校验） |
| POST | `/api/waitlist` | 排候补（含实名校验） |
| POST | `/api/patient-auth/realname` | 实名校验，换取患者凭证 |
| POST | `/api/patient-auth/request` · `/verify` | 短信验证码换取凭证（备用） |
| GET | `/api/health` | 健康检查 |

### 需要患者凭证

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/appointments?idCard=` | 本人挂号记录 |
| POST | `/api/appointments/<id>/cancel` | 取消本人挂号（后台管理员 / 窗口也可调用） |
| GET · PATCH | `/api/patients/mine?idCard=` | 查看 / 修改本人资料 |
| GET | `/api/waitlist?idCard=` | 本人候补 |
| POST | `/api/waitlist/<id>/cancel` · `/confirm` | 放弃候补 / 候补转正 |
| GET | `/api/notifications?idCard=` | 站内信 |

### 需要后台登录

| 方法 | 路径 | 角色 |
|---|---|---|
| POST | `/api/auth/login` · `/logout`，GET `/api/auth/me` | — |
| GET | `/api/appointments`、`/api/appointments/<id>`、`/<id>/logs` | 登录即可（明文需管理员 / 审计员） |
| GET | `/api/schedules`、`/api/stats/doctors` | 登录即可 |
| PATCH | `/api/schedules/<id>/quota` | 管理员、窗口 |
| POST | `/api/schedules/<id>/toggle` | 管理员、窗口 |
| POST | `/api/admin/proxy-booking` | 管理员、窗口 |
| GET | `/api/admin/waitlist` | 全部角色 |
| GET | `/api/admin/access-log` · `/outbox` · `/blacklist` | 管理员、审计员 |
| POST · DELETE | `/api/admin/blacklist` | 管理员 |
| POST | `/api/admin/notify/scan` | 管理员 |

---

## 已知限制

- **实名校验基于「姓名与身份证号未泄露」的假设**。二要素在信息泄露时不足以证明本人，
  真实系统应使用运营商三要素核验、人脸核身或医保电子凭证。
- **未接入短信平台**，短信验证码流程处于演示模式。
- 医院名称、科室图标、医生简介是前端常量，不入库（它们不参与任何查询或约束）。

---

## 版本演进

| 版本 | 时间 | 主要变化 |
|---|---|---|
| v1 | 2026-10 上旬 | 基础挂号流程；号源计数在应用层维护 |
| — | 2026-10-17 | 后端由 Node + Express 改写为 Python + Flask，接口与数据保持不变（旧版源码归档于工作区 `legacy/legacy-node/`） |
| v2 | 2026-10-28 | 新增 `patients`、`appointment_log`；号源、号序、状态流转、审计下沉到触发器；挂号费改由外键约束 |
| v3 | 2026-10-29 | 候补、通知发件箱、访问日志、黑名单、角色权限、预约单号；患者凭证与模拟实名校验；限挂规则；移动端适配 |
