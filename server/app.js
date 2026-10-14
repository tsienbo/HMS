/* ============================================================
 * 智慧医院预约挂号系统 —— 后端（全部代码都在这一个文件里）
 *
 * 怎么用：
 *   node server/app.js            启动服务，打开 http://127.0.0.1:3000/
 *   node server/app.js --init     初始化数据库（幂等：缺什么补什么，不动已有数据）
 *   node server/app.js --force    删表重建（★ 会清空所有挂号记录）
 *
 * 本文件从上往下依次是：
 *   一、连接数据库
 *   二、写死的基础数据（科室 / 医生 / 管理员账号）
 *   三、初始化数据库（建库 → 建表 → 灌数据 → 铺排班 → 自检）
 *   四、口令与就诊人信息校验
 *   五、数据库行 → 返回给前端的对象（字段改名）
 *   六、判断「这次请求是谁在操作」
 *   七、全部接口（一个接口一段，SQL 就写在里面）
 *   八、404 与兜底错误处理
 *   九、启动
 *
 * 建表语句单独放在 server/schema.sql 里，本文件用的时候读它。
 * ============================================================ */

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const express = require('express');
const pg = require('pg');

/* ============================================================
 * 一、连接数据库
 * ============================================================ */

/* 数据库地址和账号密码。换一台电脑只改这四行。 */
const DB_CONFIG = {
  host: '127.0.0.1',
  port: 5432,
  user: 'postgres',
  password: '123456',
};

/* 库名。平时就是 hospital_registration。
 * 只有跑测试的时候会用 PGDATABASE=临时库名 起第二个服务，
 * 免得测试把自己的正式数据改坏；平时不带这个环境变量。 */
const DB_NAME = process.env.PGDATABASE || 'hospital_registration';

/* pg 这个库默认把 NUMERIC 读成字符串（怕丢精度）、把 DATE 读成带时区的 Date。
 * 不处理的话：挂号费会变成 "50.00" 字符串，就诊日期可能整体差一天。 */
pg.types.setTypeParser(pg.types.builtins.NUMERIC, (v) => (v === null ? null : parseFloat(v)));
pg.types.setTypeParser(pg.types.builtins.INT8, (v) => (v === null ? null : parseInt(v, 10)));
pg.types.setTypeParser(pg.types.builtins.DATE, (v) => v);

