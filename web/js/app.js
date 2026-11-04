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
 *   八、患者端：挂号向导（含搜医生）、我的预约、就诊提醒、我的资料
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
/* 线条图标（24×24，描边随文字颜色）。替代原来的 emoji：emoji 各平台画风不一，彩色也显得杂乱 */
const ICONS = {
  logo: '<rect x="3.5" y="3.5" width="17" height="17" rx="5"/><path d="M12 8v8M8 12h8"/>',
  heart: '<path d="M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.2a4.3 4.3 0 0 1 7.5 2.6C19.5 15.4 12 20 12 20z"/><path d="M6.5 12.5h3l1.3-2.3 1.9 4.4 1.3-2.1h3.5"/>',
  bandage: '<rect x="2.6" y="8.4" width="18.8" height="7.2" rx="3.6" transform="rotate(-45 12 12)"/><path d="M10.6 10.6h.01M13.4 13.4h.01M10.6 13.4h.01M13.4 10.6h.01"/>',
  child: '<circle cx="12" cy="8" r="4"/><path d="M5.5 20.5c.5-3.8 3.1-6.2 6.5-6.2s6 2.4 6.5 6.2"/><path d="M10.5 8.3h.01M13.5 8.3h.01"/>',
  bone: '<path d="M17 10c.7-.7 1.7 0 2.5 0a2.5 2.5 0 1 0 0-5 .5.5 0 0 1-.5-.5 2.5 2.5 0 1 0-5 0c0 .8.7 1.8 0 2.5l-7 7c-.7.7-1.7 0-2.5 0a2.5 2.5 0 0 0 0 5c.3 0 .5.2.5.5a2.5 2.5 0 1 0 5 0c0-.8-.7-1.8 0-2.5z"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  female: '<circle cx="12" cy="9" r="5"/><path d="M12 14v7M9 18h6"/>',
  male: '<circle cx="10" cy="14" r="5"/><path d="M13.6 10.4 19.5 4.5M15 4.5h4.5V9"/>',
  drop: '<path d="M12 3.5s-6 6.6-6 10.6a6 6 0 0 0 12 0c0-4-6-10.6-6-10.6z"/><path d="M9.4 14.6a2.6 2.6 0 0 0 2.6 2.6"/>',
  ear: '<path d="M7 9.5a5 5 0 0 1 10 0c0 3-2.4 4-3 6.5-.5 2-1.8 3.5-3.7 3.5A3.3 3.3 0 0 1 7 16.2"/><path d="M10 10a2 2 0 0 1 4 0c0 1.5-1.6 2-1.6 3.6"/>',
  tooth: '<path d="M7.5 3.5c-2.7 0-4.2 2.1-3.7 5 .4 2.4 1.3 3.5 1.8 6.1.6 3 1.2 5.9 2.7 5.9s1.7-4 3.7-4 2.2 4 3.7 4 2.1-2.9 2.7-5.9c.5-2.6 1.4-3.7 1.8-6.1.5-2.9-1-5-3.7-5-1.9 0-2.8 1-4.5 1s-2.6-1-4.5-1z"/>',
  leaf: '<path d="M5 19c0-8.5 5.2-13.5 14.5-14.5C19.5 13.8 14.5 19 5 19z"/><path d="M5 19l8.2-8.2"/>',
  brain: '<path d="M12 5.5a3 3 0 0 0-5.5-.7 3 3 0 0 0-2.3 4.6 3.2 3.2 0 0 0 .5 5.5A3 3 0 0 0 9 18.4a3 3 0 0 0 3 1.6zM12 5.5a3 3 0 0 1 5.5-.7 3 3 0 0 1 2.3 4.6 3.2 3.2 0 0 1-.5 5.5 3 3 0 0 1-4.3 3.5 3 3 0 0 1-3 1.6"/>',
  ribbon: '<path d="M12 3.5A3.5 3.5 0 0 0 8.5 7c0 2.3 2 4.8 3.5 6.8 1.5-2 3.5-4.5 3.5-6.8A3.5 3.5 0 0 0 12 3.5z"/><path d="M10.2 11.6 6 20l3-1 1.6 2.5 2.9-6M13.8 11.6 18 20l-3-1-1.6 2.5"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.4-4.4"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  idcard: '<rect x="3" y="5.5" width="18" height="13" rx="2"/><circle cx="8.5" cy="11" r="2"/><path d="M5.8 16c.5-1.5 1.5-2.2 2.7-2.2s2.2.7 2.7 2.2M14 10h4M14 13.5h3"/>',
  calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M8 3v4M16 3v4M3.5 10h17"/>',
  hourglass: '<path d="M6.5 3.5h11M6.5 20.5h11M8 3.5c0 4.5 4 5.5 4 8.5s-4 4-4 8.5M16 3.5c0 4.5-4 5.5-4 8.5s4 4 4 8.5"/>',
  alert: '<path d="M12 4 21 19.5H3z"/><path d="M12 10v4.5M12 17.2h.01"/>',
  pin: '<path d="M12 21s-6.5-6-6.5-11a6.5 6.5 0 0 1 13 0c0 5-6.5 11-6.5 11z"/><circle cx="12" cy="10" r="2.3"/>',
  phone: '<path d="M5.2 4h3.3l1.6 4-2.1 1.4a11 11 0 0 0 6.6 6.6l1.4-2.1 4 1.6v3.3a1.6 1.6 0 0 1-1.7 1.6C10.6 19.9 4.1 13.4 3.6 5.7A1.6 1.6 0 0 1 5.2 4z"/>',
  check: '<circle cx="12" cy="12" r="8.5"/><path d="m8.2 12.3 2.6 2.6 5-5.3"/>',
  list: '<rect x="4.5" y="3.5" width="15" height="17" rx="2"/><path d="M8.5 8.5h7M8.5 12h7M8.5 15.5h4"/>',
  bell: '<path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4.5 20.5c.6-4 3.7-6.5 7.5-6.5s6.9 2.5 7.5 6.5"/>',
  door: '<path d="M6 20.5v-16a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v16M3.5 20.5h17"/><path d="M14.5 12.5h.01"/>',
  lift: '<rect x="5" y="3.5" width="14" height="17" rx="1.5"/><path d="M9.5 9.5 12 7l2.5 2.5M9.5 14.5 12 17l2.5-2.5"/>',
  steth: '<path d="M6 3.5v5a4 4 0 0 0 8 0v-5"/><path d="M10 12.5V15a4.5 4.5 0 0 0 9 0v-2"/><circle cx="19" cy="11" r="2"/>',
  arrow: '<path d="M4.5 12h14M13 6.5l5.5 5.5-5.5 5.5"/>',
  sign: '<path d="M12 3v18M6 6.5h11l2 2-2 2H6zM18 13.5H7l-2 2 2 2h11"/>',
  route: '<circle cx="6" cy="18" r="2.2"/><circle cx="18" cy="6" r="2.2"/><path d="M8.2 18H15a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h6.8"/>',
};
function icon(name, cls) {
  return '<svg class="ic' + (cls ? ' ' + cls : '') + '" viewBox="0 0 24 24" aria-hidden="true">' + (ICONS[name] || ICONS.logo) + '</svg>';
}

const DEPT_ICONS = {
  D01: 'heart', D02: 'bandage', D03: 'child', D04: 'bone', D05: 'eye', D06: 'female', D07: 'drop',
  D08: 'ear', D09: 'tooth', D10: 'leaf', D11: 'brain', D12: 'ribbon', D13: 'male',
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
  DR11: '妇科肿瘤、月经失调、高危妊娠',
  DR12: '妇科炎症、孕期保健、产后复查',
  DR13: '湿疹、银屑病、过敏性皮肤病',
  DR14: '痤疮、皮炎、真菌感染',
  DR15: '鼻窦炎、咽喉疾病、鼻内镜手术',
  DR16: '中耳炎、过敏性鼻炎、听力检查',
  DR17: '牙周病、口腔修复、种植牙咨询',
  DR18: '龋齿充填、根管治疗、口腔溃疡',
  DR19: '慢性胃病、失眠调理、针灸推拿',
  DR20: '体质调理、颈肩腰腿痛、中药调养',
  DR21: '抑郁、焦虑、睡眠障碍',
  DR22: '心理咨询、情绪管理、压力调适',
  DR23: '消化道肿瘤、肺癌综合治疗',
  DR24: '肿瘤筛查、化疗随访、癌痛管理',
  DR25: '前列腺炎、前列腺增生',
  DR26: '男性泌尿感染、性功能障碍',
};

/* 上午 / 下午 各给一个大概的时间范围。
 * 号源的最小单位就是半天，具体几点看，以到院取号后的现场叫号为准。 */
const PERIOD_RANGE = { 上午: '08:00-11:00', 下午: '14:00-17:00' };


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
var DEPT_ORDER = ['D01', 'D03', 'D02', 'D04', 'D05', 'D06', 'D08', 'D09', 'D07', 'D10', 'D11', 'D12', 'D13'];

/* 科室搜索：输入框停顿 250 ms 后再查，避免每敲一个字发一次请求 */
var deptSearchTimer = null;
var deptSearchSeq = 0;

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
  return icon(DEPT_ICONS[id] || 'logo');
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
    if (departments[i].id === id) return trDeptName(departments[i]);
  }
  return '';
}

function doctorName(id) {
  for (let i = 0; i < doctors.length; i++) {
    if (doctors[i].id === id) return trDoctorName(doctors[i]);
  }
  return '';
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

/* "2026-10-13" → 当前语言的星期几（周二 / Tue / 火 …） */
function weekdayLabel(dateStr) {
  try {
    return new Intl.DateTimeFormat(langTag(), { weekday: 'short' }).format(strToDate(dateStr));
  } catch (e) {
    return ['日', '一', '二', '三', '四', '五', '六'][strToDate(dateStr).getDay()];
  }
}

/* 从今天起连续 days 天，给「选日期」那一排按钮用。
 * 第一天显示「今天」，第二天显示「明天」，再往后显示星期几。 */
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
  if (d < 0) return t('cd_past');
  if (d === 0) return t('cd_today');
  if (d === 1) return t('cd_tomorrow');
  return t('cd_n', { n: d });
}
function suggestArrival(period) {
  return period === '上午' ? t('arrive_am') : t('arrive_pm');
}
/* 服务端给的诊室是「诊室 03」，换成当前语言 */
function colon() { return LANG === 'zh' ? '：' : ': '; }
function trRoom(room) {
  return room ? String(room).replace('诊室', t('room')) : t('tbd');
}
/* ---------- 就诊人信息存在哪 ----------
 * 先判断这台机器是「医院自助机」还是「个人设备」：
 *   · 自助机：工作人员在后台把本机登记为自助机（KIOSK_KEY），或服务端按 HMS_KIOSK_IPS 识别出来。
 *     信息只放内存，从不写 localStorage；挂号成功 60 秒后、或空闲 90 秒自动清除。
 *   · 个人设备：默认记住（下次挂号不用重填），本人可以取消勾选「在本机记住」——
 *     网吧、图书馆这类系统认不出来的公用电脑就靠这个勾。 */
const KIOSK_KEY = 'hosp_reg_kiosk';
let kioskByIp = false;           // 服务端 /api/client-mode 的结果，启动时取一次
function isKiosk() {
  if (kioskByIp) return true;
  try { return localStorage.getItem(KIOSK_KEY) === '1'; } catch (e) { return false; }
}
const REMEMBER_KEY = 'hosp_reg_remember';
const PATIENT_KEYS = ['hosp_reg_patient', 'hosp_reg_patients', 'hosp_reg_ptokens'];
const memStore = {
  m: {},
  getItem: function (k) { return Object.prototype.hasOwnProperty.call(this.m, k) ? this.m[k] : null; },
  setItem: function (k, v) { this.m[k] = String(v); },
  removeItem: function (k) { delete this.m[k]; },
};
function rememberOn() {
  if (isKiosk()) return false;
  try { return localStorage.getItem(REMEMBER_KEY) !== '0'; } catch (e) { return false; }   // 个人设备默认记住
}
function pstore() { return rememberOn() ? localStorage : memStore; }

/* 勾选 / 取消「在本机记住」：把当前就诊人信息在内存和 localStorage 之间搬过去 */
function setRemember(on) {
  const from = pstore();
  const data = {};
  PATIENT_KEYS.forEach(function (k) { data[k] = from.getItem(k); });
  try {
    localStorage.setItem(REMEMBER_KEY, on ? '1' : '0');
  } catch (e) { /* 存不了就只能不记住 */ }
  PATIENT_KEYS.forEach(function (k) {
    try { localStorage.removeItem(k); } catch (e) {}
    memStore.removeItem(k);
    if (data[k] !== null) pstore().setItem(k, data[k]);
  });
}
function rememberHtml() {
  if (isKiosk()) return '<p class="kiosk-note">' + icon('logo') + escapeHtml(t('kiosk_note')) + '</p>';
  return '<p class="remember-row"><label><input type="checkbox" id="rememberMe"' + (rememberOn() ? ' checked' : '')
    + ' onchange="setRemember(this.checked)" /> ' + escapeHtml(t('remember_me')) + '</label>'
    + '<span class="tip">' + escapeHtml(t('remember_tip')) + '</span></p>';
}

/* 不记住时：清掉内存里的就诊人信息，回到首页（空闲超时、点「完成」都走这里） */
let patientEpoch = 0;
function forgetPatient() {
  if (rememberOn()) return;
  patientEpoch++;
  const tokens = allPatientTokens();
  if (tokens) fetch('/api/patient-auth/logout', {
    method: 'POST', headers: { 'X-Patient-Token': tokens },
  }).catch(function () {});
  for (const id of ['wlMask', 'patientAuthMask', 'captchaMask', 'voucherMask', 'routeMask', 'timelineMask']) {
    const el = document.getElementById(id);
    if (!el) continue;
    el.style.display = 'none';
    for (const input of el.querySelectorAll('input, textarea')) input.value = '';
    for (const content of el.querySelectorAll('.detail, .appt-card, .voucher, .form-error')) content.textContent = '';
  }
  if (patientAuthResolve) { patientAuthResolve(false); patientAuthResolve = null; }
  if (captchaResolve) { captchaResolve(null); captchaResolve = null; }
  voucherApt = null;
  wlScheduleId = '';
  myWlList = [];
  captchaToken = '';
  clearInterval(kioskCountdownTimer);
  for (const id of ['voucherBody', 'timelineBody', 'routeBody', 'mineList', 'reminderList', 'profileBox', 'bookingBody']) {
    const el = document.getElementById(id);
    if (el) el.textContent = '';
  }
  PATIENT_KEYS.forEach(function (k) { memStore.removeItem(k); });
  bookingState = { step: 1, deptId: '', doctorId: '', scheduleId: '', date: '', period: '', patient: null, apt: null };
  if (currentPage !== 'admin' && currentPage !== 'login') goHome();
}

/* 空闲自动清除（只在「不记住」且内存里确实有就诊人信息时才动作）：自助机 90 秒，其他 3 分钟 */
const IDLE_MS = 3 * 60 * 1000;
const KIOSK_IDLE_MS = 90 * 1000;
let idleTimer = null;
function bumpIdle() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(function () {
    const has = PATIENT_KEYS.some(function (k) { return memStore.getItem(k) !== null; })
      || (bookingState && bookingState.step > 1);
    if (!rememberOn() && has) forgetPatient();
  }, isKiosk() ? KIOSK_IDLE_MS : IDLE_MS);
}

