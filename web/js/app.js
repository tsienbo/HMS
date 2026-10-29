/* ============================================================
 * 智慧医院预约挂号系统 —— 前端
 *
 * 单文件、无构建步骤，按功能分节：
 *   一、常量（医院信息、科室图标、医生简介等展示数据）
 *   二、全局状态
 *   三、工具函数（日期、金额、转义）
 *   四、本地存储（就诊人会话、常用就诊人）
 *   五、请求层：统一的 request()、患者凭证、实名校验弹窗、全部 API 封装
 *   六、页面切换
 *   七、后台登录 / 注销 / 角色
 *   八、患者端：挂号向导、我的预约、找医生、就诊提醒、我的资料
 *   九、管理端：页签与挂号记录
 *   十、管理端：排班号源
 *   十一、启动（含表格的移动端卡片标签）
 *   十二、候补（患者端）
 *   十三、放号验证码
 *   十四、挂号审计时间线
 *   十五、管理端：查看明文（权限与留痕）
 *   十六、管理端：候补队列 / 窗口代约 / 访问日志 / 发件箱 / 黑名单
 *   十七、适老化（大字版）
 *
 * 约定：
 *   · 业务校验以服务端和数据库为准，前端只做「有没有填」这类即时提示
 *   · 拼 HTML 时用户数据一律经过 escapeHtml()
 *   · 页面上的 onclick="xxx()" 依赖全局函数，函数名不要随意改动
 * ============================================================ */


/* ============================================================
 * 一、写死的常量
 * ============================================================ */

/* 医院信息。系统只服务一家医院，数据库里没有 hospitals 表，
 * 这些展示信息就写在这里，换医院只改这一处。 */
const HOSPITAL = {
  name: '市第一人民医院',
  level: '三级甲等',
  address: '城东区健康路 128 号',
  phone: '0571-8888 0120',
};

/* 科室图标。图标只是「怎么画」，数据库里没有这一列，
 * 按科室编号在这里取，换一套图标不用动数据库。 */
const DEPT_ICONS = {
  D01: '🫀',
  D02: '🩹',
  D03: '🧒',
  D04: '🦴',
  D05: '👁️',
};

/* 医生擅长方向。本系统没有「按擅长方向搜索」的功能，
 * 这段文字纯粹给患者看，不参与任何查询，所以库里没有这一列。 */
const DOCTOR_INTRO = {
  DR01: '高血压、冠心病、心律失常',
  DR02: '糖尿病、甲状腺疾病、内分泌失调',
  DR03: '呼吸道感染、胃肠炎、普通内科',
  DR04: '普外科手术、胆囊疾病、疝气',
  DR05: '外伤清创、体表肿物切除',
  DR06: '小儿呼吸道感染、腹泻、过敏',
  DR07: '新生儿黄疸、儿童保健、疫苗接种咨询',
  DR08: '关节置换、脊柱微创、复杂骨折',
  DR09: '骨折复位、运动损伤、腰肌劳损',
  DR10: '白内障、青光眼、眼底病变',
};

/* 上午 / 下午 各给一个大概的时间范围。
 * 号源的最小单位就是半天，具体几点看，以到院取号后的现场叫号为准。 */
const PERIOD_RANGE = { 上午: '08:00-11:00', 下午: '14:00-17:00' };

/* 星期几 */
const WEEK_LABEL = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/* 浏览器本地存储用的两个 key */
const SESSION_KEY = 'hosp_reg_patient';
const TOKEN_KEY = 'hosp_reg_token';


/* ============================================================
 * 二、全局变量
 * ============================================================ */

/* 科室和医生这两张表内容很少、几乎不变，
 * 页面打开时一次性拉回来放在这两个变量里，后面到处直接用，
 * 不用每次都去请求后端。 */
let departments = [];
let doctors = [];

/* 四步挂号流程的当前状态。step 取值 1~4。 */
var bookingState = { step: 1, deptId: '', doctorId: '', scheduleId: '', date: '', period: '', patient: null, apt: null };

/* 科室常见程度排序（用于 step1 列表顺序）：内科、儿科、外科、骨科、眼科 */
var DEPT_ORDER = ['D01', 'D03', 'D02', 'D04', 'D05'];

/* 科室拼音首字母（用于搜索） */
var DEPT_PINYIN = { D01: 'NK', D02: 'WK', D03: 'EK', D04: 'GK', D05: 'YK' };

/* 各医生的排班缓存，避免重复请求 */
var allSchedules = {};

/* 管理端登录令牌。登录成功后写进来，同时存一份到浏览器本地。
 * 真正的权限判断在服务端：每次请求都要带令牌，服务端查表确认。 */
let token = '';

/* 当前登录的管理员。没登录就是 null。 */
let currentUser = null;

/* 点「管理后台」被拦下来时，记一下登录成功后要去哪 */
let afterLogin = 'admin';

/* ---------- 挂号过程中选中的东西 ----------
 * 就这么几个变量记着用户选了什么，没有别的状态机。 */
let step = 1;         // 1 选科室 / 2 选医生 / 3 选时间 / 4 确认 / 5 挂号成功
let deptId = '';      // 选中的科室编号
let doctorId = '';    // 选中的医生编号
let date = '';        // 选中的日期
let period = '';      // 选中的上午 / 下午
let scheduleId = '';  // 选中的那条排班（号源就挂在它上面）

/* 第 3 步拿到的排班列表，点日期时要在里面找 */
let currentSchedules = [];

/* 我的挂号当前显示的列表（取消时按单号在这里找） */
let mineList = [];

/* ---------- 管理端 ---------- */
let adminTab = 'records';  // 当前子页签：records / schedules
let adminDept = '';        // 科室筛选
let adminDate = '';        // 日期筛选
let adminKeyword = '';     // 关键词
let adminRecords = [];     // 挂号记录列表（退号时按单号找）
let adminSchedules = [];   // 当前这一天的排班（停诊时按编号找）


/* ============================================================
 * 三、小工具（日期、金额、转义）
 * ============================================================ */

/* 取科室图标，没有就给药箱 */
function deptIcon(id) {
  if (DEPT_ICONS[id]) return DEPT_ICONS[id];
  return '🏥';
}

/* 取医生简介，没有就返回空字符串 */
function doctorIntro(id) {
  if (DOCTOR_INTRO[id]) return DOCTOR_INTRO[id];
  return '';
}

/* ---------- 按编号从缓存里找科室 / 医生 ----------
 * 找不到就返回一个兜底值，页面不至于显示空白。 */

function deptName(id) {
  for (let i = 0; i < departments.length; i++) {
    if (departments[i].id === id) return departments[i].name;
  }
  return '未知科室';
}

function doctorName(id) {
  for (let i = 0; i < doctors.length; i++) {
    if (doctors[i].id === id) return doctors[i].name;
  }
  return '未知医生';
}

function doctorTitle(id) {
  for (let i = 0; i < doctors.length; i++) {
    if (doctors[i].id === id) return doctors[i].title;
  }
  return '';
}

function doctorFee(id) {
  for (let i = 0; i < doctors.length; i++) {
    if (doctors[i].id === id) return doctors[i].fee;
  }
  return 0;
}

/* 某个科室下面有哪些医生 */
function doctorsOf(deptId) {
  const list = [];
  for (let i = 0; i < doctors.length; i++) {
    if (doctors[i].deptId === deptId) list.push(doctors[i]);
  }
  return list;
}

/* ---------- 日期 ---------- */

/* 补零：7 → "07" */
function pad2(n) {
  if (n < 10) return '0' + n;
  return '' + n;
}

/* 序号补成三位：7 → "007" */
function pad3(n) {
  let s = '' + n;
  while (s.length < 3) s = '0' + s;
  return s;
}

