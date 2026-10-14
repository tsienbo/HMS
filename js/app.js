/* ============================================================
 * 智慧医院预约挂号系统 —— 前端全部代码
 *
 * 整个前端就这一个文件，从上往下读就行，一共十二节：
 *   一、写死的常量
 *   二、全局变量
 *   三、小工具（日期、金额、转义）
 *   四、浏览器本地存的两样东西
 *   五、跟后端打交道
 *   六、页面切换
 *   七、登录 / 注销
 *   八、患者端：挂号 4 步
 *   九、患者端：我的挂号
 *   十、管理端：挂号记录
 *   十一、管理端：排班号源
 *   十二、启动
 *
 * 写法约定：
 *   · 不用 .map / .filter / .find / .reduce，一律写 for 循环
 *   · 要判断就写 if / else，不写嵌套的三元表达式
 *   · 拼 HTML 用模板字符串，但里面不再套模板字符串、不再套三元
 *   · 所有函数都写在全局，index.html 里的 onclick="xxx()" 才能直接调到
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
  return { name: '', idCard: '', phone: '' };
}

function saveSession(s) {
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify(s));
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
async function request(method, url, body) {
  const opt = { method: method, headers: {} };

  if (body) {
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  if (token) {
    opt.headers.Authorization = 'Bearer ' + token;
  }

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
    if (data && data.error) throw new Error(data.error);
    throw new Error('请求失败（HTTP ' + res.status + '）');
  }
  return data;
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

async function apiCreateAppointment(scheduleId, patient) {
  return request('POST', '/appointments', { scheduleId: scheduleId, patient: patient });
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
  const pages = ['home', 'mine', 'admin', 'login'];

  for (let i = 0; i < pages.length; i++) {
    const el = document.getElementById('page-' + pages[i]);
    if (pages[i] === name) el.style.display = '';
    else el.style.display = 'none';
  }

  /* 顶栏高亮当前这一项 */
  document.getElementById('navHome').className = (name === 'home') ? 'on' : '';
  document.getElementById('navMine').className = (name === 'mine') ? 'on' : '';
  document.getElementById('navAdmin').className = (name === 'admin') ? 'on' : '';

  if (name === 'mine') renderMine();
  window.scrollTo(0, 0);
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

/* 顶栏右上角：登录了就显示是谁，没登录就空着 */
function showLoginInfo() {
  const el = document.getElementById('loginInfo');
  if (currentUser) el.textContent = currentUser.displayName + '（管理员）';
  else el.textContent = '';
}


/* ============================================================
 * 八、患者端：挂号 4 步
 *
 * 每一步的 HTML 都写在 index.html 里（step1 ~ step4），
 * 这里只负责「算出该显示哪一步」和「把列表填进去」。
 * ============================================================ */

/* ---------- 只显示某一步 ---------- */
function showStep(n) {
  step = n;
  document.getElementById('step1').style.display = (n === 1) ? '' : 'none';
  document.getElementById('step2').style.display = (n === 2) ? '' : 'none';
  document.getElementById('step3').style.display = (n === 3) ? '' : 'none';
  document.getElementById('step4').style.display = (n === 4) ? '' : 'none';
  document.getElementById('successBox').style.display = (n === 5) ? '' : 'none';
}

/* ---------- 回到第 1 步（首页 / Logo / 继续挂号 都走这里） ---------- */
function goHome() {
  deptId = '';
  doctorId = '';
  date = '';
  period = '';
  scheduleId = '';
  currentSchedules = [];

  showPage('home');
  showStep(1);
  renderStep1();
}

/* ---------- 第 1 步：选科室 ---------- */
function renderStep1() {
  document.getElementById('homeTitle').textContent = '选择就诊科室';
  document.getElementById('homeTip').textContent =
    HOSPITAL.name + ' · 共 ' + departments.length + ' 个科室开放预约';

  let html = '';
  for (let i = 0; i < departments.length; i++) {
    const d = departments[i];
    html += `
      <div class="card" onclick="pickDept('${d.id}')">
        <div class="card-title">${deptIcon(d.id)} ${escapeHtml(d.name)}</div>
        <div class="tip">${escapeHtml(d.desc)}</div>
        <div class="tip">${doctorsOf(d.id).length} 位医生</div>
      </div>
    `;
  }
  document.getElementById('deptList').innerHTML = html;
}

/* 点了某个科室 → 进入第 2 步 */
async function pickDept(id) {
  try {
    deptId = id;
    doctorId = '';
    date = '';
    period = '';
    scheduleId = '';

    showPage('home');
    showStep(2);
    await renderStep2();
  } catch (e) {
    alert(e.message);
  }
}