/* 后台：把本机登记为医院自助机 / 取消（仅管理员）。登记信息单独存，不随「清除就诊人」一起清掉 */
function renderKioskSetting() {
  const box = document.getElementById('kioskSetting');
  if (!box) return;
  if (myRole() !== 'admin') { box.innerHTML = ''; return; }
  const enrolled = (function () { try { return localStorage.getItem(KIOSK_KEY) === '1'; } catch (e) { return false; } })();
  let h = '本机模式：<b>' + (isKiosk() ? '医院自助机' : '个人设备') + '</b>';
  if (kioskByIp) h += '（按 IP 识别）';
  h += enrolled
    ? ' <button class="btn small" onclick="setKiosk(false)">取消自助机登记</button>'
    : ' <button class="btn small" onclick="setKiosk(true)">将本机设为医院自助机</button>';
  h += '<br><span class="tip">自助机上不保存任何就诊人信息，挂号成功 60 秒后或空闲 90 秒自动清除。请在每台自助机上用管理员账号登记一次。</span>';
  box.innerHTML = h;
}
function setKiosk(on) {
  if (on && !confirm('将这台电脑设为医院自助机？\n\n之后在这台电脑上挂号，病人信息都不会保存，办完自动清除。')) return;
  try {
    if (on) localStorage.setItem(KIOSK_KEY, '1');
    else localStorage.removeItem(KIOSK_KEY);
  } catch (e) { alert('浏览器禁止了本地存储，无法登记'); return; }
  if (on) PATIENT_KEYS.forEach(function (k) { try { localStorage.removeItem(k); } catch (e) {} });
  renderKioskSetting();
}
['pointerdown', 'keydown', 'scroll', 'touchstart'].forEach(function (ev) {
  window.addEventListener(ev, bumpIdle, { passive: true });
});

function getSavedPatients() {
  try {
    var raw = pstore().getItem('hosp_reg_patients');
    if (raw) return JSON.parse(raw);
  } catch (e) {}
  return [];
}
function savePatientToHistory(p) {
  try {
    var list = getSavedPatients();
    var cleaned = [];
    for (var i = 0; i < list.length; i++) { if (sessKey(list[i]) !== sessKey(p)) cleaned.push(list[i]); }
    cleaned.unshift(patientRecord(p));
    if (cleaned.length > 5) cleaned.length = 5;
    pstore().setItem('hosp_reg_patients', JSON.stringify(cleaned));
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
    if (i === 0) label = t('today');
    else if (i === 1) label = t('tomorrow');

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
    raw = pstore().getItem(SESSION_KEY);
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
  return { name: '', idType: 'CN_ID', nationality: '', idCard: '', docKey: '', phoneCc: '86', phone: '', email: '' };
}

/* 就诊人的证件键：服务端按它找档案（居民身份证就是身份证号，护照是 P:国籍:号码）。
 * 旧版本存的会话没有 docKey，退回身份证号。 */
function sessKey(s) {
  if (!s) return '';
  return s.docKey || String(s.idCard || '').trim().toUpperCase();
}

/* 存进本机的就诊人字段（会话、常用就诊人都用这一份） */
function patientRecord(p) {
  return {
    name: p.name || '', idType: p.idType || 'CN_ID', nationality: p.nationality || '',
    idCard: p.idCard || '', docKey: sessKey(p), phoneCc: p.phoneCc || '86', phone: p.phone || '', email: p.email || '', sex: p.sex || '',
  };
}

/* 存就诊人信息。
 * 合并而不是覆盖：候补表单只填了姓名身份证，不该把上次挂号存的邮箱清掉。 */
function saveSession(s) {
  const next = patientRecord(loadSession());
  for (const k in s) {
    if (s[k] !== undefined && s[k] !== null) next[k] = s[k];
  }
  next.docKey = s.docKey || (s.idCard ? docKeyOf(next.idType, next.nationality, next.idCard) : next.docKey);
  try {
    pstore().setItem(SESSION_KEY, JSON.stringify(next));
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
  const epoch = patientEpoch;
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
    throw new Error(t('e_network'));
  }

  const text = await res.text();
  if (epoch !== patientEpoch) throw new Error(t('need_patient'));
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
    const raw = (data && data.error) || ('HTTP ' + res.status);
    const err = new Error(trError(raw));
    err.raw = raw;                      /* 中文原文：按关键字判断错误类型时用它 */
    err.status = res.status;
    err.code = (data && data.code) || '';
    err.data = data;

    /* 患者端没带有效凭证：弹验证框，验证通过后原样重发一次 */
    if (err.code === 'PATIENT_AUTH_REQUIRED' && !retried) {
      /* 就诊人：挂号 / 候补在请求体里，否则用本机记住的那位 */
      const who = (body && body.patient) || loadSession();
      const ok = await openPatientAuth(who, err.message);
      if (ok) return request(method, url, body, true);
    }
    throw err;
  }
  /* 首次建档时服务端会直接发凭证，记到这个就诊人名下 */
  if (data && data.patientToken && body && body.patient) {
    savePatientToken(sessKey(body.patient), data.patientToken);
  }
  if (method !== 'GET' && /^\/(appointments|waitlist|schedules|admin\/proxy-booking)/.test(url)) {
    allSchedules = {};
  }
  return data;
}

/* ---------- 患者凭证 ----------
 * 按证件键存：{ 证件键: 凭证 }。凭证 30 天有效，过期了服务端会再要求验证。 */
const PTOKEN_KEY = 'hosp_reg_ptokens';

function loadPatientTokens() {
  try {
    return JSON.parse(pstore().getItem(PTOKEN_KEY) || '{}') || {};
  } catch (e) {
    return {};
  }
}

function savePatientToken(idCard, t) {
  const all = loadPatientTokens();
  const key = String(idCard).trim().toUpperCase();
  // 最近验证的患者优先发送；删除再加入，避免第 11 位永远被截掉。
  delete all[key];
  all[key] = t;
  try {
    pstore().setItem(PTOKEN_KEY, JSON.stringify(all));
  } catch (e) {
    /* 存不进去就只是下次还要验证 */
  }
}

function allPatientTokens() {
  const all = loadPatientTokens();
  const keys = Object.keys(all).reverse();
  const current = sessKey(loadSession());
  if (all[current]) { keys.splice(keys.indexOf(current), 1); keys.unshift(current); }
  return keys.slice(0, 10).map(function (k) { return all[k]; }).join(',');
}

let patientAuthResolve = null;

/* 打开实名校验框，返回 Promise：校验通过给 true，取消给 false。who 用来预填 */
function openPatientAuth(who, why) {
  who = who || {};
  return new Promise(function (resolve) {
    patientAuthResolve = resolve;
    document.getElementById('paName').value = who.name || '';
    document.getElementById('paDoc').innerHTML = docFieldsHtml('pa', who, false);
    document.getElementById('paTip').textContent = why || '';
    document.getElementById('patientAuthMask').style.display = 'flex';
    document.getElementById(who.name ? 'paIdCard' : 'paName').focus();
  });
}