/* 日期对象 → "2026-10-13" */
function dateToStr(d) {
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

/* "2026-10-13" → 日期对象 */
function strToDate(s) {
  const p = String(s).slice(0, 10).split('-');
  return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
}

/* "2026-10-13" → "周二" */
function weekdayLabel(dateStr) {
  return WEEK_LABEL[strToDate(dateStr).getDay()];
}

/* 从今天起连续 days 天，给「选日期」那一排按钮用。
 * 第一天显示「今天」，第二天显示「明天」，再往后显示星期几。 */
function statusText(st) { return STATUS_TEXT[st] || st; }
function statusClass(st) {
  if (st === 'booked') return 'green';
  if (st === 'cancelled' || st === 'closed') return 'grey';
  return 'blue';
}
function daysUntil(dateStr) {
  var d = new Date(dateStr + 'T00:00:00');
  var now = new Date(); now.setHours(0,0,0,0);
  return Math.floor((d - now) / 86400000);
}
function fmtCountdown(dateStr) {
  var d = daysUntil(dateStr);
  if (d < 0) return '已过期';
  if (d === 0) return '今天就诊';
  if (d === 1) return '明天就诊';
  return '还有 ' + d + ' 天就诊';
}
function suggestArrival(period) {
  return period === '上午' ? '请于 07:30 前到院取号候诊' : '请于 13:00 前到院取号候诊';
}
function getSavedPatients() {
  try {
    var raw = localStorage.getItem('hosp_reg_patients');
    if (raw) return JSON.parse(raw);
  } catch (e) {}
  return [];
}
function savePatientToHistory(p) {
  try {
    var list = getSavedPatients();
    var cleaned = [];
    for (var i = 0; i < list.length; i++) { if (list[i].idCard !== p.idCard) cleaned.push(list[i]); }
    cleaned.unshift({ name: p.name, idCard: p.idCard, phone: p.phone, email: p.email || '' });
    if (cleaned.length > 5) cleaned.length = 5;
    localStorage.setItem('hosp_reg_patients', JSON.stringify(cleaned));
  } catch (e) {}
}

function buildDateRange(days) {
  const list = [];
  const today = new Date();
  today.setHours(0, 0, 0, 0);

  for (let i = 0; i < days; i++) {
    const d = new Date(today);
    d.setDate(today.getDate() + i);

    let label = weekdayLabel(dateToStr(d));
    if (i === 0) label = '今天';
    else if (i === 1) label = '明天';

    list.push({
      date: dateToStr(d),
      day: d.getDate(),
      month: d.getMonth() + 1,
      weekday: label,
    });
  }
  return list;
}

/* ---------- 金额与时段 ---------- */

/* 金额显示成 ¥50.00 */
function money(n) {
  return '¥' + Number(n).toFixed(2);
}
function fmtMoney(n) { return money(n); }

/* 上午 / 下午 → 大概的时间范围 */
function periodRange(period) {
  if (PERIOD_RANGE[period]) return PERIOD_RANGE[period];
  return '';
}

/* 把值塞进 HTML 时先转义，防止姓名里带 < > 把页面结构搞坏 */
function escapeHtml(s) {
  if (s == null) return '';
  let out = String(s);
  out = out.replace(/&/g, '&amp;');
  out = out.replace(/</g, '&lt;');
  out = out.replace(/>/g, '&gt;');
  out = out.replace(/"/g, '&quot;');
  out = out.replace(/'/g, '&#39;');
  return out;
}


/* ============================================================
 * 四、浏览器本地存的两样东西
 * ============================================================ */

/* 就诊人信息：只是为了下次挂号时把表单填好，不是数据源 */
function loadSession() {
  let raw = null;
  try {
    raw = localStorage.getItem(SESSION_KEY);
  } catch (e) {
    raw = null;
  }

  if (raw) {
    try {
      return JSON.parse(raw);
    } catch (e) {
      /* 存坏了就当没有 */
    }
  }
  return { name: '', idCard: '', phone: '', email: '' };
}

/* 存就诊人信息。
 * 合并而不是覆盖：候补表单只填了姓名身份证，不该把上次挂号存的邮箱清掉。 */
function saveSession(s) {
  const cur = loadSession();
  const next = {
    name: cur.name || '',
    idCard: cur.idCard || '',
    phone: cur.phone || '',
    email: cur.email || '',
  };
  for (const k in s) {
    if (s[k] !== undefined && s[k] !== null) next[k] = s[k];
  }
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify(next));
  } catch (e) {
    /* 存不进去也不影响挂号 */
  }
}


/* ============================================================
 * 五、跟后端打交道 —— 所有 fetch 都写在这一节
 * ============================================================ */

/* 统一发请求。三件事：
 *   1. 有令牌就带在请求头里（服务端靠它判断你是不是管理员）
 *   2. 把请求体转成 JSON
 *   3. 返回不是 2xx 就抛一个带中文提示的错误，页面 catch 到直接弹出来 */
async function request(method, url, body, retried) {
  const opt = { method: method, headers: {} };

  if (body) {
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  if (token) {
    opt.headers.Authorization = 'Bearer ' + token;
  }
  /* 患者凭证：一台手机可能替全家挂号，所以把本机存的都带上 */
  const ptokens = allPatientTokens();
  if (ptokens) opt.headers['X-Patient-Token'] = ptokens;

  let res;
  try {
    res = await fetch('/api' + url, opt);
  } catch (e) {
    throw new Error('连不上服务器，请确认后端已启动');
  }

  const text = await res.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (e) {
      data = null;
    }
  }

  if (!res.ok) {
    /* 光有中文提示不够用了：验证码要认 428、限流要认 429、
     * 越权要认 403，所以把状态码和 code 一起挂到 error 上。 */
    const err = new Error((data && data.error) || ('请求失败（HTTP ' + res.status + '）'));
    err.status = res.status;
    err.code = (data && data.code) || '';
    err.data = data;

    /* 患者端没带有效凭证：弹验证框，验证通过后原样重发一次 */
    if (err.code === 'PATIENT_AUTH_REQUIRED' && !retried) {
      /* 身份证号：挂号 / 候补在请求体里，查询类在 URL 参数里，都没有就用上次的 */
      const m = /[?&]idCard=([^&]+)/.exec(url);
      const idCard = (body && body.patient && body.patient.idCard)
        || (m ? decodeURIComponent(m[1]) : '') || loadSession().idCard || '';
      const name = (body && body.patient && body.patient.name) || loadSession().name || '';
      const ok = await openPatientAuth(idCard, err.message, name);
      if (ok) return request(method, url, body, true);
    }
    throw err;
  }
  /* 首次建档时服务端会直接发凭证，记到这个就诊人名下 */
  if (data && data.patientToken && body && body.patient && body.patient.idCard) {
    savePatientToken(body.patient.idCard, data.patientToken);
  }
  return data;
}

/* ---------- 患者凭证 ----------
 * 按身份证号存：{ 身份证号: 凭证 }。凭证 30 天有效，过期了服务端会再要求验证。 */
const PTOKEN_KEY = 'hosp_reg_ptokens';

function loadPatientTokens() {
  try {
    return JSON.parse(localStorage.getItem(PTOKEN_KEY) || '{}') || {};
  } catch (e) {
    return {};
  }
}

function savePatientToken(idCard, t) {
  const all = loadPatientTokens();
  all[String(idCard).trim().toUpperCase()] = t;
  try {
    localStorage.setItem(PTOKEN_KEY, JSON.stringify(all));
  } catch (e) {
    /* 存不进去就只是下次还要验证 */
  }
}

function allPatientTokens() {
  const all = loadPatientTokens();
  return Object.keys(all).map(function (k) { return all[k]; }).slice(0, 10).join(',');
}

let patientAuthResolve = null;

/* 打开实名校验框，返回 Promise：校验通过给 true，取消给 false */
function openPatientAuth(idCard, why, name) {
  return new Promise(function (resolve) {
    patientAuthResolve = resolve;
    document.getElementById('paName').value = name || '';
    document.getElementById('paIdCard').value = idCard || '';
    document.getElementById('paTip').textContent = why || '';
    document.getElementById('patientAuthMask').style.display = 'flex';
    document.getElementById(name ? 'paIdCard' : 'paName').focus();
  });
}

/* 姓名 + 身份证号实名校验（模拟公安二要素，比对逻辑在数据库函数 fn_verify_identity） */
async function submitPatientAuth() {
  const name = document.getElementById('paName').value.trim();
  const idCard = document.getElementById('paIdCard').value.trim().toUpperCase();
  const tip = document.getElementById('paTip');
  if (!name || !idCard) { tip.textContent = '请填写姓名和身份证号'; return; }
  const btn = document.getElementById('paSubmit');
  btn.disabled = true;
  try {
    const r = await request('POST', '/patient-auth/realname', { name: name, idCard: idCard }, true);
    savePatientToken(idCard, r.patientToken);
    finishPatientAuth(true);
  } catch (e) {
    tip.textContent = e.message;
  } finally {
    btn.disabled = false;
  }
}

function closePatientAuth() {
  finishPatientAuth(false);
}

function finishPatientAuth(ok) {
  document.getElementById('patientAuthMask').style.display = 'none';
  const r = patientAuthResolve;
  patientAuthResolve = null;
  if (r) r(ok);
}

/* ---------- 登录 ---------- */

async function apiLogin(username, password) {
  return request('POST', '/auth/login', { username: username, password: password });
}

async function apiLogout() {
  return request('POST', '/auth/logout');
}

/* 刷新页面时用它确认本地存的令牌还有效 */
async function apiMe() {
  return request('GET', '/auth/me');
}

/* ---------- 科室 / 医生 / 排班 ---------- */

async function apiDepartments() {
  return request('GET', '/departments');
}

async function apiDoctors() {
  return request('GET', '/doctors');
}

/* 某个科室的医生，返回值里带 remain（还剩多少号） */
async function apiDeptDoctors(deptId) {
  return request('GET', '/departments/' + encodeURIComponent(deptId) + '/doctors');
}

/* 某位医生未来几天的排班（一天两条：上午、下午） */
async function apiDoctorSchedules(doctorId, days) {
  return request('GET', '/doctors/' + encodeURIComponent(doctorId) + '/schedules?days=' + days);
}

/* 排班列表（管理端）。date / deptId 传空字符串就不筛这一项。 */
async function apiSchedules(date, deptId) {
  const q = [];
  if (date) q.push('date=' + encodeURIComponent(date));
  if (deptId) q.push('deptId=' + encodeURIComponent(deptId));

  let url = '/schedules';
  if (q.length > 0) url = url + '?' + q.join('&');
  return request('GET', url);
}

/* ---------- 挂号 ---------- */

async function apiCreateAppointment(scheduleId, patient, captchaToken, captchaAnswer) {
  var body = { scheduleId: scheduleId, patient: patient };
  if (captchaToken) {
    body.captchaToken = captchaToken;
    body.captchaAnswer = captchaAnswer;
  }
  return request('POST', '/appointments', body);
}

async function apiCaptcha() {
  return request('GET', '/captcha');
}

async function apiCancelAppointment(id) {
  return request('POST', '/appointments/' + encodeURIComponent(id) + '/cancel');
}

/* 挂号记录列表。
 * 患者端必须传 idCard（只看得到自己的）；
 * 管理端登录后可以传 keyword / deptId / date 做筛选。 */
async function apiAppointments(params) {
  const q = [];
  if (params.idCard) q.push('idCard=' + encodeURIComponent(params.idCard));
  if (params.keyword) q.push('keyword=' + encodeURIComponent(params.keyword));
  if (params.deptId) q.push('deptId=' + encodeURIComponent(params.deptId));
  if (params.date) q.push('date=' + encodeURIComponent(params.date));

  let url = '/appointments';
  if (q.length > 0) url = url + '?' + q.join('&');
  return request('GET', url);
}

/* ---------- 管理端：调号源 / 停诊 ---------- */

async function apiUpdateQuota(scheduleId, total) {
  return request('PATCH', '/schedules/' + encodeURIComponent(scheduleId) + '/quota', { total: total });
}

async function apiToggleSchedule(scheduleId) {
  return request('POST', '/schedules/' + encodeURIComponent(scheduleId) + '/toggle');
}

/* ---------- 候补（①） ---------- */

async function apiJoinWaitlist(scheduleId, patient) {
  return request('POST', '/waitlist', { scheduleId: scheduleId, patient: patient });
}

/* 某个号源现在排了多少人 —— 首页「已满 · 候补 3 人」就靠它 */
async function apiWaitlistStat(scheduleId) {
  return request('GET', '/waitlist?scheduleId=' + encodeURIComponent(scheduleId));
}

/* 患者自己的候补。all=1 表示连已过期 / 已转正的也要 */
async function apiMyWaitlist(idCard, all) {
  let url = '/waitlist?idCard=' + encodeURIComponent(idCard);
  if (all) url += '&all=1';
  return request('GET', url);
}

async function apiConfirmWaitlist(id) {
  return request('POST', '/waitlist/' + encodeURIComponent(id) + '/confirm');
}

async function apiCancelWaitlist(id) {
  return request('POST', '/waitlist/' + encodeURIComponent(id) + '/cancel');
}

async function apiNotifications(idCard) {
  return request('GET', '/notifications?idCard=' + encodeURIComponent(idCard));
}

/* ---------- 患者个人资料（② 编辑病人个人资料） ---------- */

/* 按身份证查自己的档案。身份证号脱敏返回，编辑时仍用我们存的那份真实号码。 */
async function apiPatientMine(idCard) {
  return request('GET', '/patients/mine?idCard=' + encodeURIComponent(idCard));
}

/* 修改姓名 / 手机号 / 邮箱。身份证号是身份标识，不能改。 */
async function apiUpdatePatient(idCard, body) {
  return request('PATCH', '/patients/mine?idCard=' + encodeURIComponent(idCard), body);
}

/* ---------- 管理端：审计 / 权限 / 黑名单 / 发件箱 ---------- */

async function apiAccessLog() {
  return request('GET', '/admin/access-log');
}

/* 全量候补队列（管理端） */
async function apiAdminWaitlist() {
  return request('GET', '/admin/waitlist');
}

async function apiOutbox() {
  return request('GET', '/admin/outbox');
}

async function apiNotifyScan() {
  return request('POST', '/admin/notify/scan');
}

async function apiBlacklist() {
  return request('GET', '/admin/blacklist');
}

async function apiAddBlacklist(body) {
  return request('POST', '/admin/blacklist', body);
}

async function apiRemoveBlacklist(idCard) {
  return request('DELETE', '/admin/blacklist/' + encodeURIComponent(idCard));
}

async function apiProxyBooking(scheduleId, patient, captchaToken, captchaAnswer) {
  const body = { scheduleId: scheduleId, patient: patient };
  if (captchaToken) {
    body.captchaToken = captchaToken;
    body.captchaAnswer = captchaAnswer;
  }
  return request('POST', '/admin/proxy-booking', body);
}

/* 单条挂号 + 可选明文。reveal=1 时服务端会写一条 access_log。 */
async function apiAppointment(id, reveal, reason) {
  let url = '/appointments/' + encodeURIComponent(id);
  if (reveal) {
    url += '?reveal=1&reason=' + encodeURIComponent(reason || '');
  }
  return request('GET', url);
}

async function apiAppointmentLogs(id) {
  return request('GET', '/appointments/' + encodeURIComponent(id) + '/logs');
}


/* ============================================================
 * 六、页面切换
 *
 * 四个页面在 index.html 里都写好了，这里只控制显示哪一个：
 *   page-home    首页（挂号向导）
 *   page-mine    我的挂号
 *   page-login   管理后台登录
 *   page-admin   管理后台
 * ============================================================ */

function showPage(name) {
  var pages = ['home', 'mine', 'booking', 'find', 'reminders', 'profile', 'admin', 'login'];
  for (var i = 0; i < pages.length; i++) {
    var el = document.getElementById('page-' + pages[i]);
    if (!el) continue;
    el.style.display = (pages[i] === name) ? '' : 'none';
  }

  /* 顶栏高亮当前这一项 */
  var navs = ['navHome', 'navMine', 'navBooking', 'navFind', 'navReminders', 'navProfile', 'navAdmin'];
  var navMap = { home: 'navHome', mine: 'navMine', booking: 'navBooking', find: 'navFind', reminders: 'navReminders', profile: 'navProfile', admin: 'navAdmin' };
  for (var j = 0; j < navs.length; j++) {
    var n = document.getElementById(navs[j]);
    if (n) n.className = (navMap[name] === navs[j]) ? 'on' : '';
  }

  if (name === 'mine') renderMine();
  if (name === 'reminders') renderReminders();
  if (name === 'profile') renderProfile();
  if (name === 'find') renderFind();
  window.scrollTo(0, 0);
}

function goHome() {
  showPage('home');
}

/* 点「管理后台」：没登录先去登录页 */
function goAdmin() {
  if (!currentUser) {
    afterLogin = 'admin';
    showPage('login');
    document.getElementById('lgUser').focus();
    return;
  }
  showPage('admin');
  showAdminTab(adminTab);
}


/* ============================================================
 * 七、登录 / 注销
 * ============================================================ */

async function doLogin() {
  const username = document.getElementById('lgUser').value.trim();
  const password = document.getElementById('lgPwd').value;

  if (!username || !password) {
    alert('请输入用户名和密码');
    return;
  }

  try {
    const r = await apiLogin(username, password);
    token = r.token;
    currentUser = r.user;
    localStorage.setItem(TOKEN_KEY, token);
    document.getElementById('lgPwd').value = '';
    showLoginInfo();

    if (afterLogin === 'admin') goAdmin();
    else showPage('home');
  } catch (e) {
    alert(e.message);
  }
}

async function doLogout() {
  try {
    await apiLogout();
  } catch (e) {
    /* 令牌可能已经失效了，不用管，本地清掉就行 */
  }

  token = '';
  currentUser = null;
  localStorage.removeItem(TOKEN_KEY);
  showLoginInfo();
  goHome();
}

function maskIdCard(s) {
  if (!s || s.length < 8) return s || '';
  return s.slice(0, 3) + '***********' + s.slice(-4);
}
function maskPhone(s) {
  if (!s || s.length < 7) return s || '';
  return s.slice(0, 3) + '****' + s.slice(-4);
}

/* ---------- 我的资料 ---------- */
async function renderProfile() {
  var sess = loadSession();
  if (sess && sess.idCard) {
    document.getElementById('pIdCardLook').value = sess.idCard;
    await loadProfile();
  } else {
    document.getElementById('pIdCardLook').value = '';
    document.getElementById('profileForm').style.display = 'none';
    document.getElementById('profileTip').textContent = '请输入身份证号加载资料';
  }
}
async function loadProfile() {
  var idCard = document.getElementById('pIdCardLook').value.trim();
  var tip = document.getElementById('profileTip');
  var form = document.getElementById('profileForm');
  if (!idCard) { tip.textContent = '请输入身份证号'; form.style.display = 'none'; return; }
  tip.textContent = '加载中…';
  try {
    var p = await apiPatientMine(idCard);
    document.getElementById('pNameEdit').value = p.name || '';
    document.getElementById('pIdCardEdit').value = maskIdCard(p.idCard || idCard);
    document.getElementById('pPhoneEdit').value = p.phone || '';
    document.getElementById('pEmailEdit').value = p.email || '';
    form.style.display = '';
    tip.textContent = '';
  } catch (e) {
    tip.textContent = '未找到该身份证号的就诊人记录，您可以先挂号，系统会自动创建。';
    form.style.display = 'none';
  }
}
async function saveProfile() {
  var idCard = document.getElementById('pIdCardLook').value.trim();
  var name = document.getElementById('pNameEdit').value.trim();
  var phone = document.getElementById('pPhoneEdit').value.trim();
  var email = document.getElementById('pEmailEdit').value.trim();
  var tip = document.getElementById('profileSaveTip');
  if (!idCard) { tip.textContent = '请先输入身份证号'; return; }
  if (!name) { tip.textContent = '姓名不能为空'; return; }
  if (!phone) { tip.textContent = '手机号不能为空'; return; }
  tip.textContent = '保存中…';
  try {
    await apiUpdatePatient(idCard, { name: name, phone: phone, email: email });
    saveSession({ name: name, idCard: idCard, phone: phone, email: email });
    tip.textContent = '已保存';
    setTimeout(function () { tip.textContent = ''; }, 2000);
  } catch (e) {
    tip.textContent = e.message || '保存失败';
  }
}

/* 顶栏右上角：登录了就显示是谁，什么角色，没登录就空着。
 * 角色显示出来是有用的 —— 窗口人员看到「窗口」就知道自己看不到审计日志，
 * 不用去点一个必然 403 的按钮。 */
function showLoginInfo() {
  var el = document.getElementById('loginInfo');
  var logoutBtn = document.getElementById('logoutBtn');
  if (!currentUser) {
    if (el) el.textContent = '';
    if (logoutBtn) logoutBtn.style.display = 'none';
    return;
  }
  var roleName = ROLE_LABEL[currentUser.role] || currentUser.role || '管理员';
  if (el) el.textContent = currentUser.displayName + '（' + roleName + '）';
  if (logoutBtn) logoutBtn.style.display = '';
}

/* 三个角色的中文名。和后端 users.role 的取值一一对应。 */
const ROLE_LABEL = { admin: '管理员', auditor: '审计员', desk: '窗口' };

function myRole() {
  return (currentUser && currentUser.role) || '';
}

/* 某个页签当前角色能不能看。前端隐藏只是为了少点两下，
 * 真正的拦截在服务端 require_role 里。 */
function canSee(tab) {
  const r = myRole();
  if (tab === 'access') return r === 'admin' || r === 'auditor';
  if (tab === 'blacklist') return r === 'admin' || r === 'auditor';
  if (tab === 'outbox') return r === 'admin' || r === 'auditor';
  if (tab === 'proxy') return r === 'admin' || r === 'desk';
  if (tab === 'waitlist') return true;
  return true;
}

/* 能不能改数据（加黑名单、退号、调号源、代约） */
function canWrite() {
  return myRole() === 'admin' || myRole() === 'desk';
}


/* ============================================================
 * 八、患者端：挂号向导、我的预约、找医生、就诊提醒、我的资料
 * ============================================================ */

function startBooking() {
  bookingState = { step: 1, deptId: '', doctorId: '', scheduleId: '', date: '', period: '', patient: loadSession(), apt: null };
  showPage('booking');
  renderBookingStep();
}
function startBookingWithDept(deptId, doctorId) {
  bookingState = { step: 2, deptId: deptId, doctorId: doctorId, scheduleId: '', date: '', period: '', patient: loadSession(), apt: null };
  showPage('booking');
  renderBookingStep();
}
function setProgress(step) {
  var bar = document.getElementById('bookingProgress');
  if (!bar) return;
  var steps = bar.querySelectorAll('.step');
  for (var i = 0; i < steps.length; i++) {
    var s = steps[i];
    var n = parseInt(s.getAttribute('data-step'), 10);
    s.className = 'step' + (n === step ? ' on' : n < step ? ' done' : '');
    /* 已完成的步骤可以点回去改；挂号成功后（第 4 步）就不再回退了 */
    var back = n < step && step < 4;
    s.onclick = back ? goToStep.bind(null, n) : null;
    s.title = back ? '返回修改' : '';
  }
}
function goToStep(n) {
  if (n === 1) backStep1();
  else if (n === 2) backStep2();
}
function renderBookingStep() {
  setProgress(bookingState.step);
  var body = document.getElementById('bookingBody');
  if (!body) return;
  if (bookingState.step === 1) renderStep1(body);
  else if (bookingState.step === 2) renderStep2(body);
  else if (bookingState.step === 3) renderStep3(body);
  else if (bookingState.step === 4) renderStep4(body);
}

/* ---------- Step 1 选科室 ---------- */
function renderStep1(body) {
  var html = `<div class="search-box"><input type="text" id="deptSearch" placeholder="搜索科室（如：内科 / NK）" oninput="filterDepts(this.value)" /><button class="btn" onclick="filterDepts(document.getElementById('deptSearch').value)">搜索</button></div>`;
  html += `<div class="tip">不知道挂什么科？按症状快速选择：</div>`;
  html += `<div class="actions">`;
  html += `<button class="btn small" onclick="quickDept('D01')">发烧 / 感冒 / 高血压 → 内科</button>`;
  html += `<button class="btn small" onclick="quickDept('D02')">外伤 / 术后复查 → 外科</button>`;
  html += `<button class="btn small" onclick="quickDept('D03')">儿童常见病 → 儿科</button>`;
  html += `<button class="btn small" onclick="quickDept('D04')">关节疼痛 / 骨折 → 骨科</button>`;
  html += `<button class="btn small" onclick="quickDept('D05')">视力问题 → 眼科</button>`;
  html += `</div>`;
  html += `<div id="deptList" class="cards"></div>`;
  body.innerHTML = html;
  filterDepts('');
}
function filterDepts(q) {
  var list = document.getElementById('deptList');
  if (!list) return;
  q = (q || '').toLowerCase().replace(/\s/g, '');
  var items = [];
  for (var i = 0; i < DEPT_ORDER.length; i++) {
    var d = null;
    for (var j = 0; j < departments.length; j++) { if (departments[j].id === DEPT_ORDER[i]) { d = departments[j]; break; } }
    if (!d) continue;
    var match = !q;
    if (q) {
      if (d.name.indexOf(q) >= 0) match = true;
      var py = (DEPT_PINYIN[d.id] || '').toLowerCase();
      if (py.indexOf(q) >= 0) match = true;
      if (d.desc.toLowerCase().indexOf(q) >= 0) match = true;
    }
    if (match) items.push(d);
  }
  var html = '';
  for (var i = 0; i < items.length; i++) {
    var d = items[i], docs = doctorsOf(d.id);
    html += `<div class="card" onclick="pickDept('${d.id}')">`;
    html += '<div class="card-title">' + deptIcon(d.id) + ' ' + escapeHtml(d.name) + '</div>';
    html += '<div class="tip">' + escapeHtml(d.desc) + '</div>';
    html += '<div class="tip">📍 ' + escapeHtml(d.location || '位置待定') + ' · ' + docs.length + ' 位医生</div>';
    html += '</div>';
  }
  if (items.length === 0) html = '<p class="tip">未找到匹配的科室，请换个关键词试试。</p>';
  list.innerHTML = html;
}
function quickDept(deptId) { pickDept(deptId); }
function pickDept(deptId) {
  bookingState.step = 2;
  bookingState.deptId = deptId;
  bookingState.doctorId = '';
  bookingState.scheduleId = '';
  renderBookingStep();
}

/* ---------- Step 2 选医生与日期 ---------- */
async function renderStep2(body) {
  var dept = null;
  for (var i = 0; i < departments.length; i++) { if (departments[i].id === bookingState.deptId) { dept = departments[i]; break; } }
  var html = '<div class="actions"><button class="btn" onclick="backStep1()">← 返回上一步</button></div>';
  html += '<h3>' + escapeHtml(dept ? dept.name : '') + ' · ' + escapeHtml(dept ? (dept.location || '') : '') + '</h3>';
  html += '<div id="doctorList"><p class="tip">加载号源中…</p></div>';
  body.innerHTML = html;
  /* 预加载该科室所有医生的号源，这样卡片上能显示真实余号 */
  var docs = doctorsOf(bookingState.deptId);
  for (var i = 0; i < docs.length; i++) {
    if (!allSchedules[docs[i].id]) {
      try { allSchedules[docs[i].id] = await apiDoctorSchedules(docs[i].id, 14); } catch (e) { /* 忽略单条失败 */ }
    }
  }
  renderDoctorList();
}
function renderDoctorList() {
  var container = document.getElementById('doctorList');
  if (!container) return;
  var docs = doctorsOf(bookingState.deptId);
  if (docs.length === 0) { container.innerHTML = '<p class="tip">该科室暂无出诊医生。</p>'; return; }
  var html = '';
  for (var i = 0; i < docs.length; i++) {
    var d = docs[i], st = scheduleStatus(d.id);
    var badge = '<span class="badge ' + st.cls + '">' + st.text + '</span>';
    var sel = (bookingState.doctorId === d.id) ? ' style="border-color:#2563eb;background:#eef3ff"' : '';
    html += `<div class="doc-card"${sel} onclick="pickDoctor('${d.id}')">`;
    html += '<div class="avatar">' + escapeHtml(d.name.charAt(0)) + '</div>';
    html += '<div class="info">';
    html += '<div class="name">' + escapeHtml(d.name) + ' ' + escapeHtml(d.title) + ' ' + badge + '</div>';
    html += '<div class="meta">' + (DOCTOR_INTRO[d.id] || '') + ' · 挂号费 ' + fmtMoney(d.fee) + ' 元</div>';
    html += '<div class="actions">';
    if (st.remain > 0) {
      html += `<button class="btn small primary" onclick="event.stopPropagation(); pickDoctor('${d.id}')">查看号源</button>`;
    } else {
      html += `<button class="btn small" onclick="event.stopPropagation(); joinWaitlistFromBooking('${d.id}')">候补</button>`;
      html += ` <button class="btn small" onclick="event.stopPropagation(); pickDoctor('${d.id}')">查看其他时段</button>`;
    }
    html += '</div>';
    /* 号源面板嵌在医生卡片里：点日期/时段时必须拦住冒泡，
     * 否则会再触发外层的 pickDoctor()，把刚选好的 scheduleId 清空 */
    if (bookingState.doctorId === d.id) html += '<div id="schedulePanel" style="margin-top:10px" onclick="event.stopPropagation()"></div>';
    html += '</div></div>';
  }
  container.innerHTML = html;
  if (bookingState.doctorId) renderSchedulePanel();
}
function scheduleStatus(doctorId) {
  var list = allSchedules[doctorId] || [], totalRemain = 0;
  for (var i = 0; i < list.length; i++) { if (!list[i].closed) totalRemain += list[i].remain; }
  if (totalRemain > 5) return { text: '有号', cls: 'green', remain: totalRemain };
  if (totalRemain > 0) return { text: '紧张', cls: 'orange', remain: totalRemain };
  return { text: '已满', cls: 'grey', remain: 0 };
}
async function pickDoctor(doctorId) {
  bookingState.doctorId = doctorId;
  bookingState.scheduleId = '';
  if (!allSchedules[doctorId]) {
    try { allSchedules[doctorId] = await apiDoctorSchedules(doctorId, 14); }
    catch (e) { alert('加载号源失败：' + e.message); return; }
  }
  renderDoctorList();
}
function renderSchedulePanel() {
  var panel = document.getElementById('schedulePanel');
  if (!panel) return;
  var list = allSchedules[bookingState.doctorId] || [];
  var doc = null;
  for (var i = 0; i < doctors.length; i++) { if (doctors[i].id === bookingState.doctorId) { doc = doctors[i]; break; } }
  var docFee = doc ? doc.fee : 0;
  var days = buildDateRange(14);
  var html = '<div class="dates scroll">';
  for (var i = 0; i < days.length; i++) {
    var ds = days[i].date, has = false;
    for (var j = 0; j < list.length; j++) { if (list[j].date === ds && !list[j].closed && list[j].remain > 0) { has = true; break; } }
    var on = (bookingState.date === ds) ? ' on' : '';
    var off = has ? '' : ' off';
    html += `<button class="date${on}${off}" onclick="selectDate('${ds}')">${ds.slice(5)}<span>${days[i].weekday}</span></button>`;
  }
  html += '</div>';
  if (bookingState.date) {
    html += '<div class="cards" style="grid-template-columns:repeat(auto-fill,minmax(200px,1fr))">';
    for (var i = 0; i < list.length; i++) {
      var s = list[i];
      if (s.date !== bookingState.date || s.closed) continue;
      var st = s.remain > 5 ? 'green' : s.remain > 0 ? 'orange' : 'grey';
      var stText = s.remain > 5 ? '有号' : s.remain > 0 ? '紧张' : '已满';
      var on = (bookingState.scheduleId === s.id) ? ' style="border-color:#2563eb;background:#eef3ff"' : '';
      html += `<div class="card"${on} onclick="selectPeriod('${s.id}')">`;
      html += '<div class="card-title">' + escapeHtml(s.period) + ' <span class="badge ' + st + '">' + stText + '（余 ' + s.remain + '）</span></div>';
      html += '<div class="tip">诊室 ' + escapeHtml(s.room || '待定') + ' · ' + fmtMoney(docFee) + ' 元</div>';
      html += '</div>';
    }
    html += '</div>';
  }
  panel.innerHTML = html;
}
function selectDate(dateStr) {
  bookingState.date = dateStr;
  bookingState.scheduleId = '';
  renderSchedulePanel();
}
function selectPeriod(scheduleId) {
  var list = allSchedules[bookingState.doctorId] || [], s = null;
  for (var i = 0; i < list.length; i++) { if (list[i].id === scheduleId) { s = list[i]; break; } }
  if (!s || s.remain <= 0) { alert('该时段已约满，请选择其他时段或医生'); return; }
  bookingState.scheduleId = scheduleId;
  bookingState.period = s.period;
  bookingState.step = 3;
  renderBookingStep();
}
function backStep1() {
  bookingState.step = 1;
  bookingState.doctorId = '';
  bookingState.scheduleId = '';
  bookingState.date = '';
  renderBookingStep();
}

/* ---------- Step 3 确认预约 ---------- */
function renderStep3(body) {
  var dept = null, doc = null, sch = null;
  for (var i = 0; i < departments.length; i++) { if (departments[i].id === bookingState.deptId) { dept = departments[i]; break; } }
  for (var i = 0; i < doctors.length; i++) { if (doctors[i].id === bookingState.doctorId) { doc = doctors[i]; break; } }
  var list = allSchedules[bookingState.doctorId] || [];
  for (var i = 0; i < list.length; i++) { if (list[i].id === bookingState.scheduleId) { sch = list[i]; break; } }
  var saved = getSavedPatients();
  var html = '<div class="actions"><button class="btn" onclick="backStep2()">← 返回上一步</button></div>';
  html += '<h3>确认预约信息</h3>';
  html += '<div class="box">';
  html += '<p><b>就诊科室：</b>' + escapeHtml(dept ? dept.name : '') + '</p>';
  html += '<p><b>接诊医生：</b>' + escapeHtml(doc ? (doc.name + ' ' + doc.title) : '') + '</p>';
  html += '<p><b>就诊时间：</b>' + escapeHtml(sch ? (sch.date + ' ' + sch.period) : '') + '</p>';
  html += '<p><b>就诊地点：</b>' + escapeHtml(dept ? (dept.location || '') : '') + ' · ' + escapeHtml(sch ? (sch.room || '待定') : '') + '</p>';
  html += '<p><b>挂号费用：</b>' + fmtMoney(doc ? doc.fee : 0) + ' 元</p>';
  html += '</div>';
  html += '<div class="tip" style="margin:8px 0">爽约 3 次将进入黑名单，30 天内无法挂号。如需取消，请在就诊日前操作。</div>';
  html += '<h3>就诊人信息</h3>';
  if (saved.length > 0) {
    html += '<div class="patient-pick">';
    for (var i = 0; i < saved.length; i++) {
      var p = saved[i];
      var on = (bookingState.patient && bookingState.patient.idCard === p.idCard) ? ' on' : '';
      html += '<div class="patient-chip' + on + '" onclick="pickSavedPatient(' + i + ')">' + escapeHtml(p.name) + ' ' + escapeHtml(p.idCard.slice(0,6) + '****' + p.idCard.slice(-4)) + '</div>';
    }
    html += '<div class="patient-chip" onclick="newPatient()">+ 新就诊人</div>';
    html += '</div>';
  }
  html += '<div id="patientForm">';
  html += '<p><label>姓名</label><input id="bkName" type="text" placeholder="真实姓名" value="' + escapeHtml(bookingState.patient ? bookingState.patient.name : '') + '" /></p>';
  html += '<p><label>身份证号</label><input id="bkIdCard" type="text" maxlength="18" placeholder="18 位身份证号" value="' + escapeHtml(bookingState.patient ? bookingState.patient.idCard : '') + '" /></p>';
  html += '<p><label>手机号</label><input id="bkPhone" type="text" maxlength="11" placeholder="11 位手机号" value="' + escapeHtml(bookingState.patient ? bookingState.patient.phone : '') + '" /></p>';
  html += '<p><label>邮箱</label><input id="bkEmail" type="text" maxlength="120" placeholder="选填，用于就诊提醒" value="' + escapeHtml(bookingState.patient ? (bookingState.patient.email || '') : '') + '" /></p>';
  html += '</div>';
  /* 错误直接写在按钮上方：alert 被浏览器屏蔽时，用户会以为「点了没反应」 */
  html += '<p class="form-error" id="bkError" role="alert"></p>';
  html += '<div class="actions">';
  html += '<button class="btn primary" id="bkSubmit" onclick="submitBooking()">确认预约</button>';
  html += '</div>';
  body.innerHTML = html;
}
function pickSavedPatient(idx) {
  var saved = getSavedPatients();
  if (idx >= 0 && idx < saved.length) {
    bookingState.patient = saved[idx];
    renderStep3(document.getElementById('bookingBody'));
  }
}
function newPatient() {
  bookingState.patient = null;
  renderStep3(document.getElementById('bookingBody'));
}
function backStep2() {
  bookingState.step = 2;
  bookingState.scheduleId = '';
  renderBookingStep();
}
/* captcha 由验证码框算完后传进来：{ token, answer }；第一次点按钮时为空 */
async function submitBooking(captcha) {
  var name = document.getElementById('bkName').value.trim();
  var idCard = document.getElementById('bkIdCard').value.trim().toUpperCase();
  var phone = document.getElementById('bkPhone').value.trim();
  var email = document.getElementById('bkEmail').value.trim();
  var errEl = document.getElementById('bkError');
  if (errEl) errEl.textContent = '';
  if (!name || !idCard || !phone) { if (errEl) errEl.textContent = '请填写姓名、身份证号和手机号'; return; }
  if (!bookingState.scheduleId) { alert('就诊时段已失效，请重新选择'); backStep2(); return; }
  var btn = document.getElementById('bkSubmit');
  if (btn) { btn.disabled = true; btn.textContent = '预约中…'; }
  try {
    var patient = { name: name, idCard: idCard, phone: phone, email: email };
    var apt = await apiCreateAppointment(bookingState.scheduleId, patient, captcha ? captcha.token : '', captcha ? captcha.answer : '');
    saveSession({ name: name, idCard: idCard, phone: phone, email: email });
    savePatientToHistory({ name: name, idCard: idCard, phone: phone, email: email });
    bookingState.step = 4;
    bookingState.patient = { name: name, idCard: idCard, phone: phone, email: email };
    bookingState.apt = apt;
    renderBookingStep();
    if (apt.notice) alert(apt.notice);
  } catch (err) {
    if (btn) { btn.disabled = false; btn.textContent = '确认预约'; }
    if (err.code === 'CAPTCHA_REQUIRED') {
      if (captcha) alert('验证码不正确，请重新计算');
      document.getElementById('captchaWhy').textContent = '该时段仅剩 ' + (err.data && err.data.remain || '少量') + ' 个号，需要验证一下不是脚本在抢号。';
      var c = await openCaptcha();
      if (c) submitBooking(c);
      return;
    }
    var msg = err.message || '预约失败';
    if (msg.indexOf('号源已挂完') >= 0 || msg.indexOf('超卖') >= 0 || msg.indexOf('已预约该时段') >= 0) {
      msg = '这个号刚被约走了。为您保留已选条件，请换个时段或医生再试。';
      alert(msg); backStep2(); return;
    }
    if (errEl) errEl.textContent = msg;
    else alert(msg);
  }
}

/* ---------- Step 4 成功页 ---------- */
function renderStep4(body) {
  var apt = bookingState.apt || {};
  var dept = null, doc = null;
  for (var i = 0; i < departments.length; i++) { if (departments[i].id === bookingState.deptId) { dept = departments[i]; break; } }
  for (var i = 0; i < doctors.length; i++) { if (doctors[i].id === bookingState.doctorId) { doc = doctors[i]; break; } }
  var html = '<div class="success-box">';
  html += '<div class="big-check">✅</div>';
  html += '<h2>预约成功</h2>';
  html += '<div class="detail">';
  html += '<p><b>就诊时间：</b>' + escapeHtml(apt.date || '') + ' ' + escapeHtml(apt.period || '') + '</p>';
  html += '<p><b>就诊地点：</b>' + escapeHtml(dept ? (dept.location || '') : '') + ' · ' + escapeHtml(apt.room || '诊室待定') + '</p>';
  html += '<p><b>建议到院时间：</b>' + suggestArrival(apt.period) + '</p>';
  html += '<p><b>就诊人：</b>' + escapeHtml(bookingState.patient ? bookingState.patient.name : '') + '</p>';
  html += '<p><b>挂号费用：</b>' + fmtMoney(apt.fee || 0) + ' 元</p>';
  html += '<p><b>挂号单号：</b>' + escapeHtml(apt.id || '') + ' · 序号 ' + (apt.seqNo || '-') + '</p>';
  html += '</div>';
  html += '<div class="actions">';
  html += '<button class="btn" onclick="addToCalendar()">📅 添加到日历</button>';
  html += '<button class="btn" onclick="viewRoute()">🗺️ 查看路线</button>';
  html += '<button class="btn" onclick="cancelJustBooked()">取消预约</button>';
  html += '<button class="btn primary" onclick="startBooking()">继续挂号</button>';
  html += '</div>';
  html += '<p class="tip">请携带身份证原件、医保卡（如有）、既往病历资料。</p>';
  html += '</div>';
  body.innerHTML = html;
}
function cancelJustBooked() {
  var apt = bookingState.apt;
  if (!apt || !apt.id) return;
  if (!confirm('确定取消这张挂号单？')) return;
  apiCancelAppointment(apt.id).then(function () { alert('已取消'); showPage('mine'); }).catch(function (e) { alert(e.message); });
}
function addToCalendar() {
  var apt = bookingState.apt;
  if (!apt) return;
  var text = '就诊提醒：' + (apt.deptName || '') + ' ' + (apt.doctorName || '') + '，请于 ' + suggestArrival(apt.period) + ' 到院。地点：' + (apt.location || '') + ' ' + (apt.room || '') + '。';
  alert('已复制到剪贴板（模拟）：\\n' + text);
}
function viewRoute() {
  window.open('https://map.baidu.com/search/' + encodeURIComponent(HOSPITAL.address), '_blank');
}
function joinWaitlistFromBooking(doctorId) {
  var doc = null;
  for (var i = 0; i < doctors.length; i++) { if (doctors[i].id === doctorId) { doc = doctors[i]; break; } }
  openWaitlistForm(bookingState.deptId, doctorId, doc ? doc.name : '');
}

/* ---------- 我的预约（分组） ---------- */
function switchMineTab(tab) {
  var tabs = document.querySelectorAll('#mineTabs .btn');
  for (var i = 0; i < tabs.length; i++) {
    tabs[i].className = 'btn' + (tabs[i].getAttribute('data-tab') === tab ? ' on' : '');
  }
  renderMineList(tab);
}
async function renderMine() {
  switchMineTab('upcoming');
}
async function renderMineList(tab) {
  var listEl = document.getElementById('mineList');
  var tip = document.getElementById('mineTip');
  if (!listEl) return;
  var sess = loadSession();
  if (!sess || !sess.idCard) {
    listEl.innerHTML = '<p class="tip">请先填写就诊人身份证号以查看预约记录。</p>';
    if (tip) tip.textContent = '';
    return;
  }
  listEl.innerHTML = '<p class="tip">加载中…</p>';
  try {
    var statusMap = { upcoming: 'booked', completed: 'completed', cancelled: 'cancelled' };
    var list = await apiAppointments({ idCard: sess.idCard, status: statusMap[tab] || 'all', limit: 200 });
    if (tip) tip.textContent = '共 ' + list.length + ' 条';
    if (list.length === 0) { listEl.innerHTML = '<p class="tip">暂无记录。</p>'; return; }
    var html = '';
    for (var i = 0; i < list.length; i++) html += renderApptCard(list[i], tab);
    listEl.innerHTML = html;
  } catch (e) {
    listEl.innerHTML = '<p class="tip">加载失败：' + escapeHtml(e.message) + '</p>';
    if (tip) tip.textContent = '';
  }
}
function renderApptCard(a, tab) {
  var st = statusText(a.status);
  var cls = statusClass(a.status);
  var html = '<div class="appt-card">';
  html += '<div class="header"><span class="title">' + escapeHtml(a.deptName || deptName(a.deptId)) + ' · ' + escapeHtml(a.doctorName || doctorName(a.doctorId)) + '</span><span class="badge ' + cls + '">' + st + '</span></div>';
  html += '<div class="meta">' + escapeHtml(a.date || '') + ' ' + escapeHtml(a.period || '') + ' · 序号 ' + (a.seqNo || '-') + ' · 费用 ' + fmtMoney(a.fee || 0) + ' 元</div>';
  if (a.status === 'booked') {
    html += '<div class="meta" style="color:#2563eb">' + fmtCountdown(a.date) + '</div>';
    html += '<div class="actions">';
    html += `<button class="btn small" onclick="cancelAppt('${a.id}')">取消预约</button>`;
    html += ` <button class="btn small primary" onclick="rescheduleAppt('${a.id}','${a.deptId}')">改约</button>`;
    html += '</div>';
  }
  html += '</div>';
  return html;
}
function cancelAppt(aptId) {
  if (!confirm('确定取消这张挂号单？')) return;
  apiCancelAppointment(aptId).then(function () { alert('已取消'); renderMine(); }).catch(function (e) { alert(e.message); });
}
function rescheduleAppt(aptId, deptId) {
  if (!confirm('改约将先取消当前预约，并保留科室选择。确定吗？')) return;
  apiCancelAppointment(aptId).then(function () {
    bookingState = { step: 2, deptId: deptId, doctorId: '', scheduleId: '', date: '', period: '', patient: loadSession(), apt: null };
    showPage('booking'); renderBookingStep();
  }).catch(function (e) { alert(e.message); });
}

/* ---------- 找医生 ---------- */
async function renderFind() {
  var list = document.getElementById('findList');
  var kw = document.getElementById('findKeyword').value.trim().toLowerCase();
  if (!list) return;
  var html = '';
  for (var i = 0; i < departments.length; i++) {
    var d = departments[i], docs = doctorsOf(d.id);
    if (kw) {
      var has = d.name.indexOf(kw) >= 0 || d.desc.toLowerCase().indexOf(kw) >= 0;
      for (var j = 0; j < docs.length; j++) { if (docs[j].name.indexOf(kw) >= 0) has = true; }
      if (!has) continue;
    }
    html += '<h3>' + deptIcon(d.id) + ' ' + escapeHtml(d.name) + '</h3>';
    html += '<div class="cards">';
    for (var j = 0; j < docs.length; j++) {
      var doc = docs[j], st = scheduleStatus(doc.id);
      html += '<div class="card">';
      html += '<div class="card-title">' + escapeHtml(doc.name) + ' ' + escapeHtml(doc.title) + ' <span class="badge ' + st.cls + '">' + st.text + '</span></div>';
      html += '<div class="tip">' + (DOCTOR_INTRO[doc.id] || '') + ' · 挂号费 ' + fmtMoney(doc.fee) + ' 元</div>';
      html += `<div class="actions"><button class="btn small primary" onclick="startBookingWithDept('${d.id}','${doc.id}')">立即预约</button></div>`;
      html += '</div>';
    }
    html += '</div>';
  }
  if (!html) html = '<p class="tip">未找到匹配的医生或科室。</p>';
  list.innerHTML = html;
}

/* ---------- 就诊提醒 ---------- */
async function renderReminders() {
  var list = document.getElementById('reminderList');
  var tip = document.getElementById('reminderTip');
  if (!list) return;
  var sess = loadSession();
  if (!sess || !sess.idCard) {
    list.innerHTML = '<p class="tip">请先填写就诊人身份证号以查看提醒。</p>';
    if (tip) tip.textContent = '';
    return;
  }
  list.innerHTML = '<p class="tip">加载中…</p>';
  try {
    var arr = await apiNotifications(sess.idCard);
    if (tip) tip.textContent = '共 ' + arr.length + ' 条';
    if (arr.length === 0) { list.innerHTML = '<p class="tip">暂无提醒。</p>'; return; }
    var html = '';
    for (var i = 0; i < arr.length; i++) {
      var n = arr[i];
      html += '<div class="appt-card">';
      html += '<div class="header"><span class="title">' + escapeHtml(n.template || '提醒') + '</span><span class="tip">' + fmtTime(n.scheduledAt) + '</span></div>';
      html += '<div class="meta">' + escapeHtml(n.message || '') + '</div>';
      html += '</div>';
    }
    list.innerHTML = html;
  } catch (e) {
    list.innerHTML = '<p class="tip">加载失败：' + escapeHtml(e.message) + '</p>';
    if (tip) tip.textContent = '';
  }
}

/* ---------- 我的资料补充 ---------- */
function clearLocalPatient() {
  if (!confirm('确定清除本机保存的就诊人信息？')) return;
  try { localStorage.removeItem(SESSION_KEY); } catch (e) {}
  try { localStorage.removeItem('hosp_reg_patients'); } catch (e) {}
  bookingState.patient = null;
  var el = document.getElementById('pIdCardLook');
  if (el) el.value = '';
  var pf = document.getElementById('profileForm');
  if (pf) pf.style.display = 'none';
  var pt = document.getElementById('profileTip');
  if (pt) pt.textContent = '已清除本机就诊人记录';
}

/* ============================================================
 * 九、管理端：页签与挂号记录
 *
 * 进这个页面必须先登录。前端只是「没登录就跳到登录页」，
 * 真正的拦截在服务端：就算直接去调 /api/appointments 也会拿到 401。
 * ============================================================ */

/* ---------- 切子页签 ---------- */
const ADMIN_TABS = ['records', 'schedules', 'waitlist', 'proxy', 'access', 'outbox', 'blacklist'];

/* 管理后台页签排版：每行放几个按钮，让各行数量相同。
 * 做法：先量出每个按钮「不挤」时要多宽，再从「一行放下全部」开始往下试，
 * 优先选能整除按钮总数的列数（8 个 → 8 / 4 / 2 / 1），放得下就用它；
 * 总数除不尽（比如某些角色只看到 7 个）时，退而求其次用放得下的最大列数。
 * 窗口缩放、切换页签、切换大字版时都会重新算一遍。 */
function layoutAdminTabs() {
  const bar = document.getElementById('adminTabs');
  if (!bar || bar.offsetParent === null) return;   // 页面没显示时量不出宽度

  const btns = [];
  for (let i = 0; i < bar.children.length; i++) {
    if (bar.children[i].style.display !== 'none') btns.push(bar.children[i]);
  }
  const n = btns.length;
  if (n === 0) return;

  /* 先按内容宽度排一行，量出最宽的那个按钮和总宽度 */
  bar.style.gridTemplateColumns = 'repeat(' + n + ', max-content)';
  let widest = 0;
  let total = 0;
  for (let i = 0; i < btns.length; i++) {
    const w = btns[i].getBoundingClientRect().width;
    total += w;
    if (w > widest) widest = w;
  }

  const gap = parseFloat(getComputedStyle(bar).columnGap) || 0;
  const room = bar.clientWidth;

  /* 按原本宽度一行就放得下：保持一行，不用等宽列（等宽会按最宽的按钮算，反而放不下） */
  if (total + gap * (n - 1) <= room) return;
  function fits(cols) { return (room - gap * (cols - 1)) / cols >= widest; }

  let cols = 1;
  let maxFit = 1;
  for (let c = n; c >= 1; c--) {
    if (!fits(c)) continue;
    if (maxFit === 1) maxFit = c;              // 放得下的最大列数
    if (n % c === 0 && c > 1) { cols = c; break; }
  }
  /* 能整除的只剩「每行 1 个」时（比如 7 个），先算至少要几行，
   * 再把按钮平均分到这几行：7 个、一行最多放 6 个 → 2 行 → 每行 4 个（4 + 3），
   * 而不是 6 + 1 */
  if (cols === 1 && maxFit > 1) {
    const rows = Math.ceil(n / maxFit);
    cols = Math.ceil(n / rows);
  }

  bar.style.gridTemplateColumns = 'repeat(' + cols + ', 1fr)';
}
/* 盯住页签容器自己的宽度变化（窗口缩放、出现滚动条、手机横竖屏都算），
 * 比 window 的 resize 事件可靠。宽度没变时不重排，避免排完高度变了又触发自己 */
let adminTabsWidth = 0;
if (window.ResizeObserver) {
  new ResizeObserver(function (entries) {
    const w = Math.round(entries[0].contentRect.width);
    if (w === adminTabsWidth) return;
    adminTabsWidth = w;
    layoutAdminTabs();
  }).observe(document.getElementById('adminTabs'));
} else {
  window.addEventListener('resize', layoutAdminTabs);
}

function showAdminTab(tab) {
  /* 角色不够就退回到「挂号记录」—— 前端先挡一道，服务端还会再挡 */
  if (!canSee(tab)) {
    alert('当前账号（' + (ROLE_LABEL[myRole()] || myRole()) + '）没有这个页签的权限');
    tab = 'records';
  }

  adminTab = tab;

  for (let i = 0; i < ADMIN_TABS.length; i++) {
    const t = ADMIN_TABS[i];
    const btn = document.getElementById('tab' + t.charAt(0).toUpperCase() + t.slice(1));
    const panel = document.getElementById('panel-' + t);
    if (btn) btn.className = (t === tab) ? 'btn on' : 'btn';
    if (panel) panel.style.display = (t === tab) ? '' : 'none';
  }

  /* 角色看不到的页签直接不显示按钮 */
  for (let i = 0; i < ADMIN_TABS.length; i++) {
    const t = ADMIN_TABS[i];
    const btn = document.getElementById('tab' + t.charAt(0).toUpperCase() + t.slice(1));
    if (btn) btn.style.display = canSee(t) ? '' : 'none';
  }
  layoutAdminTabs();

  const tips = {
    records: '挂号记录（含已取消、已停诊）· 患者隐私默认脱敏',
    schedules: '排班号源 · 一天两条（上午 / 下午）',
    waitlist: '候补队列 · 退号后自动补位给队首',
    proxy: '窗口代约 · 电话或到院办理的号由工作人员录入',
    access: '访问日志 · 谁因为什么看了谁的隐私',
    outbox: '通知发件箱 · 提醒与候补通知的投递状态',
    blacklist: '黑名单 · 拉黑后数据库层面直接拒绝挂号',
  };
  document.getElementById('adminTip').textContent = tips[tab] || '';

  if (tab === 'records') renderRecords();
  if (tab === 'schedules') renderSchedules();
  if (tab === 'waitlist') renderAdminWaitlist();
  if (tab === 'proxy') initProxyForm();
  if (tab === 'access') renderAccessLog();
  if (tab === 'outbox') renderOutbox();
  if (tab === 'blacklist') renderBlacklist();
}

/* ---------- 两个下拉框的选项 ----------
 * 下拉框本身写在 index.html 里，这里只负责把选项填进去。 */

/* 科室下拉框 */
function fillDeptOptions(id, selected) {
  let html = '<option value="">全部科室</option>';
  for (let i = 0; i < departments.length; i++) {
    const d = departments[i];
    html += '<option value="' + d.id + '">' + escapeHtml(d.name) + '</option>';
  }
  const sel = document.getElementById(id);
  sel.innerHTML = html;
  sel.value = selected || '';
}

/* 日期下拉框（未来 7 天） */
function fillDateOptions(id, selected) {
  const days = buildDateRange(7);
  let html = '<option value="">全部日期</option>';
  for (let i = 0; i < days.length; i++) {
    const d = days[i];
    html += '<option value="' + d.date + '">' + d.date + ' ' + d.weekday + '</option>';
  }
  const sel = document.getElementById(id);
  sel.innerHTML = html;
  sel.value = selected || '';
}

async function renderRecords() {
  const tbody = document.getElementById('recordsBody');
  const count = document.getElementById('recordsCount');

  let list = [];
  try {
    list = await apiAppointments({
      keyword: adminKeyword,
      deptId: adminDept,
      date: adminDate,
    });
  } catch (e) {
    tbody.innerHTML = '';
    count.textContent = '加载失败：' + e.message;
    return;
  }
  adminRecords = list;

  fillDeptOptions('fDept', adminDept);
  fillDateOptions('fDate', adminDate);

  /* 表格内容 */
  let rows = '';
  if (list.length === 0) {
    rows = '<tr><td colspan="8">没有符合条件的挂号记录</td></tr>';
  } else {
    for (let i = 0; i < list.length; i++) {
      const a = list[i];

      let statusCls = 'tag';
      if (a.status === 'booked') statusCls = 'tag green';

      /* ⑥ 权限控制：列表里的身份证和手机号都是脱敏的。
       * 想看明文得点「查看完整」，填理由，那一次会写进访问日志。 */
      const who = `${escapeHtml(a.patientName)}<br>
           <span class="tip">${escapeHtml(a.idCard)}</span><br>
           <span class="tip">${escapeHtml(a.phone)}</span>`;

      let op = '';
      if (a.masked) {
        op += `<button class="btn small" onclick="revealPatient('${a.id}')">查看完整</button>`;
      }
      op += `<button class="btn small" onclick="showTimeline('${a.id}')">时间线</button>`;
      if (a.status === 'booked' && canWrite()) {
        op += `<button class="btn small" onclick="adminCancel('${a.id}')">退号</button>`;
      }

      rows += `
        <tr>
          <td>${a.id}</td>
          <td>${who}</td>
          <td>${deptName(a.deptId)} · ${doctorName(a.doctorId)}</td>
          <td>${a.date} ${a.period}</td>
          <td>${pad3(a.seqNo)}</td>
          <td>${money(a.fee)}</td>
          <td><span class="${statusCls}">${statusText(a.status)}</span></td>
          <td>${op}</td>
        </tr>
      `;
    }
  }

  tbody.innerHTML = rows;
  count.textContent = '共 ' + list.length + ' 条记录'
    + '（患者隐私默认脱敏，查看完整信息需要填理由并会留痕）';
}

function doSearch() {
  adminKeyword = document.getElementById('fKeyword').value.trim();
  renderRecords();
}

function clearFilters() {
  adminDept = '';
  adminDate = '';
  adminKeyword = '';
  document.getElementById('fDept').value = '';
  document.getElementById('fDate').value = '';
  document.getElementById('fKeyword').value = '';
  renderRecords();
}

/* 状态中文名。
 * 库里是四态：booked / cancelled / completed / no_show；
 * 「已停诊」不是独立状态，是 cancelled 里 cancel_reason = closure 的那一批，
 * 后端 map_appointment 已经把它还原成 closed 了。 */
function statusText(status) {
  if (status === 'booked') return '待就诊';
  if (status === 'cancelled') return '已取消';
  if (status === 'closed') return '已停诊';
  if (status === 'completed') return '已完成';
  if (status === 'no_show') return '已爽约';
  return status;
}

/* 管理端退号 */
async function adminCancel(id) {
  let apt = null;
  for (let i = 0; i < adminRecords.length; i++) {
    if (adminRecords[i].id === id) {
      apt = adminRecords[i];
      break;
    }
  }

  let who = id;
  if (apt) who = apt.patientName;

  if (!confirm('确认为 ' + who + ' 办理退号？号源会立即释放。')) return;

  try {
    await apiCancelAppointment(id);
    alert('退号成功');
    renderRecords();
  } catch (e) {
    alert(e.message);
  }
}


/* ============================================================
 * 十、管理端：排班号源
 * ============================================================ */

async function renderSchedules() {
  const dates = document.getElementById('scheduleDates');
  const cards = document.getElementById('schedulesCards');
  const count = document.getElementById('schedulesCount');

  const days = buildDateRange(7);
  let activeDate = adminDate;
  if (!activeDate) activeDate = days[0].date;

  let all = [];
  try {
    /* 一次把未来 7 天的排班都拿回来，切换日期就不用再请求了 */
    all = await apiSchedules('', adminDept);
  } catch (e) {
    dates.innerHTML = '';
    cards.innerHTML = '';
    count.textContent = '加载失败：' + e.message;
    return;
  }

  /* 只留选中那一天的 */
  const list = [];
  for (let i = 0; i < all.length; i++) {
    if (all[i].date === activeDate) list.push(all[i]);
  }
  adminSchedules = list;

  fillDeptOptions('sDept', adminDept);

  /* 日期按钮 */
  let dateButtons = '';
  for (let i = 0; i < days.length; i++) {
    const d = days[i];

    let cls = 'date';
    if (d.date === activeDate) cls = 'date on';

    /* 这一天有几条排班 */
    let n = 0;
    for (let j = 0; j < all.length; j++) {
      if (all[j].date === d.date) n = n + 1;
    }

    dateButtons += `
      <button class="${cls}" onclick="adminDate = '${d.date}'; renderSchedules()">
        <b>${d.weekday}</b>
        <span>${d.month}/${d.day}</span>
        <span>${n} 排班</span>
      </button>
    `;
  }
  dates.innerHTML = dateButtons;

  /* 排班卡片 */
  let cardHtml = '';
  if (list.length === 0) {
    cardHtml = '<p class="tip">该日期没有排班。</p>';
  } else {
    for (let i = 0; i < list.length; i++) {
      const s = list[i];

      let stateCls = 'tag green';
      let stateText = '正常出诊';
      let toggleText = '停诊';

      if (s.closed) {
        stateCls = 'tag';
        stateText = '已停诊';
        toggleText = '恢复出诊';
      }

      cardHtml += `
        <div class="card">
          <div class="card-title">
            ${doctorName(s.doctorId)} <span class="tag">${doctorTitle(s.doctorId)}</span>
            <span class="tag">${s.period}</span>
            <span class="${stateCls}">${stateText}</span>
          </div>
          <div class="tip">${deptName(s.deptId)} · 总号源 ${s.quotaTotal} · 已约 ${s.quotaBooked} · 余 ${s.remain}</div>
          ${canWrite() ? `<div class="actions">
            <button class="btn small" onclick="changeQuota('${s.id}', ${s.quotaTotal - 1})">−</button>
            <input class="qty" type="number" min="${s.quotaBooked}" value="${s.quotaTotal}"
                   onchange="changeQuota('${s.id}', this.value)" />
            <button class="btn small" onclick="changeQuota('${s.id}', ${s.quotaTotal + 1})">＋</button>
            <button class="btn small" onclick="toggleSchedule('${s.id}')">${toggleText}</button>
          </div>` : ''}
        </div>
      `;
    }
  }
  cards.innerHTML = cardHtml;

  count.textContent = '共 ' + list.length + ' 条排班'
    + (canWrite() ? ' · 点 −/＋ 或直接改数字可以调号源总量' : ' · 当前角色只读');
}

/* 调号源总量。服务端会拒绝「比已约数还小」的值。 */
async function changeQuota(scheduleId, total) {
  try {
    await apiUpdateQuota(scheduleId, Number(total));
  } catch (e) {
    alert(e.message);
  }
  /* 成功失败都重画：失败时把输入框还原成服务端的真实值 */
  renderSchedules();
}

/* 停诊 / 恢复出诊 */
async function toggleSchedule(scheduleId) {
  let s = null;
  for (let i = 0; i < adminSchedules.length; i++) {
    if (adminSchedules[i].id === scheduleId) {
      s = adminSchedules[i];
      break;
    }
  }
  if (!s) return;

  const what = s.date + ' ' + s.period + ' ' + doctorName(s.doctorId);

  if (s.closed) {
    if (!confirm('确认恢复 ' + what + ' 的出诊？')) return;
  } else {
    let warn = '\n\n这条排班暂无有效预约。';
    if (s.quotaBooked > 0) {
      warn = '\n\n注意：这条排班已经有 ' + s.quotaBooked + ' 条有效预约，停诊后会自动为这些患者退号。';
    }
    if (!confirm('确认把 ' + what + ' 设为停诊？' + warn)) return;
  }

  try {
    const r = await apiToggleSchedule(scheduleId);

    let msg = '已恢复出诊';
    if (r.closed) {
      msg = '已停诊';
      if (r.affected) msg = '已停诊，自动退号 ' + r.affected + ' 例';
    }
    alert(msg);
  } catch (e) {
    alert(e.message);
  }
  renderSchedules();
}


/* ============================================================
 * 十一、启动
 * ============================================================ */

/* 手机上表格改成「一行一张卡片」显示（CSS 在 style.css「表格」一节）。
 * 卡片里每一项前面要有字段名，所以把表头文字抄到每个单元格的 data-label 上。
 * 用 MutationObserver 监听所有 tbody：各页面照旧用 innerHTML 填数据，
 * 填完自动补标签，渲染代码一行都不用改，以后新加表格也自动生效。 */
function labelTableCells(table) {
  const ths = table.querySelectorAll('thead th');
  const rows = table.querySelectorAll('tbody tr');
  for (let i = 0; i < rows.length; i++) {
    const cells = rows[i].children;
    for (let j = 0; j < cells.length; j++) {
      if (cells[j].hasAttribute('colspan')) continue;   // 「暂无数据」那种整行提示不加标签
      if (ths[j]) cells[j].setAttribute('data-label', ths[j].textContent.trim());
    }
  }
}

function watchDataTables() {
  const tables = document.querySelectorAll('table.data');
  for (let i = 0; i < tables.length; i++) {
    const table = tables[i];
    const body = table.querySelector('tbody');
    if (!body) continue;
    labelTableCells(table);
    new MutationObserver(function () { labelTableCells(table); })
      .observe(body, { childList: true });
  }
}

window.onload = async function () {
  watchDataTables();

  /* 0. 先把上次选的字号恢复上 —— 老年患者不希望每次进来都重按一遍 */
  try {
    applyBigFont(localStorage.getItem(BIGFONT_KEY) === '1');
  } catch (e) {
    applyBigFont(false);
  }

  /* 1. 科室和医生只拉这一次，后面都从全局变量里读 */
  try {
    departments = await apiDepartments();
    doctors = await apiDoctors();
  } catch (e) {
    alert('连不上服务器：' + e.message
      + '\n\n请确认后端已经启动（在项目目录运行 python server/app.py），然后刷新本页。');
    return;
  }

  /* 2. 本地还存着令牌的话，问一下服务端它还有效吗（无效就静默清掉） */
  const saved = localStorage.getItem(TOKEN_KEY);
  if (saved) {
    token = saved;
    try {
      const me = await apiMe();
      currentUser = me.user;
    } catch (e) {
      token = '';
      currentUser = null;
      localStorage.removeItem(TOKEN_KEY);
    }
  }
  showLoginInfo();

  /* 3. 进首页，显示挂号向导第一步 */
  goHome();
};


/* ============================================================
 * 十二、候补（① 候补与自动补位）—— 患者端
 *
 * 号满了不是死路：排进队列，有人退号就按顺序通知，
 * 号源为他保留 2 小时，超时自动顺延给下一位。
 *
 * ★ 前端在这里只做三件事：排队、确认、放弃。
 *   「谁该补位」是数据库触发器在退号那一刻决定的 ——
 *   如果放在前端，两个患者同时点「确认」就会抢到同一个号。
 * ============================================================ */

let wlScheduleId = '';   // 正在排队的那条排班
let myWlList = [];       // 我的候补（含历史）

/* 在 currentSchedules 里按编号找排班 */
function findSchedule(sid) {
  for (let i = 0; i < currentSchedules.length; i++) {
    if (currentSchedules[i].id === sid) return currentSchedules[i];
  }
  return null;
}

function openWaitlistForm(sid) {
  const s = findSchedule(sid);
  if (!s) return;

  wlScheduleId = sid;
  document.getElementById('wlWhy').textContent =
    s.date + ' ' + s.period + ' · ' + deptName(s.deptId) + ' ' +
    doctorName(s.doctorId) + ' 已约满，可以排候补。';

  const session = loadSession();
  document.getElementById('wlName').value = session.name || '';
  document.getElementById('wlIdCard').value = session.idCard || '';
  document.getElementById('wlPhone').value = session.phone || '';
  document.getElementById('wlEmail').value = session.email || '';

  document.getElementById('wlMask').style.display = 'flex';
}

function closeWaitlistForm() {
  document.getElementById('wlMask').style.display = 'none';
}

async function submitWaitlist() {
  const name = document.getElementById('wlName').value.trim();
  const idCard = document.getElementById('wlIdCard').value.trim();
  const phone = document.getElementById('wlPhone').value.trim();
  const email = document.getElementById('wlEmail').value.trim();

  if (!name || !idCard || !phone) {
    alert('请把姓名、身份证号、手机号都填上');
    return;
  }

  try {
    const r = await apiJoinWaitlist(wlScheduleId, {
      name: name, idCard: idCard, phone: phone, email: email,
    });
    saveSession({ name: name, idCard: idCard, phone: phone, email: email });
    closeWaitlistForm();
    alert(r.message + '\n\n有空位时会按顺序通知你，号源保留 2 小时。' + (r.notice ? '\n\n' + r.notice : ''));
    renderPeriods();
    showPage('waitlist');
  } catch (e) {
    alert(e.message);
  }
}

const WL_STATUS = {
  waiting: '排队中',
  offered: '已通知',
  converted: '已转正',
  expired: '已过期',
  cancelled: '已放弃',
};

async function renderMyWaitlist() {
  const tip = document.getElementById('wlTip');
  const empty = document.getElementById('wlEmpty');
  const box = document.getElementById('wlList');

  const session = loadSession();
  if (!session.idCard) {
    tip.textContent = '';
    empty.textContent = '本机还没记录就诊人信息。挂号或排候补之后，这里会显示你的候补队列。';
    empty.style.display = '';
    box.innerHTML = '';
    return;
  }

  let list = [];
  try {
    list = await apiMyWaitlist(session.idCard, true);
  } catch (e) {
    tip.textContent = '';
    empty.textContent = '加载失败：' + e.message;
    empty.style.display = '';
    box.innerHTML = '';
    return;
  }

  myWlList = list;
  const live = list.filter(function (x) {
    return x.status === 'waiting' || x.status === 'offered';
  });

  tip.textContent = '生效中的候补 ' + live.length + ' 条 · 历史 ' + (list.length - live.length) + ' 条';
  empty.style.display = list.length === 0 ? '' : 'none';
  if (list.length === 0) {
    empty.textContent = '还没有候补记录。号源约满时，在时段卡片上点「加入候补」。';
    box.innerHTML = '';
    return;
  }

  let html = '';
  for (let i = 0; i < list.length; i++) {
    const w = list[i];
    const offered = (w.status === 'offered');
    const live2 = offered || w.status === 'waiting';

    let cls = 'card';
    if (offered) cls = 'card wl-offer';

    let tagCls = 'tag';
    if (offered) tagCls = 'tag green';
    else if (w.status === 'waiting') tagCls = 'tag blue';
    else if (w.status === 'converted') tagCls = 'tag green';

    let actions = '';
    if (offered) {
      actions = `
        <button class="btn primary" onclick="confirmWl('${w.id}')">确认挂号</button>
        <button class="btn" onclick="cancelWl('${w.id}')">放弃</button>
      `;
    } else if (w.status === 'waiting') {
      actions = `<button class="btn" onclick="cancelWl('${w.id}')">放弃排队</button>`;
    }

    let extra = '';
    if (offered && w.offerExpiresAt) {
      extra = `<div class="tip">号源为你保留到 ${fmtTime(w.offerExpiresAt)}，过期自动顺延给下一位。</div>`;
    }

    html += `
      <div class="${cls}">
        <div class="card-title">
          ${w.date} ${w.weekday} ${w.period}
          <span class="${tagCls}">${WL_STATUS[w.status] || w.status}</span>
          <span class="tag">第 ${w.position} 位</span>
        </div>
        <div class="tip">${deptName(w.deptId)} · ${doctorName(w.doctorId)} ${w.doctorTitle} · ${money(w.fee)}</div>
        <div class="tip">就诊人：${escapeHtml(w.patientName)} · ${escapeHtml(w.idCard)}
          ${w.hasEmail ? ' · 已留邮箱，会收到邮件通知' : ' · 未留邮箱，只在站内通知'}</div>
        <div class="tip">候补号：${w.id}</div>
        ${extra}
        ${live2 && actions ? '<div class="actions" style="margin:8px 0 0">' + actions + '</div>' : ''}
      </div>
    `;
  }
  box.innerHTML = html;
}

async function confirmWl(id) {
  if (!confirm('确认把保留的号挂下来？')) return;
  try {
    const apt = await apiConfirmWaitlist(id);
    alert('候补转正成功，挂号单号 ' + apt.id + '，取号序号 ' + pad3(apt.seqNo) + ' 号');
    renderMyWaitlist();
  } catch (e) {
    alert(e.message);
    renderMyWaitlist();
  }
}

async function cancelWl(id) {
  if (!confirm('确认放弃这个候补？放弃后位置就没了。')) return;
  try {
    await apiCancelWaitlist(id);
    renderMyWaitlist();
  } catch (e) {
    alert(e.message);
  }
}

/* 把 ISO 时间显示成「10-29 08:30」这种本地格式 */
function fmtTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' '
    + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}