/* ---------- 第 2 步：选医生 ---------- */
async function renderStep2() {
  /* remain 由后端算好返回，0 表示这位医生近 7 天都没号了 */
  const list = await apiDeptDoctors(deptId);

  document.getElementById('homeTitle').textContent = '选择接诊医生';
  document.getElementById('homeTip').textContent = deptName(deptId) + ' · 点击医生查看可约时段';

  let html = '';
  for (let i = 0; i < list.length; i++) {
    const d = list[i];
    const soldOut = (d.remain === 0);

    let cls = 'card';
    let click = `onclick="pickDoctor('${d.id}')"`;
    let feeLine = '挂号费 ' + money(d.fee) + ' · 剩 ' + d.remain + ' 号';

    if (soldOut) {
      cls = 'card disabled';
      click = '';
      feeLine = '挂号费 ' + money(d.fee) + ' · 已约满';
    }

    html += `
      <div class="${cls}" ${click}>
        <div class="card-title">${escapeHtml(d.name)}
          <span class="tag">${escapeHtml(d.title)}</span></div>
        <div class="tip">擅长：${escapeHtml(doctorIntro(d.id))}</div>
        <div class="tip">${feeLine}</div>
      </div>
    `;
  }
  document.getElementById('doctorList').innerHTML = html;
}

/* 点了某位医生 → 进入第 3 步 */
async function pickDoctor(id) {
  try {
    doctorId = id;
    date = '';
    period = '';
    scheduleId = '';

    showPage('home');
    showStep(3);
    await loadSchedules();
  } catch (e) {
    alert(e.message);
  }
}

/* 从第 3 步返回第 2 步 */
async function backToDoctors() {
  try {
    showStep(2);
    await renderStep2();
  } catch (e) {
    alert(e.message);
  }
}

/* ---------- 第 3 步：选日期与上午 / 下午 ---------- */

/* 某一天还剩多少号（该天所有没停诊的排班加起来） */
function dayRemain(d) {
  let sum = 0;
  for (let i = 0; i < currentSchedules.length; i++) {
    const s = currentSchedules[i];
    if (s.date === d && !s.closed) sum = sum + s.remain;
  }
  return sum;
}

async function loadSchedules() {
  currentSchedules = await apiDoctorSchedules(doctorId, 7);

  /* 默认选中第一个有号的日期 */
  const days = buildDateRange(7);
  if (!date || dayRemain(date) === 0) {
    date = days[0].date;
    for (let i = 0; i < days.length; i++) {
      if (dayRemain(days[i].date) > 0) {
        date = days[i].date;
        break;
      }
    }
  }

  document.getElementById('homeTitle').textContent = '选择就诊时间';
  document.getElementById('homeTip').textContent =
    doctorName(doctorId) + ' · ' + doctorTitle(doctorId) + ' · 挂号费 ' + money(doctorFee(doctorId));

  renderDates();
  renderPeriods();
}

/* 日期那一排按钮 */
function renderDates() {
  const days = buildDateRange(7);
  let html = '';

  for (let i = 0; i < days.length; i++) {
    const d = days[i];
    const remain = dayRemain(d.date);

    let cls = 'date';
    if (d.date === date) cls = cls + ' on';

    let click = `onclick="pickDate('${d.date}')"`;
    let label = '余' + remain;

    if (remain === 0) {
      cls = cls + ' off';
      click = 'disabled';
      label = '无号';
    }

    html += `
      <button class="${cls}" ${click}>
        <b>${d.weekday}</b>
        <span>${d.month}/${d.day}</span>
        <span>${label}</span>
      </button>
    `;
  }
  document.getElementById('dateList').innerHTML = html;
}

/* 上午 / 下午两块。号源的最小单位就是它们。 */
function renderPeriods() {
  /* 先挑出这一天的、没停诊的排班 */
  const list = [];
  for (let i = 0; i < currentSchedules.length; i++) {
    const s = currentSchedules[i];
    if (s.date === date && !s.closed) list.push(s);
  }

  if (list.length === 0) {
    document.getElementById('periodList').innerHTML = '';
    document.getElementById('periodEmpty').style.display = '';
    return;
  }

  document.getElementById('periodEmpty').style.display = 'none';

  /* 上午排在下午前面 */
  list.sort(function (a, b) {
    if (a.period === '上午') return -1;
    return 1;
  });

  let html = '';
  for (let i = 0; i < list.length; i++) {
    const s = list[i];
    const full = (s.remain === 0);

    let cls = 'card';
    let click = `onclick="pickPeriod('${s.id}')"`;
    let tip = '剩余号源 ' + s.remain + ' 个';

    if (full) {
      cls = 'card disabled';
      click = '';
      tip = '已约满';
    }

    html += `
      <div class="${cls}" ${click}>
        <div class="card-title">${s.period}
          <span class="tip">${periodRange(s.period)}</span></div>
        <div class="tip">${tip}</div>
      </div>
    `;
  }
  document.getElementById('periodList').innerHTML = html;
}