/* 连接池：max 10 表示最多同时开 10 条连接，够这个项目用了。 */
const pool = new pg.Pool({
  ...DB_CONFIG,
  database: DB_NAME,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

/* 空闲连接出错时不要让整个进程挂掉，打印出来就行 */
pool.on('error', (err) => {
  console.error('[db] 连接池出错：', err.message);
});

/* 查一次数据库。用法：
 *     const r = await query('SELECT * FROM doctors WHERE id = $1', ['DR01']);
 *
 * ★ 一定要用 $1 / $2 这种占位符传参数，不要自己把变量拼进 SQL 字符串。
 *   拼字符串会被 SQL 注入：用户把 idCard 填成  ' OR '1'='1  就能把整张表读走。
 *   用 $1 传参时，pg 会把参数单独送过去，数据库不会把它当成 SQL 代码。
 */
async function query(sql, params) {
  return pool.query(sql, params);
}

/* 启动时检查数据库连不连得上 */
async function healthCheck() {
  const r = await pool.query('SELECT NOW() AS now, current_database() AS db');
  return r.rows[0];
}

/* ============================================================
 * 二、写死的基础数据
 *
 * 内容不多，摆在眼前比藏在配置文件里好读。
 * ============================================================ */

/* 科室。单院区部署，医院是部署期常量，所以没有 hospitals 表；
 * 医院名称/等级/地址和科室图标都在前端 js/app.js 里。 */
const DEPARTMENTS = [
  { id: 'D01', name: '内科', description: '感冒发热、高血压、糖尿病等常见内科疾病' },
  { id: 'D02', name: '外科', description: '外伤处理、体表肿物、术后复查' },
  { id: 'D03', name: '儿科', description: '0-14 岁儿童常见病、生长发育咨询' },
  { id: 'D04', name: '骨科', description: '骨折、关节疼痛、颈腰椎疾病' },
  { id: 'D05', name: '眼科', description: '视力检查、结膜炎、白内障筛查' },
];

/* 后台账号。这里写的是明文，灌库时派生成散列再存，明文不落库。
 * 只有一个账号，所以没有 role 列。 */
const USERS = [
  { id: 'U01', username: 'admin', password: 'admin123', displayName: '张明' },
];

/* 医生。挂号费由数据库约束锁死在「职称 → 价格」这一档上。 */
const DOCTORS = [
  { id: 'DR01', deptId: 'D01', name: '张建国', title: '主任医师', fee: 50 },
  { id: 'DR02', deptId: 'D01', name: '李慧敏', title: '副主任医师', fee: 30 },
  { id: 'DR03', deptId: 'D01', name: '王振宇', title: '主治医师', fee: 15 },
  { id: 'DR04', deptId: 'D02', name: '陈国强', title: '主任医师', fee: 50 },
  { id: 'DR05', deptId: 'D02', name: '刘文博', title: '主治医师', fee: 15 },
  { id: 'DR06', deptId: 'D03', name: '赵晓萍', title: '副主任医师', fee: 30 },
  { id: 'DR07', deptId: 'D03', name: '孙宁', title: '主治医师', fee: 15 },
  { id: 'DR08', deptId: 'D04', name: '周海涛', title: '主任医师', fee: 50 },
  { id: 'DR09', deptId: 'D04', name: '吴磊', title: '主治医师', fee: 15 },
  { id: 'DR10', deptId: 'D05', name: '郑晓岚', title: '副主任医师', fee: 30 },
];

/* 号源的最小单位就是「上午 / 下午」，不拆 30 分钟一格。
 * 患者挂号只选半天，具体就诊顺序以到院取号后的现场叫号为准。 */
const PERIODS = [
  { key: 'AM', period: '上午' },
  { key: 'PM', period: '下午' },
];

/* 一个半天放多少号，按职称定档：职称越高号越少（越难挂）。 */
const QUOTA_BY_TITLE = {
  主任医师: 20,
  副主任医师: 25,
  主治医师: 30,
};

/* 一次铺多少天的排班 */
const SEED_DAYS = 14;

/* 登录后签发的令牌多久过期（小时） */
const SESSION_TTL_HOURS = 12;

/* ============================================================
 * 三、初始化数据库
 * ============================================================ */

const WEEK_LABEL = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

function pad2(n) { return String(n).padStart(2, '0'); }

function dateToStr(d) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function strToDate(s) {
  const p = String(s).slice(0, 10).split('-').map(Number);
  return new Date(p[0], p[1] - 1, p[2]);
}

/* 从今天起，连续 days 天的日期列表 */
function buildDateRange(days) {
  const list = [];
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  for (let i = 0; i < days; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    const ds = dateToStr(d);
    list.push({ date: ds, weekday: WEEK_LABEL[strToDate(ds).getDay()] });
  }
  return list;
}

/* 生成排班：未来 days 天 × 每位医生 × 上午/下午各一条。
 * 每条排班的已约数都是 0 —— 号是患者自己挂出来的。 */
function buildSchedules(days) {
  const out = [];
  buildDateRange(days).forEach((d) => {
    DOCTORS.forEach((doc) => {
      PERIODS.forEach((p) => {
        out.push({
          id: `SC_${doc.id}_${d.date}_${p.key}`,
          doctorId: doc.id,
          deptId: doc.deptId,
          date: d.date,
          weekday: d.weekday,
          period: p.period,
          quotaTotal: QUOTA_BY_TITLE[doc.title],
        });
      });
    });
  });
  return out;
}

/* 建库：连到 PostgreSQL 自带的 postgres 库上，才能 CREATE DATABASE */
async function ensureDatabase() {
  const client = new pg.Client({ ...DB_CONFIG, database: 'postgres' });
  await client.connect();
  try {
    const r = await client.query('SELECT 1 FROM pg_database WHERE datname = $1', [DB_NAME]);
    if (r.rowCount === 0) {
      await client.query(`CREATE DATABASE "${DB_NAME.replace(/"/g, '""')}" ENCODING 'UTF8'`);
      console.log(`  · 已创建数据库 ${DB_NAME}`);
    } else {
      console.log(`  · 数据库 ${DB_NAME} 已存在`);
    }
  } finally {
    await client.end();
  }
}

/* schema.sql 应该建出来的表 */
const EXPECTED_TABLES = ['departments', 'doctors', 'schedules', 'appointments', 'users', 'user_sessions'];

/* 看看表在不在 */
async function inspectSchema() {
  const r = await pool.query(
    `SELECT tablename FROM pg_tables
      WHERE schemaname = 'public' AND tablename = ANY($1::text[])`,
    [EXPECTED_TABLES]
  );
  const present = r.rows.map((x) => x.tablename);
  const missing = EXPECTED_TABLES.filter((t) => !present.includes(t));
  return { missing, complete: missing.length === 0 };
}

/* 建表：schema.sql 一次性发过去。PostgreSQL 对「一次查询里的多条语句」
 * 按一个隐式事务处理，所以要么全建成、要么全回滚。 */
async function runSchema() {
  const sql = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
  await pool.query(sql);
  console.log('  · 表结构已创建（6 张表 + 约束 + 索引）');
}

/* 灌基础数据。CASCADE 会连带清掉排班与挂号 —— 只有基础数据为空时才会走到这里 */
async function seedReferenceData() {
  await pool.query('TRUNCATE departments, doctors, users RESTART IDENTITY CASCADE');

  for (const d of DEPARTMENTS) {
    await pool.query(
      'INSERT INTO departments (id, name, description) VALUES ($1, $2, $3)',
      [d.id, d.name, d.description]
    );
  }
  for (const d of DOCTORS) {
    await pool.query(
      'INSERT INTO doctors (id, dept_id, name, title, fee) VALUES ($1, $2, $3, $4, $5)',
      [d.id, d.deptId, d.name, d.title, d.fee]
    );
  }
  /* 明文口令在这里派生成散列后写库 */
  for (const u of USERS) {
    await pool.query(
      `INSERT INTO users (id, username, password_hash, display_name, status)
       VALUES ($1, $2, $3, $4, 'active')`,
      [u.id, u.username, hashPassword(u.password), u.displayName]
    );
  }

  console.log(`  · 基础数据：科室 ${DEPARTMENTS.length} / 医生 ${DOCTORS.length} / 后台账号 ${USERS.length}`);
  USERS.forEach((u) => {
    console.log(`      管理员  ${u.username} / ${u.password}（${u.displayName}）`);
  });
}

/* 铺排班。排班编号 SC_医生_日期_AM|PM 本身就是唯一的，
 * 已经存在的直接跳过，绝不覆盖已有的号源和挂号。 */
async function ensureSchedules(days) {
  const list = buildSchedules(days);
  if (list.length === 0) return 0;

  const dates = [...new Set(list.map((s) => s.date))];
  const existRes = await pool.query(
    'SELECT id FROM schedules WHERE work_date = ANY($1::date[])',
    [dates]
  );
  const exist = new Set(existRes.rows.map((r) => r.id));

  let n = 0;
  for (const sc of list) {
    if (exist.has(sc.id)) continue;
    await pool.query(
      `INSERT INTO schedules
         (id, doctor_id, dept_id, work_date, weekday, period, quota_total, quota_booked, closed)
       VALUES ($1, $2, $3, $4, $5, $6, $7, 0, FALSE)`,
      [sc.id, sc.doctorId, sc.deptId, sc.date, sc.weekday, sc.period, sc.quotaTotal]
    );
    n += 1;
  }
  return n;
}

/* 一致性自检：所有排班的已约号源之和，应当等于「待就诊」的挂号数。
 * 对不上就说明号源和挂号记录脱节了（退号没还号源、挂号没扣号源…）。 */
async function verifyConsistency() {
  const a = await pool.query(`
    SELECT (SELECT COALESCE(SUM(quota_booked), 0) FROM schedules)::int AS booked,
           (SELECT COUNT(*) FROM appointments WHERE status = 'active')::int AS active
  `);

  const bad = await pool.query(`
    SELECT s.id, s.period, s.quota_booked,
           (SELECT COUNT(*) FROM appointments a
             WHERE a.schedule_id = s.id AND a.status = 'active') AS actual
      FROM schedules s
     WHERE s.quota_booked <> (SELECT COUNT(*) FROM appointments a
                               WHERE a.schedule_id = s.id AND a.status = 'active')
     LIMIT 20
  `);

  return {
    ok: a.rows[0].booked === a.rows[0].active && bad.rowCount === 0,
    booked: a.rows[0].booked,
    active: a.rows[0].active,
    bad: bad.rows,
  };
}

/* 初始化的主流程。force = true 表示删表重建（会清空所有挂号） */
async function initDatabase(force) {
  const t0 = Date.now();

  console.log('\n初始化数据库...\n');
  await ensureDatabase();

  /* --- 表结构 --- */
  const schema = await inspectSchema();
  if (force) {
    console.log('  · --force：删除并重建所有表');
    await runSchema();
  } else if (schema.complete) {
    console.log('  · 表结构完整，跳过重建（如需清空重建请用 --force）');
  } else {
    console.log(`  · 表结构不完整，缺失：${schema.missing.join(', ')} → 重建`);
    await runSchema();
  }

  /* --- 基础数据 --- */
  const ref = (await pool.query(`
    SELECT (SELECT COUNT(*) FROM departments)::int AS departments,
           (SELECT COUNT(*) FROM doctors)::int     AS doctors,
           (SELECT COUNT(*) FROM users)::int       AS users
  `)).rows[0];
  const refEmpty = !ref.departments || !ref.doctors || !ref.users;

  if (force || refEmpty) {
    if (force && !refEmpty) console.log('  · --force：清空基础数据后重新灌入');
    if (refEmpty && !force) {
      console.log(`  · 基础数据不完整（科室 ${ref.departments} / 医生 ${ref.doctors} / 账号 ${ref.users}）→ 重新灌入`);
    }
    await seedReferenceData();
  } else {
    console.log(`  · 基础数据完整（科室 ${ref.departments} / 医生 ${ref.doctors} / 账号 ${ref.users}），跳过灌入`);
  }

  /* --- 排班与号源 --- */
  const scCount = (await pool.query('SELECT COUNT(*)::int AS c FROM schedules')).rows[0].c;
  if (force || scCount === 0) {
    console.log('\n生成排班与号源...');
    const n = await ensureSchedules(SEED_DAYS);
    console.log(`  · 排班 ${n} 条（已约数从 0 开始）`);
  } else {
    console.log(`\n  · 已有排班 ${scCount} 条，跳过生成`);
  }

  /* --- 一致性自检（每次都跑）--- */
  const ck = await verifyConsistency();
  if (ck.ok) {
    console.log(`  · 号源一致性校验通过（booked 合计 ${ck.booked} = active 挂号 ${ck.active}）`);
  } else {
    console.log('  ✗ 号源一致性校验失败！');
    console.log(`    booked 合计 ${ck.booked} vs active 挂号 ${ck.active}`);
    ck.bad.forEach((m) => {
      console.log(`      ${m.id}（${m.period}）: booked=${m.quota_booked} actual=${m.actual}`);
    });
  }

  const days = (await pool.query(
    'SELECT MIN(work_date) AS a, MAX(work_date) AS b FROM schedules'
  )).rows[0];
  if (days.a) {
    console.log(`  · 可预约日期范围：${String(days.a).slice(0, 10)} ~ ${String(days.b).slice(0, 10)}`);
  }

  console.log(`\n完成，耗时 ${((Date.now() - t0) / 1000).toFixed(1)}s\n`);
}

/* ============================================================
 * 四、口令与就诊人信息校验
 * ============================================================ */

/* 存进数据库的格式：  scrypt$<盐>$<散列>
 * 每条口令的盐都不一样，所以两个人密码相同，存进去也不一样。 */
function hashPassword(plain) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(String(plain), salt, 64).toString('hex');
  return `scrypt$${salt}$${hash}`;
}

function verifyPassword(plain, stored) {
  const parts = String(stored || '').split('$');
  if (parts.length !== 3 || parts[0] !== 'scrypt') return false;

  const salt = parts[1];
  const want = Buffer.from(parts[2], 'hex');
  const calc = crypto.scryptSync(String(plain), salt, 64);

  /* 定长比较，避免按字节短路带来的时间差 */
  return want.length === calc.length && crypto.timingSafeEqual(calc, want);
}

/* ---------- 就诊人信息校验 ----------
 * 前端也会校验一遍，但前端的东西可以绕过，
 * 所以服务端必须独立再校验一次，绝不能信前端传什么就存什么。 */

const ID_WEIGHTS = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const ID_CODES = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

/* 身份证：18 位 + 校验位 + 出生日期合法性 */
function checkIdCard(input) {
  const v = String(input || '').trim().toUpperCase();
  if (!/^\d{17}[\dX]$/.test(v)) return { ok: false, msg: '身份证号格式不正确（需 18 位）' };

  let sum = 0;
  for (let i = 0; i < 17; i++) sum += Number(v[i]) * ID_WEIGHTS[i];
  if (ID_CODES[sum % 11] !== v[17]) return { ok: false, msg: '身份证号校验位错误，请核对' };

  const y = Number(v.slice(6, 10));
  const m = Number(v.slice(10, 12));
  const d = Number(v.slice(12, 14));
  if (y < 1900 || y > new Date().getFullYear()) return { ok: false, msg: '身份证中的出生年份不合法' };
  if (m < 1 || m > 12) return { ok: false, msg: '身份证中的出生月份不合法' };
  if (d < 1 || d > 31) return { ok: false, msg: '身份证中的出生日期不合法' };

  return { ok: true, value: v };
}

function checkPhone(input) {
  const v = String(input || '').trim();
  if (!/^1[3-9]\d{9}$/.test(v)) return { ok: false, msg: '手机号格式不正确' };
  return { ok: true, value: v };
}

function checkName(input) {
  const v = String(input || '').trim();
  if (!/^[\u4e00-\u9fa5·]{2,20}$/.test(v)) return { ok: false, msg: '姓名需为 2-20 个中文字符' };
  return { ok: true, value: v };
}

/* 一次把三个都校验了，第一个不通过就返回那一条 */
function checkPatient(p) {
  const n = checkName(p && p.name);
  if (!n.ok) return n;
  const i = checkIdCard(p && p.idCard);
  if (!i.ok) return i;
  const ph = checkPhone(p && p.phone);
  if (!ph.ok) return ph;
  return { ok: true, value: { name: n.value, idCard: i.value, phone: ph.value } };
}

/* ============================================================
 * 五、数据库行 → 返回给前端的对象
 *
 * 数据库列名是 dept_id 这种下划线写法，前端用的是 deptId。
 * 转换只在这几个函数里做，改一处就够了。
 * ============================================================ */

function mapDepartment(r) {
  return { id: r.id, name: r.name, desc: r.description };
}

function mapDoctor(r) {
  return {
    id: r.id,
    deptId: r.dept_id,
    name: r.name,
    title: r.title,
    fee: Number(r.fee),
    /* 只有 /departments/:id/doctors 会带上它，用来显示「剩 N 号 / 已约满」 */
    remain: r.remain === undefined || r.remain === null ? undefined : Number(r.remain),
  };
}

/* 一条排班 = 某医生某天某个半天（上午/下午），号源量就挂在这一行上 */
function mapSchedule(r) {
  const total = Number(r.quota_total);
  const booked = Number(r.quota_booked);
  return {
    id: r.id,
    doctorId: r.doctor_id,
    deptId: r.dept_id,
    date: String(r.work_date).slice(0, 10),
    weekday: r.weekday,
    period: r.period,
    closed: r.closed,
    quotaTotal: total,
    quotaBooked: booked,
    remain: Math.max(0, total - booked),
  };
}

/* maskIdCard：患者端自助查询时把身份证号打码，管理端看完整的 */
function mapAppointment(r, maskIdCard) {
  const idCard = String(r.id_card || '');
  return {
    id: r.id,
    seqNo: Number(r.seq_no),
    scheduleId: r.schedule_id,
    deptId: r.dept_id,
    doctorId: r.doctor_id,
    date: String(r.work_date).slice(0, 10),
    weekday: r.weekday,
    period: r.period,
    patientName: r.patient_name,
    idCard: maskIdCard && idCard.length >= 10
      ? `${idCard.slice(0, 6)}********${idCard.slice(-4)}`
      : idCard,
    phone: r.phone,
    fee: Number(r.fee),
    status: r.status,
    closeNote: r.close_note || null,
    createdAt: r.created_at instanceof Date ? r.created_at.toISOString() : r.created_at,
    cancelledAt: r.cancelled_at
      ? (r.cancelled_at instanceof Date ? r.cancelled_at.toISOString() : r.cancelled_at)
      : null,
  };
}

/* ============================================================
 * 六、判断「这次请求是谁在操作」
 *
 * 登录成功后服务端发一个随机令牌存进 user_sessions 表，
 * 前端每次请求把它放在 Authorization: Bearer xxx 里。
 * 这里负责把令牌换成用户；没登录就返回 null。
 * ============================================================ */

async function getLoginUser(req) {
  const m = /^Bearer\s+(.+)$/i.exec(String(req.get('authorization') || '').trim());
  if (!m) return null;

  const r = await query(
    `SELECT s.token, s.expires_at, u.id, u.username, u.display_name
       FROM user_sessions s
       JOIN users u ON u.id = s.user_id
      WHERE s.token = $1 AND s.expires_at > NOW() AND u.status = 'active'`,
    [m[1].trim()]
  );
  if (r.rowCount === 0) return null;

  const row = r.rows[0];
  return {
    token: row.token,
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    expiresAt: row.expires_at instanceof Date ? row.expires_at.toISOString() : row.expires_at,
  };
}

/* 数据库抛出的约束错误，翻译成中文 */
function dbError(err) {
  if (err.code === '23514') return { status: 409, error: '号源已满或数据不合法' };
  if (err.code === '23505') return { status: 409, error: '数据重复，请勿重复提交' };
  if (err.code === '23503') return { status: 400, error: '关联数据不存在' };
  return { status: 500, error: '服务器内部错误：' + err.message };
}

/* ============================================================
 * 七、全部接口
 * ============================================================ */

const app = express();

/* 后端监听的端口。平时就是 3000。 */
const PORT = Number(process.env.PORT || 3000);

/* 让 req.body 能读到前端发来的 JSON */
app.use(express.json({ limit: '256kb' }));

/* 前端页面（index.html / css / js）也由这个服务一起发出去，
 * 所以不用再开一个端口。__dirname 是 server/，往上一层就是项目根目录。 */
app.use(express.static(path.join(__dirname, '..')));

/* ------------------------------------------------------------
 * 7.1 登录 / 注销 / 当前用户
 * ------------------------------------------------------------ */

/* 登录：查用户表 → 比对口令散列 → 发一个随机令牌存进 user_sessions */
app.post('/api/auth/login', async (req, res) => {
  try {
    const username = String((req.body && req.body.username) || '').trim().toLowerCase();
    const password = String((req.body && req.body.password) || '');

    if (!username || !password) {
      return res.status(400).json({ error: '请输入用户名与密码' });
    }

    const r = await query(
      'SELECT id, username, password_hash, display_name, status FROM users WHERE username = $1',
      [username]
    );

    /* 「账号不存在」和「密码错误」回同一句话，别让人试出哪些账号存在 */
    const FAIL = { error: '用户名或密码错误', code: 'BAD_CREDENTIALS' };
    if (r.rowCount === 0) return res.status(401).json(FAIL);

    const u = r.rows[0];
    if (!verifyPassword(password, u.password_hash)) return res.status(401).json(FAIL);
    if (u.status !== 'active') {
      return res.status(403).json({ error: '该账号已被停用，请联系管理员', code: 'ACCOUNT_DISABLED' });
    }

    const token = crypto.randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + SESSION_TTL_HOURS * 3600 * 1000);

    /* 顺手清掉过期会话，省得单独写个定时任务 */
    await query('DELETE FROM user_sessions WHERE expires_at <= NOW()');
    await query(
      'INSERT INTO user_sessions (token, user_id, expires_at) VALUES ($1, $2, $3)',
      [token, u.id, expiresAt]
    );
    await query('UPDATE users SET last_login_at = NOW() WHERE id = $1', [u.id]);

    res.json({
      token,
      expiresAt: expiresAt.toISOString(),
      ttlHours: SESSION_TTL_HOURS,
      user: { id: u.id, username: u.username, displayName: u.display_name },
    });
  } catch (err) {
    console.error('[登录]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 注销：把会话那一行删掉 */
app.post('/api/auth/logout', async (req, res) => {
  try {
    const user = await getLoginUser(req);
    if (!user) return res.status(401).json({ error: '未登录或登录已过期，请重新登录' });

    await query('DELETE FROM user_sessions WHERE token = $1', [user.token]);
    res.json({ ok: true });
  } catch (err) {
    console.error('[注销]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 当前登录用户：前端刷新页面时用它确认本地令牌还有效 */
app.get('/api/auth/me', async (req, res) => {
  try {
    const user = await getLoginUser(req);
    if (!user) return res.status(401).json({ error: '未登录或登录已过期，请重新登录' });

    const r = await query(
      'SELECT id, username, display_name FROM users WHERE id = $1',
      [user.id]
    );
    if (r.rowCount === 0) return res.status(401).json({ error: '账号不存在', code: 'UNAUTHORIZED' });

    const u = r.rows[0];
    res.json({
      user: { id: u.id, username: u.username, displayName: u.display_name },
      expiresAt: user.expiresAt,
    });
  } catch (err) {
    console.error('[当前用户]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* ------------------------------------------------------------
 * 7.2 科室 / 医生 / 排班（都是只读查询）
 * ------------------------------------------------------------ */

/* 全部科室 */
app.get('/api/departments', async (req, res) => {
  try {
    const r = await query('SELECT id, name, description FROM departments ORDER BY id');
    res.json(r.rows.map(mapDepartment));
  } catch (err) {
    console.error('[科室列表]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 某科室的医生，带上「还剩多少号」。
 * remain 只统计今天及以后、没停诊的排班。 */
app.get('/api/departments/:id/doctors', async (req, res) => {
  try {
    const r = await query(
      `SELECT d.*,
              COALESCE((
                SELECT SUM(s.quota_total - s.quota_booked)
                  FROM schedules s
                 WHERE s.doctor_id = d.id
                   AND s.closed = FALSE
                   AND s.work_date >= CURRENT_DATE
              ), 0)::int AS remain
         FROM doctors d
        WHERE d.dept_id = $1
        ORDER BY CASE d.title WHEN '主任医师' THEN 1 WHEN '副主任医师' THEN 2 ELSE 3 END, d.id`,
      [req.params.id]
    );
    res.json(r.rows.map(mapDoctor));
  } catch (err) {
    console.error('[科室医生]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 全部医生（前端启动时一次性拉走缓存起来） */
app.get('/api/doctors', async (req, res) => {
  try {
    const r = await query('SELECT * FROM doctors ORDER BY dept_id, id');
    res.json(r.rows.map(mapDoctor));
  } catch (err) {
    console.error('[医生列表]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 某位医生未来 N 天的排班（默认 7 天，最多 30 天） */
app.get('/api/doctors/:id/schedules', async (req, res) => {
  try {
    const days = Math.min(Math.max(Number(req.query.days) || 7, 1), 30);
    const r = await query(
      `SELECT * FROM schedules
        WHERE doctor_id = $1
          AND work_date >= CURRENT_DATE
          AND work_date < CURRENT_DATE + $2::int
        ORDER BY work_date, period`,
      [req.params.id, days]
    );
    res.json(r.rows.map(mapSchedule));
  } catch (err) {
    console.error('[医生排班]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 排班列表（管理端用）。可以按日期、科室筛 */
app.get('/api/schedules', async (req, res) => {
  try {
    const cond = [];
    const params = [];

    if (req.query.date) {
      params.push(req.query.date);
      cond.push(`work_date = $${params.length}::date`);
    } else {
      cond.push('work_date >= CURRENT_DATE');
    }
    if (req.query.deptId) {
      params.push(req.query.deptId);
      cond.push(`dept_id = $${params.length}`);
    }

    const r = await query(
      `SELECT * FROM schedules
        WHERE ${cond.join(' AND ')}
        ORDER BY work_date, doctor_id, period
        LIMIT 400`,
      params
    );
    res.json(r.rows.map(mapSchedule));
  } catch (err) {
    console.error('[排班列表]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* ------------------------------------------------------------
 * 7.3 挂号
 * ------------------------------------------------------------ */

/* 挂号。
 *
 * 这里没有用事务，靠的是「一条自带条件的 UPDATE」：
 *     UPDATE schedules SET quota_booked = quota_booked + 1
 *      WHERE id = $1 AND quota_booked < quota_total
 * 数据库执行这条语句时会给那一行加锁，而且「判断」和「加一」是在同一步里做完的。
 * 所以 20 个人同时抢最后 1 个号，只有 1 个人能更新成功（rowCount = 1），
 * 其余 19 个人拿到 rowCount = 0，直接回「号源已满」。
 * 不会超卖，也不需要用 SELECT ... FOR UPDATE 那一套。
 *
 * RETURNING 回来的 quota_booked 就是「该半天的第几个号」，正好当取号序号用。
 *
 * 挂号费不由这段代码决定：写单的 INSERT 语句里，fee 那一列填的是一个子查询
 * (SELECT fee FROM doctors WHERE id = $4)，价格就地取自价目表。
 * 请求体里带什么价格都不参与运算；就算有人绕过接口手写 SQL，
 * 数据库还有 fk_appt_doctor_fee 这条外键兜底。
 * 详见 schema.sql 里 appointments.fee 上方的注释。
 */
app.post('/api/appointments', async (req, res) => {
  const body = req.body || {};

  try {
    if (!body.scheduleId) return res.status(400).json({ error: '缺少排班参数' });

    const p = checkPatient(body.patient);
    if (!p.ok) return res.status(400).json({ error: p.msg });

    /* 先确认这条排班存在、没停诊、日期没过去 */
    const scRes = await query('SELECT * FROM schedules WHERE id = $1', [body.scheduleId]);
    if (scRes.rowCount === 0) return res.status(404).json({ error: '排班不存在，请刷新后重试' });
    const sc = scRes.rows[0];

    if (sc.closed) return res.status(409).json({ error: '该医生已停诊，无法挂号' });

    const workDate = String(sc.work_date).slice(0, 10);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    if (new Date(workDate + 'T00:00:00') < today) {
      return res.status(409).json({ error: '不能预约已过去的日期' });
    }

    /* ★ 扣号源（见上面的说明） */
    const upd = await query(
      `UPDATE schedules SET quota_booked = quota_booked + 1
        WHERE id = $1 AND quota_booked < quota_total
        RETURNING quota_booked`,
      [body.scheduleId]
    );
    if (upd.rowCount === 0) {
      return res.status(409).json({ error: '该时段号源已挂完，请选择其他时段' });
    }
    const seqNo = upd.rows[0].quota_booked;

    /* 挂号费不由这里决定，也不由请求体决定。
     * 下面 INSERT 的 fee 那一列填的是一个子查询，价格在 SQL 内部
     * 就地取自 doctors 价目表。所以请求体里写 fee = 1 没有任何作用。
     *
     * 子查询里那个 $4::varchar 的写法不是多余的：$4 在这条语句里出现了两次
     * （一次填 doctor_id 列，一次当子查询的查询条件），PostgreSQL 会分别去猜
     * 它的类型，猜出来一个 varchar 一个 text，于是报
     * 「inconsistent types deduced for parameter $4」。显式写上 ::varchar
     * 就是告诉数据库「两处都按 varchar 算」。 */
    /* 挂号单号（id）怎么来的：
     *   'A' + 当前时间的年月日时分秒毫秒，例如 A261014165120986，共 16 位。
     * 以前这里写的是 nextval('appointment_no_seq')，现在不再需要序列对象了。
     * 为什么不用 max(id)+1？因为并发时两条 INSERT 可能读到同一个最大值，
     * 拼出同一个单号；毫秒时间戳则不会（每一条 INSERT 都是独立语句，各取各的时间）。 */
    try {
      const ins = await query(
        `INSERT INTO appointments
           (id, seq_no, schedule_id, dept_id, doctor_id,
            work_date, weekday, period,
            patient_name, id_card, phone, fee, status)
         VALUES ('A' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS'),
                 $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                 (SELECT fee FROM doctors WHERE id = $4::varchar), 'active')
         RETURNING *`,
        [seqNo, body.scheduleId, sc.dept_id, sc.doctor_id,
          workDate, sc.weekday, sc.period,
          p.value.name, p.value.idCard, p.value.phone]
      );
      res.status(201).json(mapAppointment(ins.rows[0], false));
    } catch (err) {
      /* 写单失败就把刚才扣掉的号源还回去，不然号会白白少一个 */
      await query('UPDATE schedules SET quota_booked = quota_booked - 1 WHERE id = $1', [body.scheduleId]);
      throw err;
    }
  } catch (err) {
    console.error('[挂号]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 退号。
 * 三件事：把单据改成 cancelled、把号源还回去、把后面人的序号往前挪。
 * 同样不用事务，靠「先查再改 + 每步都带条件」保证不会改错。 */
app.post('/api/appointments/:id/cancel', async (req, res) => {
  try {
    /* 带令牌就是管理端在退号，不带就是患者自己退 */
    const user = await getLoginUser(req);

    const aptRes = await query('SELECT * FROM appointments WHERE id = $1', [req.params.id]);
    if (aptRes.rowCount === 0) return res.status(404).json({ error: '挂号记录不存在' });

    const apt = aptRes.rows[0];
    if (apt.status !== 'active') {
      return res.status(409).json({ error: '该挂号已取消，无需重复操作' });
    }

    const workDate = String(apt.work_date).slice(0, 10);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    if (new Date(workDate + 'T00:00:00') < today) {
      return res.status(409).json({ error: '就诊日期已过，无法取消' });
    }

    /* WHERE 里再带一次 status = 'active'：万一这中间有别人先退了，
     * 这里会得到 rowCount = 0，号源就不会被重复归还。 */
    const operator = user ? user.username : null;
    const upd = await query(
      `UPDATE appointments
          SET status = 'cancelled',
              cancelled_at = NOW(),
              close_note = CASE WHEN $2::text IS NULL THEN close_note
                                ELSE '管理端退号（' || $2 || '）' END
        WHERE id = $1 AND status = 'active'`,
      [req.params.id, operator]
    );
    if (upd.rowCount === 0) return res.status(409).json({ error: '该挂号已取消，无需重复操作' });

    /* 号源还回去（GREATEST 兜底，免得减成负数） */
    await query(
      'UPDATE schedules SET quota_booked = GREATEST(quota_booked - 1, 0) WHERE id = $1',
      [apt.schedule_id]
    );

    /* 后面等着的人序号往前挪一位，避免出现「空号」 */
    await query(
      `UPDATE appointments SET seq_no = seq_no - 1
        WHERE schedule_id = $1 AND status = 'active' AND seq_no > $2`,
      [apt.schedule_id, apt.seq_no]
    );

    res.json({ ok: true });
  } catch (err) {
    console.error('[退号]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 挂号记录列表。
 * 患者端（没登录）必须带 idCard，只返回他自己那几条；
 * 管理端带了有效令牌，可以跨就诊人筛选。 */
app.get('/api/appointments', async (req, res) => {
  try {
    const user = await getLoginUser(req);

    const cond = [];
    const params = [];

    if (!user && !req.query.idCard) {
      return res.status(401).json({
        error: '查询挂号记录需要提供就诊人身份证号，或登录管理端',
        code: 'UNAUTHORIZED',
      });
    }

    if (req.query.idCard) {
      params.push(String(req.query.idCard).trim().toUpperCase());
      cond.push(`id_card = $${params.length}`);
    }
    if (req.query.status && req.query.status !== 'all') {
      params.push(req.query.status);
      cond.push(`status = $${params.length}`);
    }
    if (req.query.deptId) {
      params.push(req.query.deptId);
      cond.push(`dept_id = $${params.length}`);
    }
    if (req.query.date) {
      params.push(req.query.date);
      cond.push(`work_date = $${params.length}::date`);
    }
    if (req.query.keyword) {
      params.push(`%${req.query.keyword}%`);
      const i = params.length;
      cond.push(`(patient_name ILIKE $${i} OR phone ILIKE $${i} OR id ILIKE $${i} OR id_card ILIKE $${i})`);
    }

    const where = cond.length ? `WHERE ${cond.join(' AND ')}` : '';
    const limit = Math.min(Math.max(Number(req.query.limit) || 500, 1), 2000);

    const r = await query(
      `SELECT * FROM appointments ${where}
        ORDER BY created_at DESC, id DESC
        LIMIT ${limit}`,
      params
    );
    /* 患者端不回显完整身份证号 */
    res.json(r.rows.map((row) => mapAppointment(row, !user)));
  } catch (err) {
    console.error('[挂号列表]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 单条挂号（管理端） */
app.get('/api/appointments/:id', async (req, res) => {
  try {
    const user = await getLoginUser(req);
    if (!user) return res.status(401).json({ error: '未登录或登录已过期，请重新登录' });

    const r = await query('SELECT * FROM appointments WHERE id = $1', [req.params.id]);
    if (r.rowCount === 0) return res.status(404).json({ error: '挂号记录不存在' });
    res.json(mapAppointment(r.rows[0], false));
  } catch (err) {
    console.error('[单条挂号]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* ------------------------------------------------------------
 * 7.4 管理端：调号源 / 停诊（都要登录）
 * ------------------------------------------------------------ */

/* 调整某半天排班的号源总量。
 * 一条 UPDATE 同时做「判断」和「写入」：
 * WHERE 里带上 quota_booked <= $1，改完天然满足 ck_schedule_not_oversold，
 * 不会出现「总数被改成比已约数还小」的坏数据。 */
app.patch('/api/schedules/:sid/quota', async (req, res) => {
  try {
    const user = await getLoginUser(req);
    if (!user) return res.status(401).json({ error: '未登录或登录已过期，请重新登录' });

    const total = Number(req.body && req.body.total);
    if (!Number.isInteger(total) || total < 0) {
      return res.status(400).json({ error: '号源总数必须为非负整数' });
    }

    const upd = await query(
      'UPDATE schedules SET quota_total = $1 WHERE id = $2 AND quota_booked <= $1 RETURNING *',
      [total, req.params.sid]
    );
    if (upd.rowCount === 0) {
      const cur = await query('SELECT quota_booked FROM schedules WHERE id = $1', [req.params.sid]);
      if (cur.rowCount === 0) return res.status(404).json({ error: '排班不存在' });
      return res.status(409).json({ error: `号源总数不能小于已预约数（${cur.rows[0].quota_booked}）` });
    }
    res.json(mapSchedule(upd.rows[0]));
  } catch (err) {
    console.error('[调号源]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* 停诊 / 恢复出诊。
 * 停诊时该排班下所有有效挂号自动改成 closed 并释放号源。 */
app.post('/api/schedules/:sid/toggle', async (req, res) => {
  try {
    const user = await getLoginUser(req);
    if (!user) return res.status(401).json({ error: '未登录或登录已过期，请重新登录' });

    const scRes = await query('SELECT * FROM schedules WHERE id = $1', [req.params.sid]);
    if (scRes.rowCount === 0) return res.status(404).json({ error: '排班不存在' });

    const willClose = !scRes.rows[0].closed;
    let affected = 0;

    if (willClose) {
      const upd = await query(
        `UPDATE appointments
            SET status = 'closed', cancelled_at = NOW(), close_note = '医生停诊，系统自动退号'
          WHERE schedule_id = $1 AND status = 'active'
          RETURNING id`,
        [req.params.sid]
      );
      affected = upd.rowCount;
      await query('UPDATE schedules SET quota_booked = 0 WHERE id = $1', [req.params.sid]);
    }

    await query('UPDATE schedules SET closed = $1 WHERE id = $2', [willClose, req.params.sid]);
    res.json({ ok: true, closed: willClose, affected });
  } catch (err) {
    console.error('[停诊]', err.message);
    const e = dbError(err);
    res.status(e.status).json({ error: e.error });
  }
});

/* ------------------------------------------------------------
 * 7.5 健康检查
 * ------------------------------------------------------------ */
app.get('/api/health', async (req, res) => {
  try {
    const info = await healthCheck();
    res.json({ ok: true, database: info.db, time: info.now });
  } catch (err) {
    res.status(503).json({ ok: false, error: err.message });
  }
});

/* ============================================================
 * 八、404 与兜底错误处理
 * ============================================================ */

/* 走到这里说明上面没有任何一个接口匹配上（只拦 /api，静态文件不受影响） */
app.use('/api', (req, res) => {
  res.status(404).json({ error: `接口不存在：${req.method} ${req.path}` });
});

/* 兜底：万一哪个接口漏了 try/catch，错误会落到这里，不至于把进程带崩 */
app.use((err, req, res, next) => {
  console.error('[未捕获的错误]', err.message);
  const e = dbError(err);
  res.status(e.status).json({ error: e.error });
});

/* ============================================================
 * 九、启动
 * ============================================================ */

async function startServer() {
  try {
    const info = await healthCheck();
    console.log(`\n数据库连接正常：${info.db}\n`);
  } catch (err) {
    console.error('\n无法连接数据库：', err.message);
    console.error('请检查本文件开头 DB_CONFIG 的地址、账号、密码，并确认 PostgreSQL 已启动。');
    console.error('如未初始化，请先运行：npm run db:init\n');
    process.exit(1);
  }

  app.listen(PORT, () => {
    console.log('智慧医院预约挂号系统已启动');
    console.log(`  前端页面   http://127.0.0.1:${PORT}/`);
    console.log(`  健康检查   http://127.0.0.1:${PORT}/api/health\n`);
  });
}

/* 命令行参数：
 *   什么都不带       → 启动服务
 *   --init           → 初始化数据库（幂等）
 *   --force          → 删表重建（★ 会清空所有挂号） */
const args = process.argv.slice(2);

if (args.includes('--force')) {
  initDatabase(true)
    .then(() => pool.end())
    .catch(async (err) => {
      console.error('\n初始化失败：', err.message);
      if (err.code) console.error('错误码：', err.code);
      try { await pool.end(); } catch (_) { /* 忽略 */ }
      process.exit(1);
    });
} else if (args.includes('--init')) {
  initDatabase(false)
    .then(() => pool.end())
    .catch(async (err) => {
      console.error('\n初始化失败：', err.message);
      if (err.code) console.error('错误码：', err.code);
      try { await pool.end(); } catch (_) { /* 忽略 */ }
      process.exit(1);
    });
} else {
  startServer();
}