/* ============================================================
 * 十三、放号验证码（⑤ 防黄牛）
 *
 * 服务端只在「余号 ≤ 3」时才要求验证码 —— 正常挂号不弹框，
 * 只有抢手号源才要算一道题，既挡脚本又不烦人。
 * 题目和答案都在服务端，token 一次性、5 分钟过期。
 * ============================================================ */

let captchaToken = '';
let captchaResolve = null;   // 等用户算完的那个 Promise

/* 打开验证码框，返回 Promise：算完给 {token, answer}，取消给 null */
function openCaptcha() {
  return new Promise(function (resolve) {
    captchaResolve = resolve;
    document.getElementById('captchaAnswer').value = '';
    document.getElementById('captchaMask').style.display = 'flex';
    refreshCaptcha();
  });
}

async function refreshCaptcha() {
  try {
    const c = await apiCaptcha();
    captchaToken = c.token;
    document.getElementById('captchaQuestion').textContent = c.question;
    document.getElementById('captchaTip').textContent =
      '算错了可以点「换一题」。这道题 ' + Math.round(c.ttl / 60) + ' 分钟内有效。';
    document.getElementById('captchaAnswer').focus();
  } catch (e) {
    document.getElementById('captchaQuestion').textContent = '题目加载失败：' + e.message;
  }
}