/* 换一天：只重画日期按钮和上下午两块，不用重新请求后端 */
function pickDate(d) {
  date = d;
  period = '';
  scheduleId = '';
  renderDates();
  renderPeriods();
}

/* 点了上午或下午 → 进入第 4 步 */
function pickPeriod(sid) {
  let sc = null;
  for (let i = 0; i < currentSchedules.length; i++) {
    if (currentSchedules[i].id === sid) {
      sc = currentSchedules[i];
      break;
    }
  }
  if (!sc) return;

  period = sc.period;
  scheduleId = sc.id;
  showStep(4);
  renderStep4();
}

/* 从第 4 步返回第 3 步 */
function backToPeriods() {
  showStep(3);
  renderDates();
  renderPeriods();
}

/* ---------- 第 4 步：确认挂号 ---------- */
function renderStep4() {
  const session = loadSession();

  document.getElementById('cHospital').textContent = HOSPITAL.name;
  document.getElementById('cDept').textContent = deptName(deptId);
  document.getElementById('cDoctor').textContent = doctorName(doctorId) + ' · ' + doctorTitle(doctorId);
  document.getElementById('cDate').textContent = date + ' ' + weekdayLabel(date);
  document.getElementById('cPeriod').textContent = period + '（' + periodRange(period) + '）';
  document.getElementById('cFee').textContent = money(doctorFee(doctorId));

  /* 上次填过的就诊人信息，帮用户填好 */
  const nameEl = document.getElementById('pName');
  const idEl = document.getElementById('pIdCard');
  const phoneEl = document.getElementById('pPhone');
  if (!nameEl.value) nameEl.value = session.name || '';
  if (!idEl.value) idEl.value = session.idCard || '';
  if (!phoneEl.value) phoneEl.value = session.phone || '';
}

/* ---------- 提交挂号 ----------
 * 前端只检查「有没有填」，身份证和手机号的合法性由服务端判断 ——
 * 前端校验只是让人少跑一趟，服务端必须自己再校验一次。 */
async function submitBooking() {
  const name = document.getElementById('pName').value.trim();
  const idCard = document.getElementById('pIdCard').value.trim();
  const phone = document.getElementById('pPhone').value.trim();

  if (!name || !idCard || !phone) {
    alert('请把姓名、身份证号、手机号都填上');
    return;
  }

  try {
    const apt = await apiCreateAppointment(scheduleId, { name: name, idCard: idCard, phone: phone });
    saveSession({ name: name, idCard: idCard, phone: phone });
    showSuccess(apt);
  } catch (e) {
    /* 号源被抢光、身份证格式不对等等，服务端返回的中文提示直接弹出来 */
    alert(e.message);
  }
}

/* 挂号成功，把单子填进 #successBox */
function showSuccess(apt) {
  document.getElementById('sId').textContent = apt.id;
  document.getElementById('sSeq').textContent = pad3(apt.seqNo) + ' 号';
  document.getElementById('sTime').textContent = apt.date + ' ' + apt.weekday + ' ' + apt.period;
  document.getElementById('sDoc').textContent = deptName(apt.deptId) + ' · ' + doctorName(apt.doctorId);
  document.getElementById('sFee').textContent = money(apt.fee);
  showStep(5);
}


/* ============================================================
 * 九、患者端：我的挂号
 *
 * 只显示「待就诊」。已经取消 / 被停诊退号的记录不再列出来，
 * 所以页面上没有状态筛选，也不需要显示状态徽章。
 * ============================================================ */