/* 姓名 + 证件实名校验（模拟二要素，比对逻辑在数据库函数 fn_verify_identity） */
async function submitPatientAuth() {
  const tip = document.getElementById('paTip');
  const nm = readName('paName');
  if (!nm.ok) { tip.textContent = nm.msg; return; }
  const doc = readDoc('pa');
  if (!doc.ok) { tip.textContent = doc.msg; return; }
  const btn = document.getElementById('paSubmit');
  btn.disabled = true;
  try {
    const r = await request('POST', '/patient-auth/realname', {
      name: nm.name, idType: doc.idType, nationality: doc.nationality, idCard: doc.idCard,
    }, true);
    savePatientToken(doc.docKey, r.patientToken);
    /* 校验通过的就诊人记为本机当前就诊人，「我的预约」等页面直接按他查 */
    const cur = loadSession();
    if (sessKey(cur) !== doc.docKey) {
      saveSession({ name: nm.name, idType: doc.idType, nationality: doc.nationality, idCard: doc.idCard,
                    docKey: doc.docKey, phoneCc: '86', phone: '', email: '' });
    }
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

/* 按科室名 / 拼音 / 疾病 / 症状搜科室（数据库函数 fn_search_departments） */
async function apiSearchDepartments(q) {
  return request('GET', '/departments/search?q=' + encodeURIComponent(q));
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
  if (params.status) q.push('status=' + encodeURIComponent(params.status));
  if (params.limit) q.push('limit=' + encodeURIComponent(params.limit));

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

async function apiAdminPatients(keyword, idType) {
  return request('GET', '/admin/patients?keyword=' + encodeURIComponent(keyword || '')
    + '&idType=' + encodeURIComponent(idType || ''));
}

/* 病人详情；reveal=1 时服务端写一条 access_log（view_patient） */
async function apiAdminPatient(id, reveal, reason) {
  let url = '/admin/patients/' + encodeURIComponent(id);
  if (reveal) url += '?reveal=1&reason=' + encodeURIComponent(reason || '');
  return request('GET', url);
}

async function apiAdminPatientUpdate(id, body) {
  return request('PATCH', '/admin/patients/' + encodeURIComponent(id), body);
}

async function apiAdminPatientCreate(body) {
  return request('POST', '/admin/patients', body);
}

async function apiAdminPatientDelete(id, reason) {
  return request('DELETE', '/admin/patients/' + encodeURIComponent(id), { reason: reason });
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
 * 五（附）、证件与手机号表单 —— 挂号、候补、实名校验、我的资料共用
 *
 * 支持居民身份证、护照、外国人永居证、港澳 / 台湾通行证、港澳台居住证。
 * 这里的校验与服务端 validators.check_document、数据库 fn_doc_valid 同一套规则，
 * 前端先查一遍只为当场用患者的语言提示，最终以服务端和数据库为准。
 * ============================================================ */

const ID_TYPES = ['CN_ID', 'PASSPORT', 'FRP', 'HK_MO', 'TW', 'HMT_RES'];
const ID_WEIGHTS = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];

/* 身份证号里的出生日期（第 7–14 位）是否真实存在且不晚于今天 */
function birthOk(v) {
  const y = +v.slice(6, 10), m = +v.slice(10, 12), d = +v.slice(12, 14);
  const dt = new Date(y, m - 1, d);
  return y >= 1900 && dt.getFullYear() === y && dt.getMonth() === m - 1 && dt.getDate() === d && dt <= new Date();
}

function gb11643Ok(v) {
  if (!/^\d{17}[\dX]$/.test(v)) return false;
  let sum = 0;
  for (let i = 0; i < 17; i++) sum += Number(v[i]) * ID_WEIGHTS[i];
  return '10X98765432'[sum % 11] === v[17];
}

/* 证件键（与数据库 fn_doc_key 一致） */
function docKeyOf(type, nat, no) {
  no = String(no || '').toUpperCase();
  return type === 'PASSPORT' ? 'P:' + String(nat || '').toUpperCase() + ':' + no : no;
}

function needNationality(type) { return type === 'PASSPORT' || type === 'FRP'; }
/* 身份证、港澳台居住证的第 17 位就是性别（奇数男、偶数女），不用再问；其他证件要患者自己选 */
function docHasSex(type) { return type === 'CN_ID' || type === 'HMT_RES'; }
function sexOfDoc(type, no) {
  return docHasSex(type) && /^\d{17}[\dX]$/.test(no) ? (Number(no[16]) % 2 === 1 ? 'M' : 'F') : '';
}
function sexFieldHtml(prefix, type, val) {
  return '<p id="' + prefix + 'SexRow"' + (docHasSex(type) ? ' style="display:none"' : '') + '><label for="' + prefix + 'Sex">' + t('sex') + '</label>'
    + '<select id="' + prefix + 'Sex"><option value="">' + escapeHtml(t('sex_choose')) + '</option>'
    + ['M', 'F'].map(function (k) { return '<option value="' + k + '"' + (val === k ? ' selected' : '') + '>' + escapeHtml(t('sex_' + k)) + '</option>'; }).join('')
    + '</select></p>';
}
function sexLabel(sx) { return sx ? t('sex_' + sx) : '—'; }

/* 国籍下拉：按当前语言的国家名排序 */
/* 搜索关键字：当前语言名之外，再带上英文名、中文名、两位代码和区号 —— 用任何一种都能搜到 */
let enNames = null, zhNames = null;
function countryKeywords(code, cc) {
  try {
    enNames = enNames || new Intl.DisplayNames(['en'], { type: 'region' });
    zhNames = zhNames || new Intl.DisplayNames(['zh-CN'], { type: 'region' });
    return [code, enNames.of(code), zhNames.of(code), '+' + cc, cc].join(' ');
  } catch (e) {
    return code + ' +' + cc;
  }
}

function nationalityOptions(sel) {
  const list = COUNTRIES.map(function (c) { return [c[0], countryName(c[0]), c[1]]; });
  list.sort(function (a, b) { return a[1].localeCompare(b[1], langTag()); });
  let h = '<option value="">' + escapeHtml(t('choose')) + '</option>';
  list.forEach(function (c) {
    h += '<option value="' + c[0] + '" data-kw="' + escapeHtml(countryKeywords(c[0], c[2])) + '"'
       + (c[0] === sel ? ' selected' : '') + '>' + escapeHtml(c[1]) + '</option>';
  });
  return h;
}

/* 区号下拉：+86 等常用的排前面，同一个区号的国家合并显示 */
function phoneCcOptions(sel) {
  const byCc = {};
  const order = [];
  const kw = {};
  COUNTRIES.forEach(function (c) {
    if (!byCc[c[1]]) { byCc[c[1]] = []; kw[c[1]] = []; order.push(c[1]); }
    byCc[c[1]].push(countryName(c[0]));
    kw[c[1]].push(countryKeywords(c[0], c[1]));
  });
  let h = '';
  order.forEach(function (cc) {
    h += '<option value="' + cc + '" data-kw="' + escapeHtml(kw[cc].join(' ')) + '"'
       + (cc === (sel || '86') ? ' selected' : '') + '>+' + cc + ' ' + escapeHtml(byCc[cc].join(' / ')) + '</option>';
  });
  return h;
}

/* 证件三件套（类型 / 国籍 / 号码），withPhone 时再加手机号（区号 + 号码） */
function docFieldsHtml(prefix, v, withPhone) {
  v = v || {};
  const type = v.idType || 'CN_ID';
  let h = '<p><label for="' + prefix + 'IdType">' + t('id_type') + '</label><select id="' + prefix + 'IdType" onchange="onDocTypeChange(\'' + prefix + '\')">';
  ID_TYPES.forEach(function (k) {
    h += '<option value="' + k + '"' + (k === type ? ' selected' : '') + '>' + escapeHtml(t('idt_' + k)) + '</option>';
  });
  h += '</select></p>';
  h += '<p id="' + prefix + 'NatRow"' + (needNationality(type) ? '' : ' style="display:none"') + '><label for="' + prefix + 'Nat">' + t('nationality') + '</label>'
     + '<select class="searchable" id="' + prefix + 'Nat">' + nationalityOptions(v.nationality || '') + '</select></p>';
  h += '<p><label for="' + prefix + 'IdCard">' + t('id_no') + '</label><input id="' + prefix + 'IdCard" type="text" maxlength="20" autocapitalize="characters" autocomplete="off"'
     + ' placeholder="' + escapeHtml(t('ph_' + type)) + '" value="' + escapeHtml(v.idCard || '') + '" /></p>';
  if (withPhone) h += sexFieldHtml(prefix, type, v.sex || '') + phoneFieldHtml(prefix, v);
  return h;
}

function phoneFieldHtml(prefix, v) {
  v = v || {};
  const cc = v.phoneCc || '86';
  return '<p><label for="' + prefix + 'Phone">' + t('phone') + '</label><span class="phone-row">'
       + '<select class="searchable" id="' + prefix + 'PhoneCc" aria-label="' + escapeHtml(t('phone_cc')) + '" onchange="onPhoneCcChange(\'' + prefix + '\')">' + phoneCcOptions(cc) + '</select>'
       + '<input id="' + prefix + 'Phone" type="tel" maxlength="20" inputmode="tel" autocomplete="tel-national" placeholder="' + escapeHtml(t(cc === '86' ? 'phone_ph_cn' : 'phone_ph_intl')) + '" value="' + escapeHtml(v.phone || '') + '" />'
       + '</span></p>';
}

function onDocTypeChange(prefix) {
  const type = document.getElementById(prefix + 'IdType').value;
  document.getElementById(prefix + 'NatRow').style.display = needNationality(type) ? '' : 'none';
  document.getElementById(prefix + 'IdCard').placeholder = t('ph_' + type);
  const sexRow = document.getElementById(prefix + 'SexRow');
  if (sexRow) sexRow.style.display = docHasSex(type) ? 'none' : '';
}

function onPhoneCcChange(prefix) {
  const cc = document.getElementById(prefix + 'PhoneCc').value;
  document.getElementById(prefix + 'Phone').placeholder = t(cc === '86' ? 'phone_ph_cn' : 'phone_ph_intl');
}

/* 读出并校验证件：{ok, msg, idType, nationality, idCard, docKey} */
function readDoc(prefix) {
  const type = document.getElementById(prefix + 'IdType').value;
  const no = document.getElementById(prefix + 'IdCard').value.replace(/[\s-]/g, '').toUpperCase();
  let nat = needNationality(type) ? document.getElementById(prefix + 'Nat').value : '';
  let ok;
  if (type === 'CN_ID') ok = gb11643Ok(no) && birthOk(no) && !/^(81|82|83|9)/.test(no);
  else if (type === 'HMT_RES') ok = gb11643Ok(no) && /^8[123]0000/.test(no);
  else if (type === 'FRP') ok = (gb11643Ok(no) && no[0] === '9') || /^[A-Z]{3}\d{12}$/.test(no);
  else if (type === 'HK_MO') ok = /^[HM]\d{8}(\d{2})?$/.test(no);
  else if (type === 'TW') ok = /^\d{8}(\d{2})?$/.test(no);
  else ok = /^[A-Z0-9]{5,14}$/.test(no);
  if (!no || !ok) return { ok: false, msg: t('v_doc_' + type) };
  if (needNationality(type) && !nat) return { ok: false, msg: t('v_nat') };
  /* 性别：证件能读出就用证件的；读不出且表单里有性别一栏，就必须选 */
  let sex = sexOfDoc(type, no);
  const sexSel = document.getElementById(prefix + 'Sex');
  if (!sex && sexSel) {
    sex = sexSel.value;
    if (!sex) return { ok: false, msg: t('v_sex') };
  }
  return { ok: true, idType: type, nationality: nat, idCard: no, docKey: docKeyOf(type, nat, no), sex: sex };
}

/* 各国 / 地区手机号（不含区号、不含国内长途前缀 0）的格式，和后端 validators.py 的 PHONE_RULES 是同一张表；
   表里没有的区号退回到 4–11 位数字 */
const PHONE_RULES = {'1': /^(?:[2-9]\d{2}[2-9]\d{6})$/, '7': /^(?:[79]\d{9})$/, '20': /^(?:1[0125]\d{8})$/, '27': /^(?:[6-8]\d{8})$/, '30': /^(?:69\d{8})$/, '31': /^(?:6\d{8})$/, '32': /^(?:4\d{8})$/, '33': /^(?:[67]\d{8})$/, '34': /^(?:[67]\d{8})$/, '39': /^(?:3\d{8,9})$/, '41': /^(?:7[5-9]\d{7})$/, '43': /^(?:6\d{8,10})$/, '44': /^(?:7\d{9})$/, '45': /^(?:[2-9]\d{7})$/, '46': /^(?:7\d{8})$/, '47': /^(?:[49]\d{7})$/, '48': /^(?:[4-8]\d{8})$/, '49': /^(?:1[5-7]\d{8,9})$/, '51': /^(?:9\d{8})$/, '52': /^(?:\d{10})$/, '53': /^(?:5\d{7})$/, '54': /^(?:9?\d{10})$/, '55': /^(?:[1-9]{2}9\d{8})$/, '56': /^(?:9\d{8})$/, '57': /^(?:3\d{9})$/, '58': /^(?:4\d{9})$/, '60': /^(?:1\d{8,9})$/, '61': /^(?:4\d{8})$/, '62': /^(?:8\d{8,10})$/, '63': /^(?:9\d{9})$/, '64': /^(?:2\d{7,9})$/, '65': /^(?:[89]\d{7})$/, '66': /^(?:[689]\d{8})$/, '81': /^(?:[789]0\d{8})$/, '82': /^(?:1[016-9]\d{7,8})$/, '84': /^(?:[35789]\d{8})$/, '86': /^(?:1[3-9]\d{9})$/, '90': /^(?:5\d{9})$/, '91': /^(?:[6-9]\d{9})$/, '92': /^(?:3\d{9})$/, '93': /^(?:7\d{8})$/, '94': /^(?:7\d{8})$/, '95': /^(?:9\d{7,9})$/, '98': /^(?:9\d{9})$/, '212': /^(?:[67]\d{8})$/, '213': /^(?:[567]\d{8})$/, '216': /^(?:[2-9]\d{7})$/, '233': /^(?:[235]\d{8})$/, '234': /^(?:[789][01]\d{8})$/, '237': /^(?:6\d{8})$/, '243': /^(?:[89]\d{8})$/, '244': /^(?:9\d{8})$/, '249': /^(?:9\d{8})$/, '250': /^(?:7\d{8})$/, '251': /^(?:[79]\d{8})$/, '254': /^(?:[17]\d{8})$/, '255': /^(?:[67]\d{8})$/, '256': /^(?:7\d{8})$/, '258': /^(?:8\d{8})$/, '260': /^(?:[79]\d{8})$/, '263': /^(?:7\d{8})$/, '351': /^(?:9\d{8})$/, '353': /^(?:8\d{8})$/, '358': /^(?:[45]\d{6,9})$/, '375': /^(?:[234]\d{8})$/, '380': /^(?:[3-9]\d{8})$/, '420': /^(?:[67]\d{8})$/, '852': /^(?:[4-9]\d{7})$/, '853': /^(?:6\d{7})$/, '855': /^(?:[1-9]\d{7,8})$/, '856': /^(?:20\d{8})$/, '880': /^(?:1\d{9})$/, '886': /^(?:9\d{8})$/, '964': /^(?:7\d{9})$/, '966': /^(?:5\d{8})$/, '971': /^(?:5\d{8})$/, '976': /^(?:[5-9]\d{7})$/, '977': /^(?:9\d{9})$/, '992': /^(?:\d{9})$/, '993': /^(?:6\d{7})$/, '996': /^(?:[2-9]\d{8})$/, '998': /^(?:\d{9})$/};

/* 去掉空格、横线、点、括号；去掉顺手输入的 +区号 / 00区号；去掉国内拨号习惯的开头 0（英国 07…、日本 090…） */
function normalizePhone(raw, cc) {
  let v = String(raw || '').replace(/[\s\-.()（）]/g, '');
  ['+' + cc, '00' + cc].some(function (pre) {
    if (v.indexOf(pre) === 0 && v.length > pre.length + 3) { v = v.slice(pre.length); return true; }
    return false;
  });
  const rule = PHONE_RULES[cc] || /^\d{4,11}$/;
  if (!rule.test(v) && v[0] === '0' && rule.test(v.slice(1))) v = v.slice(1);
  return v;
}

function readPhone(prefix) {
  const cc = document.getElementById(prefix + 'PhoneCc').value;
  const input = document.getElementById(prefix + 'Phone');
  if (!input.value.trim()) return { ok: false, msg: t('v_phone_empty') };
  const phone = normalizePhone(input.value, cc);
  if (!(PHONE_RULES[cc] || /^\d{4,11}$/).test(phone)) return { ok: false, msg: t('v_phone_bad') };
  return { ok: true, phoneCc: cc, phone: phone };
}

/* 姓名：中文 2–20 字，或证件上的拉丁字母写法；多余空格合并 */
function readName(id) {
  const name = document.getElementById(id).value.trim().replace(/\s+/g, ' ');
  if (!name) return { ok: false, msg: t('v_name_empty') };
  const zh = /^[一-龥·]{2,20}$/.test(name);
  const latin = /^[A-Za-zÀ-ɏ][A-Za-zÀ-ɏ .'\-]{0,48}[A-Za-zÀ-ɏ.]$/.test(name);
  if (!zh && !latin) return { ok: false, msg: t('v_name') };
  return { ok: true, name: name };
}

function readEmail(id) {
  const email = document.getElementById(id).value.trim();
  if (email && !/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(email)) return { ok: false, msg: t('v_email') };
  return { ok: true, email: email };
}

/* 本机记住的就诊人显示成「姓名 · 打码的证件号」 */
function maskDoc(no) {
  no = String(no || '');
  if (no.length >= 15) return no.slice(0, 6) + '****' + no.slice(-4);
  if (no.length >= 6) return no.slice(0, 2) + '****' + no.slice(-2);
  return no;
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

let currentPage = 'home';
function showPage(name) {
  currentPage = name;
  var pages = ['home', 'mine', 'booking', 'reminders', 'profile', 'admin', 'login'];
  for (var i = 0; i < pages.length; i++) {
    var el = document.getElementById('page-' + pages[i]);
    if (!el) continue;
    el.style.display = (pages[i] === name) ? '' : 'none';
  }

  /* 顶栏高亮当前这一项：我的预约 / 就诊提醒 / 我的资料 同属「个人中心」，登录页算「后台管理」 */
  var navs = ['navHome', 'navBooking', 'navCenter', 'navAdmin'];
  var navMap = { home: 'navHome', booking: 'navBooking',
                 mine: 'navCenter', reminders: 'navCenter', profile: 'navCenter',
                 admin: 'navAdmin', login: 'navAdmin' };
  for (var j = 0; j < navs.length; j++) {
    var n = document.getElementById(navs[j]);
    if (n) n.className = (navMap[name] === navs[j]) ? 'on' : '';
  }

  /* 个人中心的标题与切换条：只在这三页显示，并高亮当前页 */
  var inCenter = name === 'mine' || name === 'reminders' || name === 'profile';
  document.getElementById('centerHead').style.display = inCenter ? '' : 'none';
  var ct = { mine: 'ctMine', reminders: 'ctReminders', profile: 'ctProfile' };
  for (var k in ct) document.getElementById(ct[k]).className = 'btn' + (k === name ? ' on' : '');

  if (name === 'home') renderHome();
  if (name === 'mine') renderMine();
  if (name === 'reminders') renderReminders();
  if (name === 'profile') renderProfile();
  window.scrollTo(0, 0);
}

function goHome() {
  showPage('home');
}

/* 首页「常用科室」：7 个最常挂的科室 + 「全部科室」，点科室直接跳到挂号第 2 步选医生 */
const HOME_DEPTS = ['D01', 'D03', 'D02', 'D06', 'D04', 'D05', 'D09'];
function renderHome() {
  var box = document.getElementById('homeDepts');
  if (!box) return;
  var html = '';
  for (var i = 0; i < HOME_DEPTS.length; i++) {
    var d = null;
    for (var j = 0; j < departments.length; j++) { if (departments[j].id === HOME_DEPTS[i]) { d = departments[j]; break; } }
    if (!d) continue;
    html += '<button class="dq" onclick="startBookingWithDept(\'' + d.id + '\', \'\')"><span>' + deptIcon(d.id) + '</span>' + escapeHtml(trDeptName(d)) + '</button>';
  }
  html += '<button class="dq" onclick="startBooking(true)"><span>' + icon('search') + '</span>' + escapeHtml(t('all_depts')) + '</button>';
  box.innerHTML = html;
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

/* ---------- 我的资料 ----------
 * 上半部分填证件（类型 / 国籍 / 号码）加载档案，下半部分改姓名、手机号、邮箱。 */
/* ---------- 我的资料 ----------
 * 一步到位：本机已经核对过这位就诊人（有凭证），直接显示可编辑的资料；
 * 没核对过（或凭证过期），资料页本身就是核对表单 —— 填一次姓名和证件，通过后当场显示资料。
 * 以前要先选证件点「加载」，再在弹窗里把姓名和证件重填一遍，同样的信息填两次。 */
function renderProfile() {
  const sess = loadSession();
  const key = sessKey(sess);
  if (key && loadPatientTokens()[key]) loadProfile();
  else renderProfileVerify(sess);
}
function renderProfileVerify(prefill, msg) {
  prefill = prefill || {};
  document.getElementById('profileBox').innerHTML = '<div class="box narrow">'
    + '<p class="tip">' + escapeHtml(t('prof_verify_tip')) + '</p>'
    + '<p><label for="pvName">' + t('name') + '</label><input id="pvName" type="text" maxlength="50" autocomplete="name" placeholder="' + escapeHtml(t('name_ph')) + '" value="' + escapeHtml(prefill.name || '') + '" /></p>'
    + docFieldsHtml('pv', prefill, false)
    + '<p class="form-error" id="pvErr" role="alert">' + escapeHtml(msg || '') + '</p>'
    + '<div class="actions"><button class="btn primary" id="pvBtn" onclick="verifyProfile()">' + t('verify_load') + '</button></div>'
    + '</div>';
}
async function verifyProfile() {
  const err = document.getElementById('pvErr');
  err.textContent = '';
  const nm = readName('pvName');
  if (!nm.ok) { err.textContent = nm.msg; return; }
  const doc = readDoc('pv');
  if (!doc.ok) { err.textContent = doc.msg; return; }
  const btn = document.getElementById('pvBtn');
  btn.disabled = true;
  try {
    const r = await request('POST', '/patient-auth/realname',
      { name: nm.name, idType: doc.idType, nationality: doc.nationality, idCard: doc.idCard }, true);
    savePatientToken(doc.docKey, r.patientToken);
    saveSession({ name: nm.name, idType: doc.idType, nationality: doc.nationality, idCard: doc.idCard, docKey: doc.docKey });
    await loadProfile();
  } catch (e) {
    err.textContent = trError(e.message) || t('fail');
    btn.disabled = false;
  }
}
async function loadProfile() {
  const box = document.getElementById('profileBox');
  const sess = loadSession();
  box.innerHTML = '<div class="box narrow"><p class="tip">' + t('loading') + '</p></div>';
  let p;
  try {
    /* 最后一个参数 true：凭证失效时不弹全局的核对窗，而是把这一页换成核对表单 */
    p = await request('GET', '/patients/mine?idCard=' + encodeURIComponent(sessKey(sess)), null, true);
  } catch (e) {
    if (e.code === 'PATIENT_AUTH_REQUIRED' || e.status === 401) return renderProfileVerify(sess);
    return renderProfileVerify(sess, e.status === 404 ? t('prof_notfound') : (trError(e.message) || t('fail')));
  }
  box.innerHTML = '<div class="box narrow">'
    + '<p><label for="pNameEdit">' + t('name') + '</label><input id="pNameEdit" type="text" maxlength="50" value="' + escapeHtml(p.name || '') + '" /></p>'
    + '<p><label for="pIdCardEdit">' + t('id_no') + '</label><input id="pIdCardEdit" type="text" readonly style="background:#efe8dc;color:#6b6459" value="'
    + escapeHtml(t('idt_' + p.idType) + ' · ' + (p.idCard || '')) + '" /></p>'
    + phoneFieldHtml('pe', { phoneCc: p.phoneCc || '86' })
    + '<p class="tip">' + escapeHtml(t('phone_keep', { p: (p.phoneCc && p.phoneCc !== '86' ? '+' + p.phoneCc + ' ' : '') + (p.phone || '') })) + '</p>'
    + '<p><label for="pEmailEdit">' + t('email') + '</label><input id="pEmailEdit" type="text" maxlength="120" placeholder="' + escapeHtml(t('email_ph')) + '" value="' + escapeHtml(p.email || '') + '" /></p>'
    + '<div class="actions"><button class="btn primary" onclick="saveProfile()">' + t('save') + '</button>'
    + '<button class="btn" onclick="clearLocalPatient()">' + t('switch_patient') + '</button></div>'
    + '<p class="tip" id="profileSaveTip"></p>'
    + rememberHtml()
    + '</div>';
}
async function saveProfile() {
  const tip = document.getElementById('profileSaveTip');
  const sess = loadSession();
  const nm = readName('pNameEdit');
  if (!nm.ok) { tip.textContent = nm.msg; return; }
  const body = { name: nm.name };
  /* 手机号留空 = 不修改；填了就整号校验 */
  if (document.getElementById('pePhone').value.trim()) {
    const ph = readPhone('pe');
    if (!ph.ok) { tip.textContent = ph.msg; return; }
    body.phoneCc = ph.phoneCc; body.phone = ph.phone;
  }
  const em = readEmail('pEmailEdit');
  if (!em.ok) { tip.textContent = em.msg; return; }
  body.email = em.email;
  tip.textContent = t('saving');
  try {
    await apiUpdatePatient(sessKey(sess), body);
    saveSession(body);
    savePatientToHistory(loadSession());
    tip.textContent = t('saved');
    setTimeout(function () { loadProfile(); }, 900);
  } catch (e) {
    tip.textContent = trError(e.message) || t('fail');
  }
}

/* 管理后台页顶部：登录了就显示是谁、什么角色；顶栏只留「退出登录」按钮。
 * 角色显示出来是有用的 —— 窗口人员看到「窗口」就知道自己看不到审计日志，
 * 不用去点一个必然 403 的按钮。 */
function showLoginInfo() {
  /* 顶栏只标一句「管理员已登录」（点它进后台）；退出登录放在后台页签里，
   * 患者端页面不出现退出按钮，免得在公用电脑上被误点或被患者看到账号操作 */
  var el = document.getElementById('adminWho');
  var badge = document.getElementById('staffBadge');
  var bar = document.getElementById('staffBar');
  if (!currentUser) {
    if (el) el.textContent = '';
    if (badge) badge.style.display = 'none';
    if (bar) bar.className = 'staff-bar';
    renderKioskSetting();
    return;
  }
  var roleName = ROLE_LABEL[currentUser.role] || currentUser.role || '管理员';
  if (el) el.textContent = '当前账号：' + currentUser.username + ' · ' + roleName;
  renderKioskSetting();
  if (badge) { badge.innerHTML = icon('check') + escapeHtml(roleName + '已登录'); badge.title = '点击进入后台管理'; badge.style.display = ''; }
  if (bar) { bar.innerHTML = icon('check') + escapeHtml(roleName + '已登录 · 进入后台管理 ›'); bar.className = 'staff-bar on'; }
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
 * 八、患者端：挂号向导（含搜医生）、我的预约、就诊提醒、我的资料
 * ============================================================ */

/* focusSearch：从首页「找医生」进来时把光标放进搜索框 */
function startBooking(focusSearch) {
  bookingState = { step: 1, deptId: '', doctorId: '', scheduleId: '', date: '', period: '', patient: isKiosk() ? null : loadSession(), apt: null };
  showPage('booking');
  renderBookingStep();
  if (focusSearch === true) { var box = document.getElementById('deptSearch'); if (box) box.focus(); }
}
function startBookingWithDept(deptId, doctorId) {
  bookingState = { step: 2, deptId: deptId, doctorId: doctorId, scheduleId: '', date: '', period: '', patient: isKiosk() ? null : loadSession(), apt: null };
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
    s.title = back ? t('step_back_title') : '';
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
  var html = '<div class="search-box"><input type="text" id="deptSearch" placeholder="' + escapeHtml(t('search_ph')) + '" oninput="filterDepts(this.value)" /><button class="btn" onclick="filterDepts(document.getElementById(\'deptSearch\').value)">' + t('search') + '</button></div>';
  if (t('search_lang_note')) html += '<p class="tip">' + escapeHtml(t('search_lang_note')) + '</p>';
  html += '<div id="deptList" class="cards"></div>';
  body.innerHTML = html;
  filterDepts('');
}
function filterDepts(q) {
  q = (q || '').trim();
  clearTimeout(deptSearchTimer);
  if (!q) { renderDeptCards(DEPT_ORDER.map(function (id) { return { deptId: id, hits: [] }; }), [], ''); return; }
  deptSearchTimer = setTimeout(function () { searchDepts(q); }, 250);
}
/* 按姓名（含拼音）或擅长方向找医生（医生只有二十几位，前端直接匹配，不用走接口） */
function searchDoctors(q) {
  var out = [], ql = q.toLowerCase();
  for (var i = 0; i < doctors.length; i++) {
    var d = doctors[i];
    if (d.name.indexOf(q) >= 0 || (DOCTOR_INTRO[d.id] || '').indexOf(q) >= 0
        || (DOCTOR_PINYIN[d.id] || '').toLowerCase().indexOf(ql) >= 0
        || (ql.length >= 3 && trIntro(d.id).toLowerCase().indexOf(ql) >= 0)) out.push(d);
  }
  return out;
}
/* 用当前语言的科室名匹配（Dermatology、皮膚科 …）：词典是中文的，外文科室名在前端补上 */
function searchDeptNames(q) {
  var ql = q.toLowerCase(), out = [];
  if (LANG === 'zh' || ql.length < 2) return out;
  for (var i = 0; i < departments.length; i++) {
    if (trDeptName(departments[i]).toLowerCase().indexOf(ql) >= 0) out.push({ deptId: departments[i].id, hits: [], score: 1e9 });
  }
  return out;
}
async function searchDepts(q) {
  var seq = ++deptSearchSeq;
  var res;
  try {
    res = await apiSearchDepartments(q);
  } catch (e) {
    /* 接口不可用时退回到只按科室名匹配 */
    res = { results: departments.filter(function (d) { return d.name.indexOf(q) >= 0; })
                                 .map(function (d) { return { deptId: d.id, hits: [] }; }), others: [] };
  }
  if (seq !== deptSearchSeq) return;          /* 已经有更新的搜索了，丢弃旧结果 */
  var local = searchDeptNames(q), seen = {};
  local.forEach(function (x) { seen[x.deptId] = 1; });
  var merged = local.concat((res.results || []).filter(function (x) { return !seen[x.deptId]; }));
  renderDeptCards(merged, res.others || [], q);
}
/* items: [{deptId, hits}]；others: 本院未开设的科室 [{name, hits, score}] */
function renderDeptCards(items, others, q) {
  var list = document.getElementById('deptList');
  if (!list) return;
  var html = '';
  var docs = q ? searchDoctors(q) : [];
  /* 搜的是医生姓名（如「张建国」）时只列医生，不再拿姓名去匹配疾病 / 科室 */
  for (var k0 = 0; k0 < docs.length; k0++) {
    if (docs[k0].name.indexOf(q) >= 0 || (DOCTOR_PINYIN[docs[k0].id] || '').toLowerCase().indexOf(q.toLowerCase()) >= 0) { items = []; others = []; break; }
  }
  if (docs.length) {
    html += '<h3 class="grid-head">' + t('doctors_h') + '</h3>';
    for (var k = 0; k < docs.length; k++) {
      var doc = docs[k], dp = null;
      for (var m = 0; m < departments.length; m++) { if (departments[m].id === doc.deptId) { dp = departments[m]; break; } }
      html += `<div class="card" onclick="startBookingWithDept('${doc.deptId}','${doc.id}')">`;
      html += '<div class="card-title">' + escapeHtml(trDoctorName(doc)) + ' <span class="tip">' + escapeHtml(trTitle(doc.title)) + '</span></div>';
      html += '<div class="tip">' + deptIcon(doc.deptId) + ' ' + escapeHtml(dp ? trDeptName(dp) : '') + ' · ' + t('fee') + ' ' + fmtMoney(doc.fee) + '</div>';
      if (trIntro(doc.id)) html += '<div class="tip">' + t('specialty') + ': ' + escapeHtml(trIntro(doc.id)) + '</div>';
      html += '</div>';
    }
    if (items.length) html += '<h3 class="grid-head">' + t('depts_h') + '</h3>';
  }
  var top = items.length ? items[0].score || 0 : 0;
  if (others.length && (!items.length || others[0].score >= top)) {
    var o = others[0];
    var what = '“' + escapeHtml(q) + '”' + (o.hits && o.hits.length ? '（' + escapeHtml(o.hits.join('、')) + '）' : '');
    html += '<p class="tip search-hint">' + what
          + (o.name === '急诊科' ? t('er_hint') : t('other_hint', { dept: escapeHtml(o.name) }))
          + (items.length ? t('see_below') : '') + '</p>';
  }
  for (var i = 0; i < items.length; i++) {
    var d = null;
    for (var j = 0; j < departments.length; j++) { if (departments[j].id === items[i].deptId) { d = departments[j]; break; } }
    if (!d) continue;
    var docs = doctorsOf(d.id);
    html += `<div class="card" onclick="pickDept('${d.id}')">`;
    html += '<div class="card-title">' + deptIcon(d.id) + ' ' + escapeHtml(trDeptName(d)) + sexLimitBadge(d.id) + '</div>';
    if (items[i].hits && items[i].hits.length) html += '<div class="tip">' + t('match') + ': ' + escapeHtml(items[i].hits.join('、')) + '</div>';
    html += '<div class="tip">' + escapeHtml(trDeptDesc(d)) + '</div>';
    html += '<div class="tip">' + icon('pin') + ' ' + escapeHtml(d.location ? trLocation(d.location) : t('loc_tbd')) + ' · ' + t('n_doctors', { n: docs.length }) + '</div>';
    html += '</div>';
  }
  if (!items.length && !others.length && !docs.length) html = '<p class="tip search-hint">' + t('no_match') + '</p>';
  list.innerHTML = html;
}
function deptSexLimit(deptId) {
  for (var i = 0; i < departments.length; i++) { if (departments[i].id === deptId) return departments[i].sexLimit || ''; }
  return '';
}
function sexLimitBadge(deptId) {
  var lim = deptSexLimit(deptId);
  return lim ? ' <span class="badge orange">' + escapeHtml(t(lim === 'F' ? 'only_f' : 'only_m')) + '</span>' : '';
}
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
  var html = '<div class="actions"><button class="btn" onclick="backStep1()">' + t('back') + '</button></div>';
  html += '<h3>' + escapeHtml(dept ? trDeptName(dept) : '') + ' · ' + escapeHtml(dept ? trLocation(dept.location || '') : '') + '</h3>';
  html += '<div id="doctorList"><p class="tip">' + t('loading_slots') + '</p></div>';
  body.innerHTML = html;
  /* 预加载该科室所有医生的号源，这样卡片上能显示真实余号 */
  var docs = doctorsOf(bookingState.deptId);
  for (var i = 0; i < docs.length; i++) {
    delete allSchedules[docs[i].id];
    try { allSchedules[docs[i].id] = await apiDoctorSchedules(docs[i].id, 14); }
    catch (e) { /* 忽略单条失败，不展示旧余号 */ }
  }
  renderDoctorList();
}
function renderDoctorList() {
  var container = document.getElementById('doctorList');
  if (!container) return;
  var docs = doctorsOf(bookingState.deptId);
  if (docs.length === 0) { container.innerHTML = '<p class="tip">' + t('no_doctor') + '</p>'; return; }
  var html = '';
  for (var i = 0; i < docs.length; i++) {
    var d = docs[i], st = scheduleStatus(d.id);
    var badge = '<span class="badge ' + st.cls + '">' + st.text + '</span>';
    var sel = (bookingState.doctorId === d.id) ? ' style="border-color:#1f5e55;background:#eaf2ee"' : '';
    html += `<div class="doc-card"${sel} onclick="pickDoctor('${d.id}')">`;
    html += '<div class="avatar">' + escapeHtml(d.name.charAt(0)) + '</div>';
    html += '<div class="info">';
    html += '<div class="name">' + escapeHtml(trDoctorName(d)) + ' ' + escapeHtml(trTitle(d.title)) + ' ' + badge + '</div>';
    html += '<div class="meta">' + escapeHtml(trIntro(d.id)) + ' · ' + t('fee') + ' ' + fmtMoney(d.fee) + '</div>';
    html += '<div class="actions">';
    if (st.remain > 0) {
      html += `<button class="btn small primary" onclick="event.stopPropagation(); pickDoctor('${d.id}')">${t('view_slots')}</button>`;
    } else {
      /* 候补按半天排：先展开号源面板，在已满的时段上点「排候补」 */
      html += `<button class="btn small" onclick="event.stopPropagation(); pickDoctor('${d.id}')">${t('join_wl')}</button>`;
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
  for (var i = 0; i < list.length; i++) { if (!list[i].closed && !list[i].ended) totalRemain += list[i].remain; }
  if (totalRemain > 5) return { text: t('st_avail'), cls: 'green', remain: totalRemain };
  if (totalRemain > 0) return { text: t('st_tight'), cls: 'orange', remain: totalRemain };
  return { text: t('st_full'), cls: 'grey', remain: 0 };
}
async function pickDoctor(doctorId) {
  bookingState.doctorId = doctorId;
  bookingState.scheduleId = '';
  delete allSchedules[doctorId];
  try { allSchedules[doctorId] = await apiDoctorSchedules(doctorId, 14); }
  catch (e) { alert(t('load_slots_fail') + e.message); return; }
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
  var html = '';
  if (scheduleStatus(bookingState.doctorId).remain === 0) html += '<p class="tip">' + t('wl_pick_slot') + '</p>';
  html += '<div class="dates scroll">';
  for (var i = 0; i < days.length; i++) {
    var ds = days[i].date, has = false;
    for (var j = 0; j < list.length; j++) { if (list[j].date === ds && !list[j].closed && !list[j].ended && list[j].remain > 0) { has = true; break; } }
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
      /* 当天已停止挂号的半天：灰掉、不能选、也不能排候补 */
      if (s.ended) {
        html += '<div class="card disabled" title="' + escapeHtml(t('slot_ended_tip')) + '">';
        html += '<div class="card-title">' + escapeHtml(trPeriod(s.period)) + ' <span class="badge grey">' + t('st_ended') + '</span></div>';
        html += '<div class="tip">' + escapeHtml(t('slot_ended_tip')) + '</div></div>';
        continue;
      }
      var st = s.remain > 5 ? 'green' : s.remain > 0 ? 'orange' : 'grey';
      var stText = s.remain > 5 ? t('st_avail') : s.remain > 0 ? t('st_tight') : t('st_full');
      var on = (bookingState.scheduleId === s.id) ? ' style="border-color:#1f5e55;background:#eaf2ee"' : '';
      html += `<div class="card"${on} onclick="selectPeriod('${s.id}')">`;
      html += '<div class="card-title">' + escapeHtml(trPeriod(s.period)) + ' <span class="badge ' + st + '">' + stText + ' · ' + t('remain', { n: s.remain }) + '</span></div>';
      html += '<div class="tip">' + escapeHtml(trRoom(s.room)) + ' · ' + fmtMoney(docFee) + '</div>';
      /* 已满的半天可以排候补；按钮要拦住冒泡，否则会触发外层的 selectPeriod */
      if (s.remain <= 0) html += `<div class="actions"><button class="btn small" onclick="event.stopPropagation(); openWaitlistForm('${s.id}')">${t('join_wl')}</button></div>`;
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
  if (s && s.ended) { alert(t('slot_ended_tip')); return; }
  if (!s || s.remain <= 0) { alert(t('slot_full_alert')); return; }
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
  var pt = bookingState.patient || {};
  var html = '<div class="actions"><button class="btn" onclick="backStep2()">' + t('back') + '</button></div>';
  html += '<h3>' + t('confirm_h') + '</h3>';
  html += '<div class="box">';
  html += '<p><b>' + t('f_dept') + colon() + '</b>' + escapeHtml(dept ? trDeptName(dept) : '') + '</p>';
  html += '<p><b>' + t('f_doctor') + colon() + '</b>' + escapeHtml(doc ? (trDoctorName(doc) + ' ' + trTitle(doc.title)) : '') + '</p>';
  html += '<p><b>' + t('f_time') + colon() + '</b>' + escapeHtml(sch ? (sch.date + ' ' + weekdayLabel(sch.date) + ' ' + trPeriod(sch.period)) : '') + '</p>';
  html += '<p><b>' + t('f_place') + colon() + '</b>' + escapeHtml(dept ? trLocation(dept.location || '') : '') + ' · ' + escapeHtml(sch ? trRoom(sch.room) : '') + '</p>';
  html += '<p><b>' + t('f_fee') + colon() + '</b>' + fmtMoney(doc ? doc.fee : 0) + '</p>';
  html += '</div>';
  html += '<div class="tip" style="margin:8px 0">' + t('noshow_warn') + '</div>';
  html += '<h3>' + t('patient_h') + '</h3>';
  if (saved.length > 0) {
    html += '<div class="patient-pick">';
    for (var i = 0; i < saved.length; i++) {
      var p = saved[i];
      var on = (sessKey(pt) && sessKey(pt) === sessKey(p)) ? ' on' : '';
      html += '<div class="patient-chip' + on + '" onclick="pickSavedPatient(' + i + ')">' + escapeHtml(p.name) + ' ' + escapeHtml(maskDoc(p.idCard)) + '</div>';
    }
    html += '<div class="patient-chip" onclick="newPatient()">' + t('new_patient') + '</div>';
    html += '</div>';
  }
  html += '<div id="patientForm">';
  html += '<p><label for="bkName">' + t('name') + '</label><input id="bkName" type="text" maxlength="50" autocomplete="name" placeholder="' + escapeHtml(t('name_ph')) + '" value="' + escapeHtml(pt.name || '') + '" /></p>';
  html += docFieldsHtml('bk', pt, true);
  html += '<p><label for="bkEmail">' + t('email') + '</label><input id="bkEmail" type="text" maxlength="120" placeholder="' + escapeHtml(t('email_ph')) + '" value="' + escapeHtml(pt.email || '') + '" /></p>';
  html += '</div>';
  /* 错误直接写在按钮上方：alert 被浏览器屏蔽时，用户会以为「点了没反应」 */
  html += rememberHtml();
  html += '<p class="form-error" id="bkError" role="alert"></p>';
  html += '<div class="actions">';
  html += '<button class="btn primary" id="bkSubmit" onclick="submitBooking()">' + t('submit_booking') + '</button>';
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
  var errEl = document.getElementById('bkError');
  function fail(msg) { if (errEl) errEl.textContent = msg; else alert(msg); }
  if (errEl) errEl.textContent = '';
  var nm = readName('bkName');
  if (!nm.ok) return fail(nm.msg);
  var doc = readDoc('bk');
  if (!doc.ok) return fail(doc.msg);
  var lim = deptSexLimit(bookingState.deptId);
  if (lim && doc.sex && doc.sex !== lim) return fail(t(lim === 'F' ? 'e_only_f' : 'e_only_m'));
  var ph = readPhone('bk');
  if (!ph.ok) return fail(ph.msg);
  var em = readEmail('bkEmail');
  if (!em.ok) return fail(em.msg);
  if (!bookingState.scheduleId) { alert(t('slot_expired')); backStep2(); return; }
  var btn = document.getElementById('bkSubmit');
  if (btn) { btn.disabled = true; btn.textContent = t('booking_ing'); }
  var patient = {
    name: nm.name, idType: doc.idType, nationality: doc.nationality, idCard: doc.idCard, docKey: doc.docKey, sex: doc.sex,
    phoneCc: ph.phoneCc, phone: ph.phone, email: em.email,
  };
  try {
    var apt = await apiCreateAppointment(bookingState.scheduleId, patient, captcha ? captcha.token : '', captcha ? captcha.answer : '');
    saveSession(patient);
    savePatientToHistory(patient);
    bookingState.step = 4;
    bookingState.patient = patient;
    bookingState.apt = apt;
    renderBookingStep();
    if (apt.notice) alert(trError(apt.notice));
  } catch (err) {
    if (btn) { btn.disabled = false; btn.textContent = t('submit_booking'); }
    if (err.code === 'CAPTCHA_REQUIRED') {
      if (captcha) alert(t('captcha_wrong'));
      document.getElementById('captchaWhy').textContent = t('captcha_why', { n: (err.data && err.data.remain) || '…' });
      var c = await openCaptcha();
      if (c) submitBooking(c);
      return;
    }
    var raw = err.raw || err.message || '';
    if (raw.indexOf('号源已挂完') >= 0 || raw.indexOf('超卖') >= 0 || raw.indexOf('已预约该时段') >= 0) {
      alert(t('just_taken')); backStep2(); return;
    }
    fail(err.message || t('fail'));
  }
}

/* ---------- Step 4 成功页 ---------- */
let kioskCountdownTimer = null;
function startKioskCountdown() {
  clearInterval(kioskCountdownTimer);
  var n = 60;
  var tick = function () {
    var el = document.getElementById('kioskCountdown');
    if (!el || bookingState.step !== 4) { clearInterval(kioskCountdownTimer); return; }   // 已经离开成功页
    if (n <= 0) { clearInterval(kioskCountdownTimer); forgetPatient(); return; }
    el.innerHTML = icon('logo') + ' ' + escapeHtml(t('kiosk_countdown', { n: n }));
    n--;
  };
  tick();
  kioskCountdownTimer = setInterval(tick, 1000);
}
/* ---------- 预约凭证 ----------
 * 挂号成功页和「我的预约 → 查看凭证」用同一份内容，成功页关掉之后也能随时再打开。
 * apt 是接口返回的挂号单（map_appointment）：科室、医生、诊室、日期、时段、号序、单号都在上面。 */
let voucherApt = null;
function aptDept(apt) {
  for (var i = 0; i < departments.length; i++) { if (departments[i].id === apt.deptId) return departments[i]; }
  return null;
}
function aptDoctor(apt) {
  for (var i = 0; i < doctors.length; i++) { if (doctors[i].id === apt.doctorId) return doctors[i]; }
  return null;
}
function voucherDetailHtml(apt, patientName) {
  var dept = aptDept(apt), doc = aptDoctor(apt);
  var html = '<div class="detail">';
  html += '<p><b>' + t('f_dept') + colon() + '</b>' + escapeHtml(dept ? trDeptName(dept) : (apt.deptName || ''))
        + ' · ' + escapeHtml(doc ? trDoctorName(doc) + ' ' + trTitle(doc.title) : (apt.doctorName || '')) + '</p>';
  html += '<p><b>' + t('f_time') + colon() + '</b>' + escapeHtml(apt.date || '') + ' ' + escapeHtml(apt.date ? weekdayLabel(apt.date) : '') + ' ' + escapeHtml(trPeriod(apt.period)) + '</p>';
  html += '<p><b>' + t('f_place') + colon() + '</b>' + escapeHtml(dept ? trLocation(dept.location || '') : trLocation(apt.location || '')) + ' · ' + escapeHtml(trRoom(apt.room)) + '</p>';
  html += '<p><b>' + t('f_arrive') + colon() + '</b>' + suggestArrival(apt.period) + '</p>';
  html += '<p><b>' + t('f_patient') + colon() + '</b>' + escapeHtml(patientName || apt.patientName || '') + '</p>';
  html += '<p><b>' + t('f_fee') + colon() + '</b>' + fmtMoney(apt.fee || 0) + '</p>';
  /* 单号显示患者查询用的预约单号（10 位），没有时退回内部编号 */
  html += '<p><b>' + t('f_apt_no') + colon() + '</b>' + escapeHtml(apt.appointmentNo || apt.id || '') + ' · ' + t('seq') + ' ' + (apt.seqNo || '-') + '</p>';
  html += '</div>';
  return html;
}
/* 凭证上的操作：日历、路线，待就诊的还能改约、取消 */
function voucherActionsHtml(apt) {
  /* 自助机上不提供「添加到日历」：下载的日历文件会留在公共电脑上 */
  var html = isKiosk() ? '' : '<button class="btn" onclick="addToCalendar()">' + icon('calendar') + escapeHtml(t('add_cal')) + '</button>';
  html += '<button class="btn" onclick="viewRoute()">' + icon('route') + escapeHtml(t('route')) + '</button>';
  if (apt.status === 'booked') {
    html += '<button class="btn" onclick="rescheduleAppt(\'' + apt.id + '\',\'' + apt.deptId + '\')">' + t('edit_appt') + '</button>';
    html += '<button class="btn" onclick="cancelVoucherAppt()">' + t('cancel_appt') + '</button>';
  }
  return html;
}

function renderStep4(body) {
  var apt = bookingState.apt || {};
  apt.status = apt.status || 'booked';
  voucherApt = apt;
  var html = '<div class="success-box">';
  html += '<div class="big-check">' + icon('check') + '</div>';
  html += '<h2>' + t('success') + '</h2>';
  html += voucherDetailHtml(apt, bookingState.patient ? bookingState.patient.name : '');
  html += '<div class="actions">' + voucherActionsHtml(apt) + '</div>';
  html += '<div class="actions">';
  html += '<button class="btn primary" onclick="startBooking()">' + t('continue_booking') + '</button>';
  html += '<button class="btn" onclick="showPage(\'mine\')">' + t('view_mine') + '</button>';
  if (!rememberOn()) html += '<button class="btn" onclick="forgetPatient()">' + t('done_clear') + '</button>';
  html += '</div>';
  if (isKiosk()) html += '<p class="kiosk-note" id="kioskCountdown"></p>';
  else html += '<p class="tip">' + t('voucher_tip') + '</p>';
  html += '<p class="tip">' + t('bring_docs') + '</p>';
  html += '</div>';
  body.innerHTML = html;
  if (isKiosk()) startKioskCountdown();
}

/* 我的预约 → 查看凭证 */
let mineApts = {};          // renderMineList 拉到的挂号单，按编号存，打开凭证时直接取
function openVoucher(aptId) {
  var apt = mineApts[aptId];
  if (!apt) return;
  voucherApt = apt;
  document.getElementById('voucherBody').innerHTML = voucherDetailHtml(apt)
    + '<p class="tip">' + t('bring_docs') + '</p>'
    + '<div class="actions">' + voucherActionsHtml(apt)
    + '<button class="btn primary" onclick="closeVoucher()">' + t('close') + '</button></div>';
  document.getElementById('voucherMask').style.display = 'flex';
}
/* ---------- 开源致谢 ----------
 * 本系统用到的开源项目。科室搜索词典的数据来自 GitHub 上的 QASystemOnMedicalKG（原项目注明请勿商用），
 * 拼音由 pypinyin 生成；运行时依赖 Flask、psycopg 与 PostgreSQL。前端没有用第三方库。 */
const CREDITS = [
  ['QASystemOnMedicalKG', 'liuhuanyong', 'https://github.com/liuhuanyong/QASystemOnMedicalKG', 'cr_kg'],
  ['pypinyin', 'mozillazg', 'https://github.com/mozillazg/python-pinyin', 'cr_pinyin'],
  ['Flask', 'Pallets', 'https://github.com/pallets/flask', 'cr_flask'],
  ['psycopg', 'The Psycopg Team', 'https://github.com/psycopg/psycopg', 'cr_psycopg'],
  ['PostgreSQL', 'PostgreSQL Global Development Group', 'https://www.postgresql.org/', 'cr_pg'],
];
function openCredits() {
  var html = '<p class="tip">' + escapeHtml(t('credits_intro')) + '</p><ul class="credits">';
  CREDITS.forEach(function (c) {
    html += '<li><a href="' + c[2] + '" target="_blank" rel="noopener noreferrer"><b>' + escapeHtml(c[0]) + '</b></a>'
          + ' <span class="tip">' + escapeHtml(c[1]) + '</span><br>' + escapeHtml(t(c[3])) + '</li>';
  });
  html += '</ul><p class="tip">' + escapeHtml(t('cr_self')) + '</p>';
  document.getElementById('creditsBody').innerHTML = html;
  document.getElementById('creditsMask').style.display = 'flex';
}
function closeCredits() {
  document.getElementById('creditsMask').style.display = 'none';
}

function closeVoucher() {
  document.getElementById('voucherMask').style.display = 'none';
}
function cancelVoucherAppt() {
  var apt = voucherApt;
  if (!apt || !apt.id) return;
  if (!confirm(t('confirm_cancel'))) return;
  apiCancelAppointment(apt.id).then(function () {
    alert(t('cancelled_ok'));
    closeVoucher();
    showPage('mine');
  }).catch(function (e) { alert(e.message); });
}
/* ---------- 添加到日历 ----------
 * 生成标准 iCalendar（.ics）文件：电脑上用 Outlook / Windows 日历 / Mac 日历打开就能添加，
 * iPhone 的 Safari 会直接弹出「添加到日历」，安卓手机用系统日历或 Google 日历打开。
 * 日程是这个半天的出诊时间，带两个提醒：前一天、开诊前 1 小时。
 * 自助机上不显示这个按钮（文件会留在公共电脑上）。 */
function icsText(s) {
  return String(s || '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
}
function icsFold(line) {
  /* RFC 5545：每行不超过 75 个字节，超出的折到下一行、行首加一个空格（中文一个字 3 个字节） */
  var out = '', cur = '', bytes = 0, enc = new TextEncoder();
  for (var ch of line) {
    var b = enc.encode(ch).length;
    if (bytes + b > 74) { out += cur + '\r\n '; cur = ''; bytes = 1; }
    cur += ch; bytes += b;
  }
  return out + cur;
}
function icsTime(date, hhmm) {
  /* 北京时间换成 UTC（中国不实行夏令时，固定减 8 小时），写成 20261105T053000Z */
  var d = date.split('-').map(Number), h = hhmm.split(':').map(Number);
  return new Date(Date.UTC(d[0], d[1] - 1, d[2], h[0] - 8, h[1])).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
}
function addToCalendar() {
  var apt = voucherApt;
  if (!apt || !apt.date) return;
  var dept = aptDept(apt), doc = aptDoctor(apt);
  var am = apt.period === '上午';
  var deptName = dept ? trDeptName(dept) : (apt.deptName || '');
  var docName = doc ? trDoctorName(doc) + ' ' + trTitle(doc.title) : (apt.doctorName || '');
  var place = t('hospital_sub') + ' ' + (dept ? trLocation(dept.location || '') : trLocation(apt.location || '')) + ' · ' + trRoom(apt.room);
  var no = apt.appointmentNo || apt.id || '';
  var desc = [t('f_arrive') + colon() + suggestArrival(apt.period),
              t('f_apt_no') + colon() + no + ' · ' + t('seq') + ' ' + (apt.seqNo || '-'),
              t('f_fee') + colon() + fmtMoney(apt.fee || 0),
              t('f_patient') + colon() + (apt.patientName || '')].join('\n');
  var lines = [
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//HMS//Hospital Booking//ZH', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    'UID:' + no + '@hms',
    'DTSTAMP:' + new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, ''),
    'DTSTART:' + icsTime(apt.date, am ? '08:00' : '13:30'),
    'DTEND:' + icsTime(apt.date, am ? '12:00' : '17:00'),
    'SUMMARY:' + icsText(t('cal_title') + colon() + deptName + ' · ' + docName),
    'LOCATION:' + icsText(place),
    'DESCRIPTION:' + icsText(desc),
    'BEGIN:VALARM', 'ACTION:DISPLAY', 'TRIGGER:-P1D', 'DESCRIPTION:' + icsText(t('cal_title') + ' ' + deptName), 'END:VALARM',
    'BEGIN:VALARM', 'ACTION:DISPLAY', 'TRIGGER:-PT1H', 'DESCRIPTION:' + icsText(t('cal_title') + ' ' + deptName), 'END:VALARM',
    'END:VEVENT', 'END:VCALENDAR'];
  var ics = lines.map(icsFold).join('\r\n') + '\r\n';
  var name = 'appointment-' + no + '.ics';
  /* iPhone / iPad：用 data: 地址打开，Safari 会直接弹出「添加到日历」；其他设备下载 .ics 文件 */
  if (/iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)) {
    location.href = 'data:text/calendar;charset=utf-8,' + encodeURIComponent(ics);
  } else {
    var url = URL.createObjectURL(new Blob([ics], { type: 'text/calendar;charset=utf-8' }));
    var a = document.createElement('a');
    a.href = url; a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
    alert(t('cal_done'));
  }
}
/* ---------- 怎么走 ----------
 * 不跳外部地图：按科室位置（如「门诊楼 2 层东区」）画一张楼层示意图（电梯 → 目标区域的箭头），
 * 再用箭头串起几步文字指引。位置格式见 seed_data.DEPARTMENTS 的 location。 */
const ROUTE_DIR = { '东区': 'E', '西区': 'W', '北侧': 'N', '南侧': 'S' };
function parseLocation(loc) {
  const m = /^(门诊楼|医技楼)\s*(\d+)\s*层(东区|西区|北侧|南侧)?/.exec((loc || '').trim());
  return m ? { bld: m[1], floor: Number(m[2]), side: m[3] || '' } : null;
}
function routeSvg(dir, zoneName) {
  /* 300×190 的楼层平面：上北下南；电梯在中间，目标区域高亮，箭头从电梯指过去 */
  const zones = { E: [205, 18, 80, 154], W: [15, 18, 80, 154], N: [15, 18, 270, 46], S: [15, 126, 270, 46] };
  const tips = { E: [205, 95], W: [95, 95], N: [150, 64], S: [150, 126] };
  let g = '<rect x="10" y="12" width="280" height="166" rx="10" fill="#f6f1e8" stroke="#a59a88" stroke-width="2"/>';
  if (zones[dir]) {
    const z = zones[dir];
    g += '<rect x="' + z[0] + '" y="' + z[1] + '" width="' + z[2] + '" height="' + z[3] + '" rx="8" fill="#d6e6df" stroke="#1f5e55" stroke-width="2"/>';
    const tp = tips[dir];
    g += '<line x1="150" y1="95" x2="' + tp[0] + '" y2="' + tp[1] + '" stroke="#1f5e55" stroke-width="4" marker-end="url(#rtArrow)"/>';
    if (zoneName) g += '<text x="' + (z[0] + z[2] / 2) + '" y="' + (z[1] + (dir === 'E' || dir === 'W' ? 24 : z[3] / 2 + 5)) + '" text-anchor="middle" font-size="13" font-weight="700" fill="#174a43">' + escapeHtml(zoneName) + '</text>';
  }
  g += '<rect x="128" y="78" width="44" height="34" rx="6" fill="#fff" stroke="#3a342c" stroke-width="2"/>'
     + '<text x="150" y="100" text-anchor="middle" font-size="12" fill="#3a342c">' + escapeHtml(t('rt_lift')) + '</text>'
     + '<text x="150" y="10" text-anchor="middle" font-size="11" fill="#6b6459">↑ N</text>';
  return '<svg class="route-map" viewBox="0 0 300 190" role="img" aria-label="' + escapeHtml(t('rt_h')) + '">'
    + '<defs><marker id="rtArrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5" markerHeight="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#1f5e55"/></marker></defs>'
    + g + '</svg>';
}
function viewRoute() {
  const apt = voucherApt;
  if (!apt) return;
  const dept = aptDept(apt);
  const locZh = (dept && dept.location) || apt.location || '';
  const L = parseLocation(locZh);
  const i = trIdx();
  const bld = L ? LOC_PARTS.bld[L.bld][i] : trLocation(locZh);
  const floorTxt = L ? LOC_PARTS.floor[i].replace('{n}', L.floor) : '';
  const dir = L ? ROUTE_DIR[L.side] : '';
  /* 方向箭头：同一个向右的箭头按方向旋转 */
  const rot = { E: 0, S: 90, W: 180, N: 270 }[dir];
  const arrow = rot === undefined ? icon('sign')
    : '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true" style="transform:rotate(' + rot + 'deg)">' + ICONS.arrow + '</svg>';
  const steps = [
    [icon('door'), t('rt_1', { b: bld })],
    [icon(L && L.floor > 1 ? 'lift' : 'check'), L && L.floor > 1 ? t('rt_2', { f: floorTxt }) : t('rt_2g')],
    [arrow, dir ? t('rt_3', { d: t('rt_d_' + dir), z: LOC_PARTS.side[L.side][i] }) : t('rt_3c')],
    [icon('steth'), t('rt_4', { r: trRoom(apt.room) })],
  ];
  let h = '<p class="route-where"><b>' + escapeHtml(trLocation(locZh)) + ' · ' + escapeHtml(trRoom(apt.room)) + '</b></p>';
  h += routeSvg(dir, dir ? LOC_PARTS.side[L.side][i] : '');
  h += '<ol class="route-steps">';
  steps.forEach(function (st, k) {
    h += '<li><span class="rs-ic">' + st[0] + '</span><span class="rs-tx">' + escapeHtml(st[1]) + '</span></li>';
    if (k < steps.length - 1) h += '<li class="rs-arrow" aria-hidden="true">↓</li>';
  });
  h += '</ol><p class="tip">' + escapeHtml(t('rt_tip')) + '</p>';
  document.getElementById('routeBody').innerHTML = h;
  document.getElementById('routeMask').style.display = 'flex';
}
function closeRoute() {
  document.getElementById('routeMask').style.display = 'none';
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
let mineTab = 'upcoming';
async function renderMineList(tab) {
  mineTab = tab;
  var listEl = document.getElementById('mineList');
  var tip = document.getElementById('mineTip');
  if (!listEl) return;
  var sess = loadSession();
  if (!sessKey(sess)) {
    listEl.innerHTML = '<p class="tip">' + t('need_patient') + '</p>'
      + '<div class="actions"><button class="btn primary" onclick="verifyAndReload()">' + t('auth_h') + '</button></div>';
    if (tip) tip.textContent = '';
    return;
  }
  if (tab === 'waitlist') return renderMyWaitlist();
  listEl.innerHTML = '<p class="tip">' + t('loading') + '</p>';
  try {
    var statusMap = { upcoming: 'booked', completed: 'completed', cancelled: 'cancelled' };
    var list = await apiAppointments({ idCard: sessKey(sess), status: statusMap[tab] || 'all', limit: 200 });
    if (mineTab !== tab) return;          /* 等结果期间已切到别的页签，丢弃这次的结果 */
    if (tip) tip.textContent = t('total_n', { n: list.length });
    if (list.length === 0) { listEl.innerHTML = '<p class="tip">' + t('no_records') + '</p>'; return; }
    var html = '';
    mineApts = {};
    for (var i = 0; i < list.length; i++) { mineApts[list[i].id] = list[i]; html += renderApptCard(list[i], tab); }
    listEl.innerHTML = html;
  } catch (e) {
    listEl.innerHTML = '<p class="tip">' + t('load_fail') + escapeHtml(e.message) + '</p>';
    if (tip) tip.textContent = '';
  }
}
/* 本机还没有就诊人：先做一次实名校验，通过后记为当前就诊人再刷新 */
async function verifyAndReload() {
  if (await openPatientAuth(loadSession(), '')) showPage(currentPage);
}
function renderApptCard(a, tab) {
  var st = statusText(a.status);
  var cls = statusClass(a.status);
  var html = '<div class="appt-card">';
  html += '<div class="header"><span class="title">' + escapeHtml(deptName(a.deptId) || a.deptName) + ' · ' + escapeHtml(doctorName(a.doctorId) || a.doctorName) + '</span><span class="badge ' + cls + '">' + st + '</span></div>';
  html += '<div class="meta">' + escapeHtml(a.date || '') + ' ' + escapeHtml(trPeriod(a.period)) + ' · ' + t('seq') + ' ' + (a.seqNo || '-') + ' · ' + t('fee') + ' ' + fmtMoney(a.fee || 0) + '</div>';
  if (a.status === 'booked') {
    html += '<div class="meta" style="color:#1f5e55">' + fmtCountdown(a.date) + '</div>';
    html += '<div class="actions">';
    html += `<button class="btn small" onclick="openVoucher('${a.id}')">${t('view_voucher')}</button> `;
    html += `<button class="btn small" onclick="cancelAppt('${a.id}')">${t('cancel_appt')}</button>`;
    html += ` <button class="btn small primary" onclick="rescheduleAppt('${a.id}','${a.deptId}')">${t('reschedule')}</button>`;
    html += '</div>';
  }
  html += '</div>';
  return html;
}
function cancelAppt(aptId) {
  if (!confirm(t('confirm_cancel'))) return;
  apiCancelAppointment(aptId).then(function () { alert(t('cancelled_ok')); renderMineList(mineTab); }).catch(function (e) { alert(e.message); });
}
function rescheduleAppt(aptId, deptId) {
  if (!confirm(t('confirm_reschedule'))) return;
  apiCancelAppointment(aptId).then(function () {
    closeVoucher();
    bookingState = { step: 2, deptId: deptId, doctorId: '', scheduleId: '', date: '', period: '', patient: loadSession(), apt: null };
    showPage('booking'); renderBookingStep();
  }).catch(function (e) { alert(e.message); });
}

/* ---------- 就诊提醒 ---------- */
async function renderReminders() {
  var list = document.getElementById('reminderList');
  var tip = document.getElementById('reminderTip');
  if (!list) return;
  var sess = loadSession();
  if (!sessKey(sess)) {
    list.innerHTML = '<p class="tip">' + t('need_patient') + '</p>'
      + '<div class="actions"><button class="btn primary" onclick="verifyAndReload()">' + t('auth_h') + '</button></div>';
    if (tip) tip.textContent = '';
    return;
  }
  list.innerHTML = '<p class="tip">' + t('loading') + '</p>';
  try {
    var arr = await apiNotifications(sessKey(sess));
    if (tip) tip.textContent = t('total_n', { n: arr.length }) + (t('rem_lang_note') ? ' · ' + t('rem_lang_note') : '');
    if (arr.length === 0) { list.innerHTML = '<p class="tip">' + t('no_reminders') + '</p>'; return; }
    var html = '';
    for (var i = 0; i < arr.length; i++) {
      var n = arr[i];
      html += '<div class="appt-card">';
      html += '<div class="header"><span class="title">' + escapeHtml(n.subject || t('reminder')) + '</span><span class="tip">' + fmtTime(n.at) + '</span></div>';
      html += '<div class="meta">' + escapeHtml(n.body || '') + '</div>';
      html += '</div>';
    }
    list.innerHTML = html;
  } catch (e) {
    list.innerHTML = '<p class="tip">' + t('load_fail') + escapeHtml(e.message) + '</p>';
    if (tip) tip.textContent = '';
  }
}

/* ---------- 我的资料补充 ---------- */
async function clearLocalPatient() {
  if (!confirm(t('confirm_clear'))) return;
  /* 先让服务端把本机持有的患者凭证作废（请求头会自动带上它们），再清本地。
   * 以前只清了就诊人信息，凭证还留在 localStorage 里，公用电脑上下一个人仍能用上一位的身份。 */
  try { await request('POST', '/patient-auth/logout'); } catch (e) { /* 断网也照样清本地 */ }
  PATIENT_KEYS.forEach(function (k) {
    try { localStorage.removeItem(k); } catch (e) {}
    memStore.removeItem(k);
  });
  bookingState.patient = null;
  renderProfile();
  var pt = document.getElementById('profileTip');
  if (pt) pt.textContent = t('cleared');
}

/* ============================================================
 * 九、管理端：页签与挂号记录
 *
 * 进这个页面必须先登录。前端只是「没登录就跳到登录页」，
 * 真正的拦截在服务端：就算直接去调 /api/appointments 也会拿到 401。
 * ============================================================ */

/* ---------- 切子页签 ---------- */
const ADMIN_TABS = ['records', 'patients', 'schedules', 'waitlist', 'proxy', 'access', 'outbox', 'blacklist'];

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
    patients: '病人资料 · 档案与历次挂号，隐私默认脱敏',
    schedules: '排班号源 · 一天两条（上午 / 下午）',
    waitlist: '候补队列 · 退号后自动补位给队首',
    proxy: '窗口代约 · 电话或到院办理的号由工作人员录入',
    access: '访问日志 · 谁因为什么看了谁的隐私',
    outbox: '通知发件箱 · 提醒与候补通知的投递状态',
    blacklist: '黑名单 · 拉黑后数据库层面直接拒绝挂号',
  };
  document.getElementById('adminTip').textContent = tips[tab] || '';

  if (tab === 'records') renderRecords();
  if (tab === 'patients') renderPatients();
  if (tab === 'schedules') renderSchedules();
  if (tab === 'waitlist') renderAdminWaitlist();
  if (tab === 'proxy') { initProxyForm(); document.getElementById('pxDoc').innerHTML = docFieldsHtml('px', {}, true); }
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
  syncSearchable('fDept');
  syncSearchable('fDate');
  document.getElementById('fKeyword').value = '';
  renderRecords();
}

/* 挂号状态的显示名（按当前语言，词条在 i18n.js 的 s_*）。
 * 库里是四态：booked / cancelled / completed / no_show；
 * 「已停诊」不是独立状态，是 cancelled 里 cancel_reason = closure 的那一批，
 * 后端 map_appointment 已经把它还原成 closed 了。 */
function statusText(status) {
  return I18N['s_' + status] ? t('s_' + status) : status;
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
/* ============================================================
 * 可搜索下拉框：选项多的 <select class="searchable"> 自动换成「输入框 + 过滤列表」
 *
 * 原来的 <select> 还在（隐藏起来），值仍然存在它身上 —— readDoc、onchange 这些代码一行都不用改。
 * 点开或开始输入就弹出列表，输入的文字匹配选项文字和 data-kw 里的关键字（国家的英文名、代码、区号）；
 * ↑↓ 选择、回车确定、Esc 关闭。页面上新画出来的下拉框由 MutationObserver 自动接管。
 * ============================================================ */
function enhanceSelect(sel) {
  if (sel.dataset.enhanced) return;
  sel.dataset.enhanced = '1';
  const wrap = document.createElement('span');
  wrap.className = 'ss-wrap';
  sel.parentNode.insertBefore(wrap, sel);
  wrap.appendChild(sel);
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'ss-input';
  input.autocomplete = 'off';
  input.setAttribute('role', 'combobox');
  input.setAttribute('aria-expanded', 'false');
  if (sel.id) {
    input.id = sel.id + '_ss';
    document.querySelectorAll('label[for="' + sel.id + '"]').forEach(function (l) { l.htmlFor = input.id; });
  }
  if (sel.getAttribute('aria-label')) input.setAttribute('aria-label', sel.getAttribute('aria-label'));
  const list = document.createElement('div');
  list.className = 'ss-list';
  list.setAttribute('role', 'listbox');
  wrap.appendChild(input);
  wrap.appendChild(list);

  let items = [], active = -1;
  function sync() {
    const o = sel.options[sel.selectedIndex];
    input.value = o && o.value ? o.text : '';
    input.placeholder = (o && !o.value) ? o.text : t('ss_ph');
  }
  function render(q) {
    q = (q || '').trim().toLowerCase();
    /* 排序：代码 / 区号完全一致 > 名称开头就对上 > 某个关键字开头对上 > 中间包含（搜 ger 时德国排在阿尔及利亚前面） */
    const score = function (o) {
      if (!q) return 0;
      const words = (o.text + ' ' + (o.dataset.kw || '')).toLowerCase().split(/[\s/]+/);
      if (words.indexOf(q) >= 0) return 1;
      if (o.text.toLowerCase().indexOf(q) === 0) return 2;
      if (words.some(function (w) { return w.indexOf(q) === 0; })) return 3;
      return (o.text + ' ' + (o.dataset.kw || '')).toLowerCase().indexOf(q) >= 0 ? 4 : 0;
    };
    items = [].filter.call(sel.options, function (o) { return o.value && (!q || score(o) > 0); });
    if (q) items.sort(function (a, b) { return score(a) - score(b); });
    list.innerHTML = items.length
      ? items.map(function (o, i) {
          return '<div class="ss-opt' + (o.value === sel.value ? ' sel' : '') + '" role="option" data-i="' + i + '">' + escapeHtml(o.text) + '</div>';
        }).join('')
      : '<div class="ss-empty">' + escapeHtml(t('ss_none')) + '</div>';
    active = -1;
  }
  function open() {
    /* 同一时间只开一个列表 */
    document.querySelectorAll('.ss-wrap.open').forEach(function (w) { if (w !== wrap && w._ssClose) w._ssClose(); });
    render('');
    wrap.classList.add('open');
    input.setAttribute('aria-expanded', 'true');
    input.value = '';
    input.placeholder = t('ss_ph');
    const cur = list.querySelector('.ss-opt.sel');
    if (cur) cur.scrollIntoView({ block: 'nearest' });
  }
  function close() {
    wrap.classList.remove('open');
    input.setAttribute('aria-expanded', 'false');
    sync();
  }
  function highlight(i) {
    const opts = list.querySelectorAll('.ss-opt');
    if (!opts.length) return;
    active = (i + opts.length) % opts.length;
    opts.forEach(function (el, k) { el.classList.toggle('active', k === active); });
    opts[active].scrollIntoView({ block: 'nearest' });
  }
  function choose(i) {
    const o = items[i];
    if (!o) return;
    const changed = sel.value !== o.value;
    sel.value = o.value;
    close();
    if (changed) sel.dispatchEvent(new Event('change', { bubbles: true }));   // 触发原来写在 select 上的 onchange
  }
  input.addEventListener('focus', open);
  input.addEventListener('click', function () { if (!wrap.classList.contains('open')) open(); });
  input.addEventListener('input', function () { render(input.value); wrap.classList.add('open'); if (items.length === 1) highlight(0); });
  input.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); if (!wrap.classList.contains('open')) open(); highlight(active + 1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); highlight(active - 1); }
    else if (e.key === 'Enter') { if (wrap.classList.contains('open')) { e.preventDefault(); choose(active >= 0 ? active : 0); } }
    else if (e.key === 'Escape') { close(); input.blur(); }
  });
  input.addEventListener('blur', function () { setTimeout(close, 120); });
  list.addEventListener('mousedown', function (e) {
    const el = e.target.closest('.ss-opt');
    e.preventDefault();                              // 不让输入框先失焦
    if (el) choose(Number(el.dataset.i));
  });
  sel.addEventListener('change', sync);
  sel._ssSync = sync;          // 代码里直接改 sel.value（不触发 change）后调用 syncSearchable 刷新显示
  wrap._ssClose = close;
  /* 选项被代码整体换掉（切科室后重填排班、切语言）时，显示的文字跟着更新 */
  new MutationObserver(sync).observe(sel, { childList: true });
  sync();
}

/* ============================================================
 * 按钮文字自适应：导航、页签、步骤条、常用科室这些「一格一个词」的地方，
 * 外文或大字版下可能放不下。先在一行里逐步缩小字号（最小到原来的六成、不小于 11px），
 * 还放不下才允许在空格处换行 —— 永远不在单词中间断开（不会出现 Upcomin / g）。
 * 页面内容变化、切语言、切大字版、窗口尺寸变化时自动重算。
 * ============================================================ */
/* 两种：一行放完的（导航、页签、步骤条……）先不换行地缩字号；
 * 允许多行的（常用科室格子）只在空格处换行，最长的那个词放不下时才缩字号 */
const FIT_ONE_LINE = ['.nav a span', '.center-tabs .btn', '#mineTabs .btn', '.progress-bar .step em', '.btn', '.staff-bar', '.logo'];
const FIT_MULTI_LINE = ['.dq'];
function fitLabels() {
  var fits = function (el) { return el.scrollWidth <= el.clientWidth + 1; };
  document.querySelectorAll(FIT_ONE_LINE.join(',')).forEach(function (el) {
    el.style.fontSize = '';
    el.style.whiteSpace = '';
    if (el.offsetParent === null || !el.clientWidth) return;
    el.style.whiteSpace = 'nowrap';
    var fs = parseFloat(getComputedStyle(el).fontSize);
    var min = Math.max(10, fs * 0.55);
    while (!fits(el) && fs > min) { fs -= 0.5; el.style.fontSize = fs + 'px'; }
    if (!fits(el)) el.style.whiteSpace = 'normal';    // 仍放不下：只在空格处换行（CSS 里 word-break: keep-all）
  });
  document.querySelectorAll(FIT_MULTI_LINE.join(',')).forEach(function (el) {
    el.style.fontSize = '';
    if (el.offsetParent === null || !el.clientWidth) return;
    var fs = parseFloat(getComputedStyle(el).fontSize);
    var min = Math.max(10, fs * 0.55);
    while (!fits(el) && fs > min) { fs -= 0.5; el.style.fontSize = fs + 'px'; }
  });
}
let fitPending = false;
function scheduleFit() {
  if (fitPending) return;
  fitPending = true;
  requestAnimationFrame(function () { fitPending = false; fitLabels(); });
}

function syncSearchable(id) {
  const el = document.getElementById(id);
  if (el && el._ssSync) el._ssSync();
}

function watchSearchableSelects() {
  const run = function () { document.querySelectorAll('select.searchable:not([data-enhanced])').forEach(enhanceSelect); };
  run();
  new MutationObserver(run).observe(document.body, { childList: true, subtree: true });
  /* 点在列表外面就收起（不只靠输入框失焦：有的触屏浏览器点空白处不会让输入框失焦） */
  document.addEventListener('mousedown', function (e) {
    document.querySelectorAll('.ss-wrap.open').forEach(function (w) { if (!w.contains(e.target) && w._ssClose) w._ssClose(); });
  });
  document.addEventListener('touchstart', function (e) {
    document.querySelectorAll('.ss-wrap.open').forEach(function (w) { if (!w.contains(e.target) && w._ssClose) w._ssClose(); });
  }, { passive: true });
}

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
  watchSearchableSelects();
  /* 内容变了（翻页、切语言、重画列表）或窗口尺寸变了，就重新给按钮文字算字号。
   * 只监听节点和文字变化，不监听属性 —— fitLabels 自己改的是 style 属性，不会触发死循环 */
  new MutationObserver(scheduleFit).observe(document.body, { childList: true, subtree: true, characterData: true });
  window.addEventListener('resize', scheduleFit);

  /* 先问服务端这台机器是不是按 IP 登记的自助机（没配置 HMS_KIOSK_IPS 时一律不是） */
  try {
    const m = await fetch('/api/client-mode').then(function (r) { return r.json(); });
    kioskByIp = !!(m && m.kiosk);
  } catch (e) { /* 拿不到就只看本机登记 */ }

  /* 自助机、或本人取消了「记住」：localStorage 里不该有就诊人信息，有就清掉 ——
   * 包括旧版本不分设备写进去的那些，公用电脑上残留的上一位病人信息从这一刻起就没了 */
  if (!rememberOn()) {
    PATIENT_KEYS.forEach(function (k) { try { localStorage.removeItem(k); } catch (e) {} });
  }
  bumpIdle();

  /* 语言：上次选的，或按浏览器语言 */
  LANG = detectLang();
  buildLangSelect();
  applyI18n();

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
    alert(t('e_network') + '\n\n' + e.message);
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

/* ---------- 语言切换 ---------- */
function buildLangSelect() {
  const sel = document.getElementById('langSel');
  if (!sel) return;
  sel.innerHTML = LANGS.map(function (l) {
    return '<option value="' + l[0] + '"' + (l[0] === LANG ? ' selected' : '') + '>' + l[1] + '</option>';
  }).join('');
}

function setLang(code) {
  LANG = code;
  const sel = document.getElementById('langSel');
  if (sel) sel.value = code;
  try { localStorage.setItem(LANG_KEY, code); } catch (e) { /* 记不住就只是下次还按浏览器语言 */ }
  applyI18n();
  /* 当前页按新语言重画（挂号向导停在原来那一步） */
  if (currentPage === 'booking') renderBookingStep();
  else showPage(currentPage);
}


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

/* 按编号找排班：号源面板里的数据在 allSchedules（按医生分组） */
function findSchedule(sid) {
  for (const docId in allSchedules) {
    const list = allSchedules[docId] || [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === sid) return Object.assign({ doctorId: docId }, list[i]);
    }
  }
  return null;
}

function openWaitlistForm(sid) {
  const s = findSchedule(sid);
  if (!s) return;

  wlScheduleId = sid;
  let doc = null;
  for (let i = 0; i < doctors.length; i++) { if (doctors[i].id === s.doctorId) doc = doctors[i]; }
  document.getElementById('wlWhy').textContent = t('wl_why', {
    when: s.date + ' ' + weekdayLabel(s.date) + ' ' + trPeriod(s.period),
    who: (doc ? deptName(doc.deptId) + ' ' + trDoctorName(doc) : ''),
  });

  const session = loadSession();
  document.getElementById('wlName').value = session.name || '';
  document.getElementById('wlDoc').innerHTML = docFieldsHtml('wl', session, true);
  document.getElementById('wlEmail').value = session.email || '';
  document.getElementById('wlTipErr').textContent = '';
  document.getElementById('wlMask').style.display = 'flex';
}

function closeWaitlistForm() {
  document.getElementById('wlMask').style.display = 'none';
}

async function submitWaitlist() {
  const err = document.getElementById('wlTipErr');
  const nm = readName('wlName');
  if (!nm.ok) { err.textContent = nm.msg; return; }
  const doc = readDoc('wl');
  if (!doc.ok) { err.textContent = doc.msg; return; }
  const ph = readPhone('wl');
  if (!ph.ok) { err.textContent = ph.msg; return; }
  const em = readEmail('wlEmail');
  if (!em.ok) { err.textContent = em.msg; return; }
  const patient = {
    name: nm.name, idType: doc.idType, nationality: doc.nationality, idCard: doc.idCard, docKey: doc.docKey, sex: doc.sex,
    phoneCc: ph.phoneCc, phone: ph.phone, email: em.email,
  };
  try {
    const r = await apiJoinWaitlist(wlScheduleId, patient);
    saveSession(patient);
    savePatientToHistory(patient);
    closeWaitlistForm();
    alert(t('wl_joined', { n: r.waitlist ? r.waitlist.position : '' }) + (r.notice ? '\n\n' + trError(r.notice) : ''));
    showPage('mine');
    switchMineTab('waitlist');
  } catch (e) {
    err.textContent = e.message;
  }
}

/* 「我的预约」里的「候补」页签 */
async function renderMyWaitlist() {
  const tip = document.getElementById('mineTip');
  const box = document.getElementById('mineList');
  const session = loadSession();
  box.innerHTML = '<p class="tip">' + t('loading') + '</p>';

  let list = [];
  try {
    list = await apiMyWaitlist(sessKey(session), true);
    if (mineTab !== 'waitlist') return;   /* 已切到别的页签 */
  } catch (e) {
    tip.textContent = '';
    box.innerHTML = '<p class="tip">' + t('load_fail') + escapeHtml(e.message) + '</p>';
    return;
  }

  myWlList = list;
  const live = list.filter(function (x) { return x.status === 'waiting' || x.status === 'offered'; });
  tip.textContent = t('wl_live', { a: live.length, b: list.length - live.length });
  if (list.length === 0) {
    box.innerHTML = '<p class="tip">' + t('wl_empty') + '</p>';
    return;
  }

  let html = '';
  for (let i = 0; i < list.length; i++) {
    const w = list[i];
    const offered = (w.status === 'offered');
    let tagCls = 'badge';
    if (offered || w.status === 'converted') tagCls = 'badge green';
    else if (w.status === 'waiting') tagCls = 'badge blue';
    else tagCls = 'badge grey';

    let actions = '';
    if (offered) {
      actions = `<button class="btn small primary" onclick="confirmWl('${w.id}')">${t('wl_confirm')}</button>
                 <button class="btn small" onclick="cancelWl('${w.id}')">${t('wl_giveup')}</button>`;
    } else if (w.status === 'waiting') {
      actions = `<button class="btn small" onclick="cancelWl('${w.id}')">${t('wl_leave')}</button>`;
    }

    html += '<div class="appt-card' + (offered ? ' wl-offer' : '') + '">'
      + '<div class="header"><span class="title">' + escapeHtml(deptName(w.deptId)) + ' · ' + escapeHtml(doctorName(w.doctorId)) + '</span>'
      + '<span class="' + tagCls + '">' + t('wl_s_' + w.status) + (w.status === 'waiting' ? ' · ' + t('wl_pos', { n: w.position }) : '') + '</span></div>'
      + '<div class="meta">' + escapeHtml(w.date + ' ' + weekdayLabel(w.date) + ' ' + trPeriod(w.period)) + ' · ' + money(w.fee) + '</div>'
      + '<div class="meta">' + t('f_patient') + colon() + escapeHtml(w.patientName) + ' · ' + escapeHtml(w.idCard)
      + ' · ' + (w.hasEmail ? t('wl_email_yes') : t('wl_email_no')) + '</div>'
      + (offered && w.offerExpiresAt ? '<div class="meta" style="color:#1f5e55">' + t('wl_keep', { t: fmtTime(w.offerExpiresAt) }) + '</div>' : '')
      + (actions ? '<div class="actions">' + actions + '</div>' : '')
      + '</div>';
  }
  box.innerHTML = html;
}

async function confirmWl(id) {
  if (!confirm(t('wl_confirm_q'))) return;
  try {
    const apt = await apiConfirmWaitlist(id);
    alert(t('wl_ok', { id: apt.id, seq: pad3(apt.seqNo) }));
  } catch (e) {
    alert(e.message);
  }
  renderMyWaitlist();
}

async function cancelWl(id) {
  if (!confirm(t('wl_cancel_q'))) return;
  try {
    await apiCancelWaitlist(id);
  } catch (e) {
    alert(e.message);
  }
  renderMyWaitlist();
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
    document.getElementById('captchaTip').textContent = t('cap_tip', { n: Math.round(c.ttl / 60) });
    document.getElementById('captchaAnswer').focus();
  } catch (e) {
    document.getElementById('captchaQuestion').textContent = t('cap_load_fail') + e.message;
  }
}

function submitCaptcha() {
  const answer = document.getElementById('captchaAnswer').value.trim();
  if (!answer) {
    alert(t('cap_fill'));
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
 * 十五（附）、管理端：病人资料
 *
 * 列表和详情默认脱敏。admin / auditor 点「查看完整」填理由后看明文，
 * 服务端写一条 access_log（view_patient）；admin / desk 可以改手机号和邮箱。
 * 姓名与证件是实名校验的依据，后台不改 —— 改了会和人口库对不上。
 * ============================================================ */

let ptDetail = null;   // 详情弹窗里当前这位病人

function idTypeLabel(p) {
  return t('idt_' + p.idType) + (p.nationality ? '（' + countryName(p.nationality) + '）' : '');
}
function phoneLabel(p) {
  return (p.phoneCc && p.phoneCc !== '86' ? '+' + p.phoneCc + ' ' : '') + p.phone;
}
function statusBadge(st) {
  return '<span class="badge ' + statusClass(st) + '">' + statusText(st) + '</span>';
}

function clearPatientFilters() {
  document.getElementById('ptKeyword').value = '';
  document.getElementById('ptType').value = '';
  renderPatients();
}

async function renderPatients() {
  const sel = document.getElementById('ptType');
  if (!sel.options.length) {
    sel.innerHTML = '<option value="">全部证件类型</option>'
      + ID_TYPES.map(function (k) { return '<option value="' + k + '">' + escapeHtml(t('idt_' + k)) + '</option>'; }).join('');
  }
  document.getElementById('ptNewBtn').style.display = canWrite() ? '' : 'none';
  const body = document.getElementById('ptBody');
  const count = document.getElementById('ptCount');
  body.innerHTML = '<tr><td colspan="8">加载中…</td></tr>';

  let list = [];
  try {
    list = await apiAdminPatients(document.getElementById('ptKeyword').value.trim(), sel.value);
  } catch (e) {
    body.innerHTML = '<tr><td colspan="8">加载失败：' + escapeHtml(e.message) + '</td></tr>';
    count.textContent = '';
    return;
  }
  if (adminTab !== 'patients') return;
  if (list.length === 0) {
    body.innerHTML = '<tr><td colspan="8">没有符合条件的病人</td></tr>';
    count.textContent = '';
    return;
  }

  let rows = '';
  for (let i = 0; i < list.length; i++) {
    const p = list[i];
    const st = p.blacklisted ? '<span class="badge orange">黑名单</span>'
      : (p.booked ? '<span class="badge green">待就诊 ' + p.booked + '</span>' : '—');
    rows += `
      <tr>
        <td><span class="tip">${escapeHtml(p.id)}</span></td>
        <td><b>${escapeHtml(p.name)}</b> <span class="tip">${sexLabel(p.sex)}</span></td>
        <td>${escapeHtml(idTypeLabel(p))}<br><span class="tip">${escapeHtml(p.idCard)}</span></td>
        <td>${escapeHtml(phoneLabel(p))}</td>
        <td>${p.total}（完成 ${p.completed} · 取消 ${p.cancelled} · 爽约 ${p.noShow}）</td>
        <td>${p.lastVisit || '—'}</td>
        <td>${st}</td>
        <td><button class="btn small" onclick="openPatientDetail('${p.id}')">详情</button></td>
      </tr>`;
  }
  body.innerHTML = rows;
  count.textContent = '共 ' + list.length + ' 位病人（最多显示 500 位，可用搜索缩小范围）';
}

async function openPatientDetail(id, reveal, reason) {
  document.getElementById('ptMask').style.display = 'flex';
  const info = document.getElementById('ptInfo');
  if (!reveal) {
    info.innerHTML = '<p class="tip">加载中…</p>';
    document.getElementById('ptActions').innerHTML = '';
    document.getElementById('ptAppts').innerHTML = '';
  }
  let p;
  try {
    p = await apiAdminPatient(id, reveal, reason);
  } catch (e) {
    if (reveal) { alert(e.message); return; }
    info.innerHTML = '<p class="form-error">' + escapeHtml(e.message) + '</p>';
    return;
  }
  ptDetail = p;
  renderPatientDetail(false);
}

function setPatientModalMode(title, showAppts) {
  document.getElementById('ptTitle').textContent = title;
  document.getElementById('ptApptsHead').style.display = showAppts ? '' : 'none';
  document.getElementById('ptApptsTable').style.display = showAppts ? '' : 'none';
}

function renderPatientDetail(editing) {
  const p = ptDetail;
  setPatientModalMode(editing ? '修改病人资料' : '病人资料', true);
  const row = function (k, v) { return '<p><b>' + k + '：</b>' + v + '</p>'; };
  let h = '<div class="detail">';
  if (editing) {
    /* 留空 = 不修改。脱敏状态下拿不到原值，所以手机号 / 邮箱 / 证件都默认不动，要改就整项重新填 */
    h += '<p><label for="peName">姓名</label><input id="peName" type="text" maxlength="50" value="' + escapeHtml(p.name) + '" /></p>';
    h += row('当前证件', escapeHtml(idTypeLabel(p)) + ' · ' + escapeHtml(p.idCard));
    h += '<p><label><input type="checkbox" id="peDocOn" onchange="document.getElementById(\'peDocBox\').style.display = this.checked ? \'\' : \'none\'" /> 修改证件</label></p>';
    h += '<div id="peDocBox" style="display:none">' + docFieldsHtml('pe', { idType: p.idType, nationality: p.nationality }, false) + '</div>';
    /* 性别：身份证 / 居住证跟着证件号走，不能单独改；其他证件可以改 */
    h += sexFieldHtml('pe', p.idType, p.sex);
    if (docHasSex(p.idType)) h += row('性别', sexLabel(p.sex) + '（按证件号自动判断）');
    h += row('当前手机号', escapeHtml(phoneLabel(p)));
    h += phoneFieldHtml('pe', { phoneCc: p.phoneCc, phone: '' });
    h += '<p class="tip">手机号留空表示不修改。</p>';
    h += row('当前邮箱', escapeHtml(p.email || '—'));
    h += '<p><label for="peEmail">新邮箱</label><input id="peEmail" type="text" placeholder="留空表示不修改" /></p>';
    if (p.email) h += '<p><label><input type="checkbox" id="peEmailClear" /> 清除邮箱（不再收邮件提醒）</label></p>';
    h += '<p class="tip">改姓名或证件会同步到实名校验库与黑名单，修改会记入访问日志。</p>';
    h += '<p class="form-error" id="peErr" role="alert"></p>';
  } else {
    h += row('姓名', '<b>' + escapeHtml(p.name) + '</b>' + (p.blacklisted ? ' <span class="badge orange">黑名单</span>' : ''));
    h += row('性别', sexLabel(p.sex));
    h += row('档案号', escapeHtml(p.id));
    h += row('证件', escapeHtml(idTypeLabel(p)) + ' · ' + escapeHtml(p.idCard));
    h += row('手机号', escapeHtml(phoneLabel(p)));
    h += row('邮箱', escapeHtml(p.email || '—'));
    h += row('建档时间', fmtTime(p.createdAt)
      + (p.updatedAt && p.updatedAt !== p.createdAt ? ' · 最近修改 ' + fmtTime(p.updatedAt) : ''));
    h += row('挂号统计', '共 ' + p.total + ' 次：待就诊 ' + p.booked + ' · 已完成 ' + p.completed
      + ' · 已取消 ' + p.cancelled + ' · 爽约 ' + p.noShow);
  }
  h += '</div>';
  if (p.masked && !editing) h += '<p class="tip">证件号、手机号、邮箱已脱敏。查看完整信息需要填写理由，并会记入访问日志。</p>';
  document.getElementById('ptInfo').innerHTML = h;

  let act = '';
  if (editing) {
    act += '<button class="btn" onclick="renderPatientDetail(false)">取消</button>';
    act += '<button class="btn primary" onclick="savePatientEdit()">保存</button>';
  } else {
    if (p.masked && (myRole() === 'admin' || myRole() === 'auditor')) {
      act += '<button class="btn" onclick="revealPatientDetail()">查看完整</button>';
    }
    if (canWrite()) act += '<button class="btn" onclick="renderPatientDetail(true)">修改资料</button>';
    if (myRole() === 'admin') act += '<button class="btn danger" onclick="deletePatient()">删除档案</button>';
  }
  document.getElementById('ptActions').innerHTML = act;

  let rows = '';
  const list = p.appointments || [];
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    rows += `
      <tr>
        <td><span class="tip">${escapeHtml(a.appointmentNo || a.id)}</span></td>
        <td>${escapeHtml(a.deptName)} · ${escapeHtml(a.doctorName)}</td>
        <td>${escapeHtml(a.date)} ${escapeHtml(a.period)}</td>
        <td>${fmtMoney(a.fee)}</td>
        <td>${statusBadge(a.status)}</td>
      </tr>`;
  }
  document.getElementById('ptAppts').innerHTML = rows || '<tr><td colspan="5">还没有挂号记录</td></tr>';
}

function revealPatientDetail() {
  const reason = prompt('查看完整病人信息需要填写理由（至少 2 个字）：\n例如：患者来电核对身份 / 窗口办理退费');
  if (reason === null) return;
  if (reason.trim().length < 2) { alert('理由至少 2 个字'); return; }
  openPatientDetail(ptDetail.id, true, reason.trim());
}

async function savePatientEdit() {
  const err = document.getElementById('peErr');
  err.textContent = '';
  const body = {};
  const nm = readName('peName');
  if (!nm.ok) { err.textContent = nm.msg; return; }
  if (nm.name !== ptDetail.name) body.name = nm.name;
  if (document.getElementById('peDocOn').checked) {
    const doc = readDoc('pe');
    if (!doc.ok) { err.textContent = doc.msg; return; }
    body.idType = doc.idType; body.nationality = doc.nationality; body.idCard = doc.idCard;
    if (doc.sex) body.sex = doc.sex;
  } else {
    const sx = document.getElementById('peSex').value;
    if (sx && sx !== ptDetail.sex && !docHasSex(ptDetail.idType)) body.sex = sx;
  }
  if (document.getElementById('pePhone').value.trim()) {
    const ph = readPhone('pe');
    if (!ph.ok) { err.textContent = ph.msg; return; }
    body.phoneCc = ph.phoneCc; body.phone = ph.phone;
  }
  const clear = document.getElementById('peEmailClear');
  if (clear && clear.checked) body.clearEmail = true;
  else if (document.getElementById('peEmail').value.trim()) {
    const em = readEmail('peEmail');
    if (!em.ok) { err.textContent = em.msg; return; }
    body.email = em.email;
  }
  if (!Object.keys(body).length) { err.textContent = '没有修改任何内容'; return; }
  try {
    await apiAdminPatientUpdate(ptDetail.id, body);
  } catch (e) {
    err.textContent = e.message;
    return;
  }
  alert('已保存');
  openPatientDetail(ptDetail.id);
  renderPatients();
}

/* 新建病人（窗口建档）：和挂号页同一套姓名 / 证件 / 手机号校验 */
function openPatientCreate() {
  ptDetail = null;
  document.getElementById('ptMask').style.display = 'flex';
  setPatientModalMode('新建病人', false);
  let h = '<div class="detail">';
  h += '<p><label for="pnName">姓名</label><input id="pnName" type="text" maxlength="50" placeholder="与证件一致的姓名" /></p>';
  h += docFieldsHtml('pn', {}, true);
  h += '<p><label for="pnEmail">邮箱</label><input id="pnEmail" type="text" placeholder="选填，用于就诊提醒" /></p>';
  h += '<p class="tip">证件已有档案时不会重复建档；姓名会登记为该证件的实名信息。</p>';
  h += '<p class="form-error" id="pnErr" role="alert"></p></div>';
  document.getElementById('ptInfo').innerHTML = h;
  document.getElementById('ptActions').innerHTML =
    '<button class="btn" onclick="closePatientDetail()">取消</button>'
    + '<button class="btn primary" onclick="savePatientCreate()">建档</button>';
}

async function savePatientCreate() {
  const err = document.getElementById('pnErr');
  err.textContent = '';
  const nm = readName('pnName');
  if (!nm.ok) { err.textContent = nm.msg; return; }
  const doc = readDoc('pn');
  if (!doc.ok) { err.textContent = doc.msg; return; }
  const ph = readPhone('pn');
  if (!ph.ok) { err.textContent = ph.msg; return; }
  const em = readEmail('pnEmail');
  if (!em.ok) { err.textContent = em.msg; return; }
  let r;
  try {
    r = await apiAdminPatientCreate({ name: nm.name, idType: doc.idType, nationality: doc.nationality,
      idCard: doc.idCard, sex: doc.sex, phoneCc: ph.phoneCc, phone: ph.phone, email: em.email });
  } catch (e) {
    err.textContent = e.message;
    return;
  }
  renderPatients();
  openPatientDetail(r.id);
}

/* 删除档案：仅管理员，必须填理由。待就诊的号先退掉（号源归还、候补补位），再删全部记录 */
async function deletePatient() {
  const p = ptDetail;
  let warn = '确定删除「' + p.name + '」的档案吗？此操作不能撤销。\n\n将删除：档案、全部 ' + p.total + ' 条挂号记录、候补和登录凭证。';
  if (p.booked) warn += '\n其中 ' + p.booked + ' 个待就诊的号会先退号，号源归还给其他患者。';
  warn += '\n黑名单与访问日志会保留。';
  if (!confirm(warn)) return;
  const reason = prompt('请填写删除理由（至少 2 个字，会记入访问日志）：');
  if (reason === null) return;
  if (reason.trim().length < 2) { alert('理由至少 2 个字'); return; }
  try {
    await apiAdminPatientDelete(p.id, reason.trim());
  } catch (e) {
    alert(e.message);
    return;
  }
  alert('已删除');
  closePatientDetail();
  renderPatients();
}

function closePatientDetail() {
  document.getElementById('ptMask').style.display = 'none';
  ptDetail = null;
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
    if (!keep[s.date] || s.closed || s.ended || s.remain <= 0) continue;
    opts += '<option value="' + s.id + '">'
      + s.date + ' ' + s.period + ' · ' + doctorName(s.doctorId)
      + '（余 ' + s.remain + '）</option>';
    n = n + 1;
  }
  if (n === 0) opts = '<option value="">该科室未来 7 天没有可约号源</option>';
  sel.innerHTML = opts;
  remain.textContent = n > 0 ? '可选时段 ' + n + ' 个' : '';
}

let proxyBookingPending = false;
async function bookWithCaptcha(scheduleId, patient, mode) {
  if (mode === 'proxy' && proxyBookingPending) return { ok: false, cancelled: true };
  if (mode === 'proxy') proxyBookingPending = true;
  let captcha = null;
  try {
    while (true) {
      try {
        const api = mode === 'proxy' ? apiProxyBooking : apiCreateAppointment;
        const apt = await api(scheduleId, patient, captcha ? captcha.token : '', captcha ? captcha.answer : '');
        return { ok: true, apt: apt };
      } catch (e) {
        if (e.code !== 'CAPTCHA_REQUIRED') return { ok: false, message: e.message };
        document.getElementById('captchaWhy').textContent = t('captcha_why', { n: (e.data && e.data.remain) || '…' });
        captcha = await openCaptcha();
        if (!captcha) return { ok: false, cancelled: true };
      }
    }
  } finally {
    if (mode === 'proxy') proxyBookingPending = false;
  }
}

async function submitProxy() {
  const sid = document.getElementById('pxSchedule').value;
  const tip = document.getElementById('proxyTip');
  if (!sid) { alert('请先选一个时段'); return; }
  const nm = readName('pxName');
  if (!nm.ok) { alert(nm.msg); return; }
  const doc = readDoc('px');
  if (!doc.ok) { alert(doc.msg); return; }
  const ph = readPhone('px');
  if (!ph.ok) { alert(ph.msg); return; }
  const em = readEmail('pxEmail');
  if (!em.ok) { alert(em.msg); return; }

  const done = await bookWithCaptcha(sid, {
    name: nm.name, idType: doc.idType, nationality: doc.nationality, idCard: doc.idCard, sex: doc.sex,
    phoneCc: ph.phoneCc, phone: ph.phone, email: em.email,
  }, 'proxy');

  if (!done.ok) {
    if (!done.cancelled) alert(done.message);
    return;
  }

  tip.textContent = '已代约：' + done.apt.id + '（取号序号 ' + pad3(done.apt.seqNo)
    + ' 号）· 审计日志已记成「代约:工号」';
  document.getElementById('pxName').value = '';
  document.getElementById('pxDoc').innerHTML = docFieldsHtml('px', {}, true);
  document.getElementById('pxEmail').value = '';
  proxyDeptChange();
}

/* 代约走 /api/admin/proxy-booking（审计记「代约:工号」），
 * 封装在 apiProxyBooking 里，由 bookWithCaptcha 的 mode='proxy' 选路。 */


/* ---------- 访问日志 ---------- */
const ACTION_LABEL = {
  reveal_idcard: '查看完整身份证',
  view_patient: '查看患者档案',
  create_patient: '新建病人档案',
  edit_patient: '修改病人资料',
  delete_patient: '删除病人档案',
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
  scheduleFit();

  const btn = document.getElementById('fontToggle');
  if (btn) {
    const key = on ? 'normal_font' : 'big_font';
    btn.innerHTML = '<span data-i18n="' + key + '">' + t(key) + '</span>';
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