function submitCaptcha() {
  const answer = document.getElementById('captchaAnswer').value.trim();
  if (!answer) {
    alert('请填写答案');
    return;
  }
  document.getElementById('captchaMask').style.display = 'none';
  const r = captchaResolve;
  captchaResolve = null;
  if (r) r({ token: captchaToken, answer: answer });
}

function closeCaptcha() {
  document.getElementById('captchaMask').style.display = 'none';
  const r = captchaResolve;
  captchaResolve = null;
  if (r) r(null);
}


/* ============================================================
 * 十四、挂号审计时间线（④）
 *
 * 「只知道状态是 cancelled，不知道什么时候挂的、什么时候退的」
 * 这条时间线就是答案：appointments 的 created_at / cancelled_at
 * 加 appointment_log 里每一次状态变更，全由触发器写。
 * ============================================================ */

async function showTimeline(id) {
  const body = document.getElementById('tlBody');
  const head = document.getElementById('tlHead');
  body.innerHTML = '';
  head.textContent = '加载中…';
  document.getElementById('timelineMask').style.display = 'flex';

  try {
    const r = await apiAppointmentLogs(id);
    const a = r.appointment;

    head.innerHTML = '单号 <b>' + a.id + '</b> · 就诊人 ' + escapeHtml(a.patientName)
      + ' · 当前状态 ' + statusText(a.status);

    let rows = '';
    if (r.timeline.length === 0) {
      rows = '<tr><td colspan="4">没有审计记录</td></tr>';
    } else {
      for (let i = 0; i < r.timeline.length; i++) {
        const t = r.timeline[i];
        rows += `
          <tr>
            <td>${fmtTime(t.at)}</td>
            <td>${t.action === 'insert' ? '挂号' : (t.action === 'cancel' ? '退号' : t.action)}</td>
            <td>${t.oldStatus ? statusText(t.oldStatus) + ' → ' : ''}${statusText(t.newStatus)}</td>
            <td>${escapeHtml(t.operator || '—')}</td>
          </tr>
        `;
      }
    }
    body.innerHTML = rows;
  } catch (e) {
    head.textContent = '加载失败：' + e.message;
  }
}