async function renderMine() {
  const tip = document.getElementById('mineTip');
  const empty = document.getElementById('mineEmpty');
  const box = document.getElementById('mineList');

  /* 没有就诊人身份证号 = 本机没挂过号，不显示任何人的数据 */
  const session = loadSession();
  if (!session.idCard) {
    tip.textContent = '';
    empty.textContent = '本机还没记录就诊人信息，挂一次号就能在这里看到。';
    empty.style.display = '';
    box.innerHTML = '';
    return;
  }

  let all = [];
  try {
    all = await apiAppointments({ idCard: session.idCard });
  } catch (e) {
    tip.textContent = '';
    empty.textContent = '加载失败：' + e.message;
    empty.style.display = '';
    box.innerHTML = '';
    return;
  }

  /* 后端按时间正序返回，最新的放最前面；再只留待就诊 */
  const list = [];
  for (let i = all.length - 1; i >= 0; i--) {
    if (all[i].status === 'active') list.push(all[i]);
  }

  mineList = list;
  tip.textContent = '待就诊 ' + list.length + ' 条';
  empty.style.display = 'none';

  if (list.length === 0) {
    empty.textContent = '暂无待就诊挂号。';
    empty.style.display = '';
    box.innerHTML = '';
    return;
  }

  let html = '';
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    html += `
      <div class="card">
        <div class="card-title">
          ${a.date} ${a.weekday} ${a.period}
          <span class="tag green">待就诊</span>
        </div>
        <div class="tip">${HOSPITAL.name} · ${deptName(a.deptId)} · ${doctorName(a.doctorId)} ${doctorTitle(a.doctorId)}</div>
        <div class="tip">就诊人：${escapeHtml(a.patientName)} · 取号序号 ${pad3(a.seqNo)} 号 · ${money(a.fee)}</div>
        <div class="tip">挂号单号：${a.id}</div>
        <button class="btn" onclick="cancelMine('${a.id}')">取消挂号</button>
      </div>
    `;
  }
  box.innerHTML = html;
}

/* 取消挂号。只凭单号就能退 —— 单号在页面上，不用再输身份证。 */
async function cancelMine(id) {
  let apt = null;
  for (let i = 0; i < mineList.length; i++) {
    if (mineList[i].id === id) {
      apt = mineList[i];
      break;
    }
  }

  let what = id;
  if (apt) what = apt.date + ' ' + apt.period + ' ' + deptName(apt.deptId) + ' ' + doctorName(apt.doctorId);

  if (!confirm('确认取消这条挂号？\n\n' + what + '\n\n号源会立即释放给其他患者。')) return;

  try {
    await apiCancelAppointment(id);
    alert('已取消挂号');
    renderMine();
  } catch (e) {
    alert(e.message);
  }
}


/* ============================================================
 * 十、管理端：挂号记录
 *
 * 进这个页面必须先登录。前端只是「没登录就跳到登录页」，
 * 真正的拦截在服务端：就算直接去调 /api/appointments 也会拿到 401。
 * ============================================================ */

/* ---------- 切子页签 ---------- */
function showAdminTab(tab) {
  adminTab = tab;

  document.getElementById('tabRecords').className = 'btn';
  document.getElementById('tabSchedules').className = 'btn';
  document.getElementById('panel-records').style.display = 'none';
  document.getElementById('panel-schedules').style.display = 'none';

  if (tab === 'records') {
    document.getElementById('tabRecords').className = 'btn on';
    document.getElementById('adminTip').textContent = '挂号记录（含已取消、已停诊）';
    document.getElementById('panel-records').style.display = '';
    renderRecords();
  } else {
    document.getElementById('tabSchedules').className = 'btn on';
    document.getElementById('adminTip').textContent = '排班号源 · 一天两条（上午 / 下午）';
    document.getElementById('panel-schedules').style.display = '';
    renderSchedules();
  }
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
      if (a.status === 'active') statusCls = 'tag green';

      let op = '—';
      if (a.status === 'active') {
        op = `<button class="btn small" onclick="adminCancel('${a.id}')">退号</button>`;
      }

      rows += `
        <tr>
          <td>${a.id}</td>
          <td>${escapeHtml(a.patientName)}<br><span class="tip">${escapeHtml(a.phone)}</span></td>
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
  count.textContent = '共 ' + list.length + ' 条记录';
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

/* 状态中文名 */
function statusText(status) {
  if (status === 'active') return '待就诊';
  if (status === 'cancelled') return '已取消';
  if (status === 'closed') return '已停诊';
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
 * 十一、管理端：排班号源
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
          <div class="actions">
            <button class="btn small" onclick="changeQuota('${s.id}', ${s.quotaTotal - 1})">−</button>
            <input class="qty" type="number" min="${s.quotaBooked}" value="${s.quotaTotal}"
                   onchange="changeQuota('${s.id}', this.value)" />
            <button class="btn small" onclick="changeQuota('${s.id}', ${s.quotaTotal + 1})">＋</button>
            <button class="btn small" onclick="toggleSchedule('${s.id}')">${toggleText}</button>
          </div>
        </div>
      `;
    }
  }
  cards.innerHTML = cardHtml;

  count.textContent = '共 ' + list.length + ' 条排班 · 点 −/＋ 或直接改数字可以调号源总量';
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
 * 十二、启动
 * ============================================================ */

window.onload = async function () {
  /* 1. 科室和医生只拉这一次，后面都从全局变量里读 */
  try {
    departments = await apiDepartments();
    doctors = await apiDoctors();
  } catch (e) {
    alert('连不上服务器：' + e.message + '\n\n请确认后端已经启动（在项目目录执行 npm start），然后刷新本页。');
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