function closeTimeline() {
  document.getElementById('timelineMask').style.display = 'none';
}


/* ============================================================
 * 十五、管理端：查看明文（⑥ 权限控制）
 *
 * 列表里所有人看到的都是脱敏的。想看完整身份证必须：
 *   1. 有 admin / auditor 角色（desk 会被服务端 403）
 *   2. 填一个理由
 *   3. 那一次访问写进 access_log
 * ============================================================ */

async function revealPatient(id) {
  const reason = prompt('查看完整患者信息需要填写理由（至少 2 个字）：\n'
    + '例如：患者来电核对身份证 / 窗口办理退费');
  if (reason === null) return;

  if (reason.trim().length < 2) {
    alert('理由至少 2 个字');
    return;
  }

  try {
    const a = await apiAppointment(id, true, reason.trim());
    alert('完整信息：\n\n就诊人：' + a.patientName
      + '\n身份证：' + a.idCard
      + '\n手机号：' + a.phone
      + '\n\n这次查看已记入访问日志。');
  } catch (e) {
    alert(e.message);
  }
}


/* ============================================================
 * 十六、管理端：候补队列 / 窗口代约 / 访问日志 / 发件箱 / 黑名单
 * ============================================================ */

/* ---------- 候补队列 ---------- */
async function renderAdminWaitlist() {
  const body = document.getElementById('wlBody');
  const count = document.getElementById('wlCount');
  body.innerHTML = '<tr><td colspan="7">加载中…</td></tr>';

  let list = [];
  try {
    list = await apiAdminWaitlist();
  } catch (e) {
    body.innerHTML = '<tr><td colspan="7">加载失败：' + escapeHtml(e.message) + '</td></tr>';
    count.textContent = '';
    return;
  }

  if (list.length === 0) {
    body.innerHTML = '<tr><td colspan="7">当前没有排队中的候补</td></tr>';
    count.textContent = '';
    return;
  }

  let rows = '';
  for (let i = 0; i < list.length; i++) {
    const w = list[i];
    let cls = 'tag blue';
    if (w.status === 'offered') cls = 'tag green';

    rows += `
      <tr>
        <td>${w.id}</td>
        <td>${w.date} ${w.period}<br><span class="tip">${deptName(w.deptId)} · ${doctorName(w.doctorId)}</span></td>
        <td>${escapeHtml(w.patientName)}<br><span class="tip">${escapeHtml(w.idCard)}</span></td>
        <td>第 ${w.position} 位</td>
        <td><span class="${cls}">${WL_STATUS[w.status] || w.status}</span></td>
        <td>${w.offeredAt ? fmtTime(w.offeredAt) : '—'}</td>
        <td>${w.offerExpiresAt ? fmtTime(w.offerExpiresAt) : '—'}</td>
      </tr>
    `;
  }
  body.innerHTML = rows;
  count.textContent = '共 ' + list.length + ' 条生效候补（排队中 + 已通知）';
}


/* ---------- 窗口代约（③ 适老化：电话 / 线下代约） ---------- */
let proxySchedules = [];

function initProxyForm() {
  /* 科室下拉框 */
  let html = '<option value="">请选择科室</option>';
  for (let i = 0; i < departments.length; i++) {
    html += '<option value="' + departments[i].id + '">' + escapeHtml(departments[i].name) + '</option>';
  }
  const sel = document.getElementById('pxDept');
  sel.innerHTML = html;
  document.getElementById('pxSchedule').innerHTML = '<option value="">请先选科室</option>';
  document.getElementById('pxRemain').textContent = '';
  document.getElementById('proxyTip').textContent = '';
}

async function proxyDeptChange() {
  const did = document.getElementById('pxDept').value;
  const sel = document.getElementById('pxSchedule');
  const remain = document.getElementById('pxRemain');

  if (!did) {
    sel.innerHTML = '<option value="">请先选科室</option>';
    remain.textContent = '';
    return;
  }

  sel.innerHTML = '<option value="">加载中…</option>';
  try {
    proxySchedules = await apiSchedules('', did);
  } catch (e) {
    sel.innerHTML = '<option value="">加载失败：' + escapeHtml(e.message) + '</option>';
    return;
  }

  /* 只列未来 7 天、没停诊、还有号的 */
  const days = buildDateRange(7);
  const keep = {};
  for (let i = 0; i < days.length; i++) keep[days[i].date] = true;

  let opts = '<option value="">请选择时段</option>';
  let n = 0;
  for (let i = 0; i < proxySchedules.length; i++) {
    const s = proxySchedules[i];
    if (!keep[s.date] || s.closed || s.remain <= 0) continue;
    opts += '<option value="' + s.id + '">'
      + s.date + ' ' + s.period + ' · ' + doctorName(s.doctorId)
      + '（余 ' + s.remain + '）</option>';
    n = n + 1;
  }
  if (n === 0) opts = '<option value="">该科室未来 7 天没有可约号源</option>';
  sel.innerHTML = opts;
  remain.textContent = n > 0 ? '可选时段 ' + n + ' 个' : '';
}

async function submitProxy() {
  const sid = document.getElementById('pxSchedule').value;
  const name = document.getElementById('pxName').value.trim();
  const idCard = document.getElementById('pxIdCard').value.trim();
  const phone = document.getElementById('pxPhone').value.trim();
  const email = document.getElementById('pxEmail').value.trim();
  const tip = document.getElementById('proxyTip');

  if (!sid) { alert('请先选一个时段'); return; }
  if (!name || !idCard || !phone) { alert('请把姓名、身份证号、手机号都填上'); return; }

  const done = await bookWithCaptcha(sid, {
    name: name, idCard: idCard, phone: phone, email: email,
  }, 'proxy');

  if (!done.ok) {
    if (!done.cancelled) alert(done.message);
    return;
  }

  tip.textContent = '已代约：' + done.apt.id + '（取号序号 ' + pad3(done.apt.seqNo)
    + ' 号）· 审计日志已记成「代约:工号」';
  document.getElementById('pxName').value = '';
  document.getElementById('pxIdCard').value = '';
  document.getElementById('pxPhone').value = '';
  document.getElementById('pxEmail').value = '';
  proxyDeptChange();
}

/* 代约走 /api/admin/proxy-booking（审计记「代约:工号」），
 * 封装在 apiProxyBooking 里，由 bookWithCaptcha 的 mode='proxy' 选路。 */


/* ---------- 访问日志 ---------- */
const ACTION_LABEL = {
  reveal_idcard: '查看完整身份证',
  view_patient: '查看患者档案',
  export_records: '导出记录',
  view_audit: '查看审计时间线',
  blacklist: '加入黑名单',
};

async function renderAccessLog() {
  const body = document.getElementById('accessBody');
  const count = document.getElementById('accessCount');
  body.innerHTML = '<tr><td colspan="6">加载中…</td></tr>';

  let list = [];
  try {
    list = await apiAccessLog();
  } catch (e) {
    body.innerHTML = '<tr><td colspan="6">加载失败：' + escapeHtml(e.message) + '</td></tr>';
    count.textContent = '';
    return;
  }

  if (list.length === 0) {
    body.innerHTML = '<tr><td colspan="6">还没有敏感操作记录</td></tr>';
    count.textContent = '';
    return;
  }

  let rows = '';
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    rows += `
      <tr>
        <td>${fmtTime(a.at)}</td>
        <td>${escapeHtml(a.username)}</td>
        <td>${ACTION_LABEL[a.action] || a.action}</td>
        <td>${escapeHtml(a.patientName || '—')}<br>
            <span class="tip">${escapeHtml(a.targetType)} ${escapeHtml(a.targetId)}</span></td>
        <td>${escapeHtml(a.reason || '—')}</td>
        <td><span class="tip">${escapeHtml(a.ip || '—')}</span></td>
      </tr>
    `;
  }
  body.innerHTML = rows;
  count.textContent = '最近 ' + list.length + ' 条敏感操作';
}


/* ---------- 通知发件箱 ---------- */
const TEMPLATE_LABEL = {
  waitlist_offer: '候补有空位',
  waitlist_expired: '候补保留过期',
  reminder_t1: '就诊前一天提醒',
  reminder_t0: '就诊当天提醒',
  booking_done: '挂号成功通知',
};

async function renderOutbox() {
  const body = document.getElementById('outboxBody');
  const count = document.getElementById('outboxCount');
  body.innerHTML = '<tr><td colspan="8">加载中…</td></tr>';

  let list = [];
  try {
    list = await apiOutbox();
  } catch (e) {
    body.innerHTML = '<tr><td colspan="8">加载失败：' + escapeHtml(e.message) + '</td></tr>';
    count.textContent = '';
    return;
  }

  if (list.length === 0) {
    body.innerHTML = '<tr><td colspan="8">发件箱是空的</td></tr>';
    count.textContent = '';
    return;
  }

  let rows = '';
  for (let i = 0; i < list.length; i++) {
    const o = list[i];
    let cls = 'tag';
    if (o.status === 'sent') cls = 'tag green';
    else if (o.status === 'failed') cls = 'tag warn';

    rows += `
      <tr>
        <td>${o.id}</td>
        <td>${o.channel === 'email' ? '邮件' : '站内'}</td>
        <td>${TEMPLATE_LABEL[o.template] || o.template}</td>
        <td><span class="tip">${escapeHtml(o.recipient)}</span></td>
        <td><span class="${cls}">${o.status}</span></td>
        <td>${o.attempts}</td>
        <td>${fmtTime(o.scheduledAt)}</td>
        <td><span class="tip">${escapeHtml(o.lastError || (o.sentAt ? '已发出' : ''))}</span></td>
      </tr>
    `;
  }
  body.innerHTML = rows;
  count.textContent = '最近 ' + list.length + ' 条通知（站内信躺在表里就算已送达，只有邮件需要真的投递）';
}

async function triggerScan() {
  const tip = document.getElementById('scanTip');
  tip.textContent = '正在扫描…';
  try {
    const r = await apiNotifyScan();
    const n = Object.keys(r.remind).reduce(function (s, k) { return s + r.remind[k]; }, 0);
    tip.textContent = '新增提醒 ' + n + ' 条 · 候补过期 ' + r.expired
      + ' 条（顺延 ' + r.reoffered + '）· 发出 ' + r.mail.sent + ' 封（失败 ' + r.mail.failed + '）'
      + (r.mail.dry_run ? ' · 当前是 dry-run，邮件写在本机日志里' : '');
    renderOutbox();
  } catch (e) {
    tip.textContent = '失败：' + e.message;
  }
}


/* ---------- 黑名单 ---------- */
async function renderBlacklist() {
  const body = document.getElementById('blBody');
  const count = document.getElementById('blCount');
  body.innerHTML = '<tr><td colspan="6">加载中…</td></tr>';

  let list = [];
  try {
    list = await apiBlacklist();
  } catch (e) {
    body.innerHTML = '<tr><td colspan="6">加载失败：' + escapeHtml(e.message) + '</td></tr>';
    count.textContent = '';
    return;
  }

  if (list.length === 0) {
    body.innerHTML = '<tr><td colspan="6">黑名单是空的</td></tr>';
    count.textContent = '';
    return;
  }

  let rows = '';
  for (let i = 0; i < list.length; i++) {
    const b = list[i];
    const canDel = myRole() === 'admin';
    rows += `
      <tr>
        <td><span class="tip">${escapeHtml(b.idCard)}</span></td>
        <td>${escapeHtml(b.patientName || '—')}</td>
        <td>${escapeHtml(b.reason)}</td>
        <td>${b.until ? fmtTime(b.until) : '永久'}</td>
        <td>${escapeHtml(b.createdBy || '—')}</td>
        <td>${canDel
          ? '<button class="btn small" onclick="removeBlacklist(\'' + b.idCard + '\')">解除</button>'
          : '—'}</td>
      </tr>
    `;
  }
  body.innerHTML = rows;
  count.textContent = '共 ' + list.length + ' 条';
}

async function addBlacklist() {
  const idCard = document.getElementById('blIdCard').value.trim();
  const reason = document.getElementById('blReason').value.trim();
  const until = document.getElementById('blUntil').value;

  if (!idCard) { alert('请填身份证号'); return; }
  if (reason.length < 2) { alert('请填拉黑理由（至少 2 个字）'); return; }

  try {
    await apiAddBlacklist({
      idCard: idCard,
      reason: reason,
      until: until ? until + 'T23:59:59+08:00' : null,
    });
    document.getElementById('blIdCard').value = '';
    document.getElementById('blReason').value = '';
    document.getElementById('blUntil').value = '';
    renderBlacklist();
  } catch (e) {
    alert(e.message);
  }
}

async function removeBlacklist(idCard) {
  if (!confirm('确认解除这条黑名单？')) return;
  try {
    await apiRemoveBlacklist(idCard);
    renderBlacklist();
  } catch (e) {
    alert(e.message);
  }
}


/* ============================================================
 * 十七、适老化
 *
 * 三件事，成本都不高但真的有人需要：
 *   1. 大字版 —— 一键把全站字号放大一档，记在 localStorage
 *   2. 语音挂号 —— 说一句「我想看内科」就跳到那个科室
 *   3. 电话 / 线下代约 —— 见管理端的「窗口代约」
 * ============================================================ */

const BIGFONT_KEY = 'hosp_reg_bigfont';

function applyBigFont(on) {
  if (on) document.body.classList.add('big');
  else document.body.classList.remove('big');

  const btn = document.getElementById('fontToggle');
  if (btn) {
    btn.textContent = on ? '标准字号' : '大字版';
    btn.className = on ? 'btn small on' : 'btn small';
  }
  /* 字号变了按钮宽度跟着变，后台页签要重新排 */
  layoutAdminTabs();
}

function toggleBigFont() {
  const on = !document.body.classList.contains('big');
  applyBigFont(on);
  try {
    localStorage.setItem(BIGFONT_KEY, on ? '1' : '0');
  } catch (e) {
    /* 存不了就只对本次有效 */
  }
}
