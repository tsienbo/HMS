/* ============================================================
 * 多语言（患者端）
 *
 * 面向外国留学生、港澳台居民等就诊人：患者能看到的界面文字都在这里，
 * 一行一个词条，九种语言按 LANGS 的顺序排列。管理后台给院内工作人员用，保持中文。
 *
 *   t('key')                 取当前语言的文字，缺失时退回中文
 *   t('key', {n: 3})         {n} 这样的占位符会被替换
 *   applyI18n()              把页面上带 data-i18n / data-i18n-ph / data-i18n-title 的元素换成当前语言
 *
 * 加一种语言：LANGS 末尾加一项，每个词条末尾加一列，缺的列会自动显示中文。
 * ============================================================ */

const LANGS = [
  ['zh', '简体中文', 'zh-CN'],
  ['en', 'English', 'en'],
  ['ja', '日本語', 'ja'],
  ['ko', '한국어', 'ko'],
  ['ru', 'Русский', 'ru'],
  ['es', 'Español', 'es'],
  ['fr', 'Français', 'fr'],
  ['th', 'ไทย', 'th'],
  ['vi', 'Tiếng Việt', 'vi'],
];
const LANG_KEY = 'hms_lang';

/*            zh / en / ja / ko / ru / es / fr / th / vi */
const I18N = {
  /* ---------- 顶栏与导航 ---------- */
  brand: ["智慧医院挂号平台", "Smart Hospital Booking", "スマート病院予約", "스마트 병원 예약", "Запись в больницу", "Citas del hospital", "Rendez-vous à l'hôpital", "จองคิวโรงพยาบาล", "Đặt lịch khám bệnh viện"],
  nav_home: ["首页", "Home", "ホーム", "홈", "Главная", "Inicio", "Accueil", "หน้าแรก", "Trang chủ"],
  nav_booking: ["挂号", "Book", "予約", "예약", "Запись", "Cita", "Rendez-vous", "จองคิว", "Đặt lịch"],
  nav_center: ["个人中心", "My account", "マイページ", "마이페이지", "Кабинет", "Mi cuenta", "Mon compte", "บัญชีของฉัน", "Tài khoản"],
  nav_admin: ["后台管理", "Staff", "職員用", "직원용", "Персонал", "Personal", "Personnel", "เจ้าหน้าที่", "Nhân viên"],
  big_font: ["大字版", "Large text", "大きな文字", "큰 글씨", "Крупный шрифт", "Texto grande", "Grand texte", "ตัวอักษรใหญ่", "Chữ lớn"],
  normal_font: ["标准字号", "Normal text", "標準の文字", "기본 글씨", "Обычный шрифт", "Texto normal", "Texte normal", "ตัวอักษรปกติ", "Chữ thường"],
  big_font_title: ["把全站字号放大一档", "Make all text larger", "文字を大きくする", "글씨를 크게 표시", "Увеличить шрифт", "Aumentar el texto", "Agrandir le texte", "ขยายตัวอักษร", "Phóng to chữ"],
  logout: ["退出登录", "Log out", "ログアウト", "로그아웃", "Выйти", "Cerrar sesión", "Déconnexion", "ออกจากระบบ", "Đăng xuất"],
  language: ["语言", "Language", "言語", "언어", "Язык", "Idioma", "Langue", "ภาษา", "Ngôn ngữ"],

  /* ---------- 首页 ---------- */
  hospital_sub: ["三级甲等 · 市第一人民医院", "Grade 3A · City First People's Hospital", "三級甲等 · 市第一人民病院", "3급 갑등 · 시 제일인민병원", "Высшая категория · Первая городская больница", "Nivel 3A · Primer Hospital Popular de la Ciudad", "Catégorie 3A · Premier hôpital populaire de la ville", "ระดับ 3A · โรงพยาบาลประชาชนแห่งที่หนึ่งของเมือง", "Hạng 3A · Bệnh viện Nhân dân số 1 Thành phố"],
  book_now: ["立即挂号", "Book now", "今すぐ予約", "지금 예약", "Записаться", "Pedir cita", "Prendre rendez-vous", "จองคิวเลย", "Đặt lịch ngay"],
  call_book: ["电话预约", "Book by phone", "電話で予約", "전화 예약", "Запись по телефону", "Cita por teléfono", "Rendez-vous par téléphone", "จองทางโทรศัพท์", "Đặt qua điện thoại"],
  call_tip: ["不会操作智能手机？点上方按钮直接拨打，由工作人员代约，或让子女帮忙操作。", "Need help? Tap the button above to call — our staff can book for you.", "操作が難しい場合は、上のボタンから電話してください。スタッフが代わりに予約します。", "도움이 필요하면 위 버튼으로 전화하세요. 직원이 대신 예약해 드립니다.", "Нужна помощь? Позвоните по кнопке выше — сотрудники запишут вас.", "¿Necesita ayuda? Pulse el botón para llamar y el personal le dará la cita.", "Besoin d'aide ? Appuyez sur le bouton pour appeler, le personnel réservera pour vous.", "ต้องการความช่วยเหลือ? กดปุ่มด้านบนเพื่อโทร เจ้าหน้าที่จะจองให้คุณ", "Cần hỗ trợ? Bấm nút phía trên để gọi, nhân viên sẽ đặt lịch giúp bạn."],
  home_depts: ["常用科室", "Common departments", "主な診療科", "주요 진료과", "Основные отделения", "Departamentos frecuentes", "Services courants", "แผนกที่ใช้บ่อย", "Khoa thường dùng"],
  all_depts: ["更多", "More", "その他", "더보기", "Ещё", "Más", "Plus", "เพิ่มเติม", "Thêm"],
  notes_h: ["就诊须知", "Before your visit", "受診のご案内", "진료 안내", "Перед визитом", "Antes de su visita", "Avant votre visite", "ข้อควรทราบก่อนพบแพทย์", "Lưu ý khi khám"],
  n_hours: ["门诊时间：上午 8:00–12:00，下午 13:30–17:00", "Clinic hours: 8:00–12:00 and 13:30–17:00", "診療時間：午前 8:00–12:00、午後 13:30–17:00", "진료 시간: 오전 8:00–12:00, 오후 13:30–17:00", "Часы приёма: 8:00–12:00 и 13:30–17:00", "Horario: 8:00–12:00 y 13:30–17:00", "Horaires : 8 h–12 h et 13 h 30–17 h", "เวลาทำการ: 8:00–12:00 และ 13:30–17:00", "Giờ khám: 8:00–12:00 và 13:30–17:00"],
  n_doc: ["就诊当天请携带挂号时填写的证件（身份证、护照等）", "Bring the ID you booked with (ID card, passport, etc.)", "予約時に入力した身分証（パスポート等）をご持参ください", "예약 시 입력한 신분증(여권 등)을 지참하세요", "Возьмите документ, указанный при записи (паспорт и т. п.)", "Traiga el documento con el que reservó (pasaporte, etc.)", "Apportez la pièce d'identité utilisée pour réserver (passeport, etc.)", "โปรดนำเอกสารที่ใช้จอง (บัตรประชาชน หนังสือเดินทาง ฯลฯ) มาด้วย", "Mang theo giấy tờ đã dùng khi đặt lịch (CCCD, hộ chiếu…)"],
  n_limit: ["同一就诊人同一天最多预约 2 个号", "Up to 2 appointments per patient per day", "1 人 1 日 2 件まで予約できます", "1인 1일 최대 2건까지 예약할 수 있습니다", "Не более 2 записей в день на одного пациента", "Máximo 2 citas por paciente al día", "2 rendez-vous maximum par patient et par jour", "ผู้ป่วยหนึ่งคนจองได้สูงสุด 2 คิวต่อวัน", "Mỗi người bệnh tối đa 2 lượt mỗi ngày"],
  n_wait: ["号满可排候补，有人退号会通知你，号源为你保留 2 小时", "If full, join the waitlist — we'll notify you and hold the slot for 2 hours", "満員の場合はキャンセル待ちへ。空きが出たら通知し、2 時間確保します", "마감 시 대기 신청하면 취소 발생 시 알려 드리고 2시간 동안 자리를 보류합니다", "Если мест нет, встаньте в лист ожидания — мы сообщим и придержим место 2 часа", "Si está completo, únase a la lista de espera: le avisaremos y guardaremos la plaza 2 horas", "Si c'est complet, inscrivez-vous en liste d'attente : nous vous prévenons et gardons la place 2 h", "หากคิวเต็ม ลงชื่อรอได้ เมื่อมีคนยกเลิกจะแจ้งและเก็บคิวไว้ให้ 2 ชั่วโมง", "Hết chỗ có thể đăng ký chờ; khi có người hủy sẽ báo và giữ chỗ 2 giờ"],
  n_cancel: ["不能就诊请提前取消；30 天内取消 5 次或 180 天内爽约 3 次，将暂停线上挂号", "Cancel in advance if you can't come. 5 cancellations in 30 days or 3 no-shows in 180 days suspends online booking", "来院できない場合は事前にキャンセルを。30 日で 5 回のキャンセル、または 180 日で 3 回の無断欠席でオンライン予約が停止されます", "못 오시면 미리 취소하세요. 30일 내 5회 취소 또는 180일 내 3회 노쇼 시 온라인 예약이 중지됩니다", "Отменяйте запись заранее. 5 отмен за 30 дней или 3 неявки за 180 дней — онлайн-запись приостанавливается", "Cancele con antelación si no puede venir. 5 cancelaciones en 30 días o 3 ausencias en 180 días suspenden la reserva en línea", "Annulez à l'avance si vous ne pouvez pas venir. 5 annulations en 30 jours ou 3 absences en 180 jours suspendent la réservation en ligne", "หากมาไม่ได้โปรดยกเลิกล่วงหน้า ยกเลิก 5 ครั้งใน 30 วัน หรือไม่มาตามนัด 3 ครั้งใน 180 วัน จะถูกระงับการจองออนไลน์", "Không đến được vui lòng hủy trước. Hủy 5 lần trong 30 ngày hoặc vắng 3 lần trong 180 ngày sẽ bị tạm ngừng đặt lịch trực tuyến"],
  sc_mine_t: ["我的预约", "My appointments", "予約一覧", "내 예약", "Мои записи", "Mis citas", "Mes rendez-vous", "นัดหมายของฉัน", "Lịch hẹn của tôi"],
  sc_rem_t: ["就诊提醒", "Reminders", "受診のお知らせ", "진료 알림", "Напоминания", "Recordatorios", "Rappels", "การแจ้งเตือน", "Nhắc lịch"],
  sc_prof_t: ["我的资料", "My details", "登録情報", "내 정보", "Мои данные", "Mis datos", "Mes informations", "ข้อมูลของฉัน", "Thông tin của tôi"],

  /* ---------- 挂号步骤 ---------- */
  step1: ["选科室", "Department", "診療科", "진료과", "Отделение", "Departamento", "Service", "แผนก", "Chọn khoa"],
  step2: ["选医生与日期", "Doctor & date", "医師と日付", "의사·날짜", "Врач и дата", "Médico y fecha", "Médecin et date", "แพทย์และวันที่", "Bác sĩ & ngày"],
  step3: ["确认预约", "Confirm", "確認", "확인", "Подтверждение", "Confirmar", "Confirmer", "ยืนยัน", "Xác nhận"],
  step4: ["预约成功", "Done", "完了", "완료", "Готово", "Listo", "Terminé", "สำเร็จ", "Hoàn tất"],
  step_back_title: ["返回修改", "Go back and change", "戻って変更", "돌아가서 수정", "Вернуться и изменить", "Volver y cambiar", "Revenir et modifier", "กลับไปแก้ไข", "Quay lại sửa"],
  back: ["← 返回上一步", "← Back", "← 戻る", "← 이전", "← Назад", "← Atrás", "← Retour", "← ย้อนกลับ", "← Quay lại"],

  /* ---------- 第一步：选科室 / 搜索 ---------- */
  search_ph: ["搜索科室、症状或医生", "Search departments, symptoms or doctors", "診療科・症状・医師を検索", "진료과·증상·의사 검색", "Поиск: отделение, симптом или врач", "Buscar departamento, síntoma o médico", "Service, symptôme ou médecin", "ค้นหาแผนก อาการ หรือแพทย์", "Tìm khoa, triệu chứng hoặc bác sĩ"],
  search: ["搜索", "Search", "検索", "검색", "Найти", "Buscar", "Rechercher", "ค้นหา", "Tìm"],
  search_lang_note: ["", "Symptom search works in Chinese (e.g. 胃痛, 咳嗽). You can also type a department or doctor name in English.", "症状検索は中国語のみ対応です（例：胃痛、咳嗽）。診療科名や医師名でも検索できます。", "증상 검색은 중국어만 지원합니다(예: 胃痛, 咳嗽). 진료과나 의사 이름으로도 검색할 수 있습니다.", "Поиск по симптомам — на китайском (напр. 胃痛, 咳嗽). Можно искать по названию отделения или имени врача.", "La búsqueda por síntomas funciona en chino (p. ej. 胃痛, 咳嗽). También puede buscar por departamento o médico.", "La recherche par symptôme fonctionne en chinois (ex. 胃痛, 咳嗽). Vous pouvez aussi chercher un service ou un médecin.", "การค้นหาตามอาการรองรับภาษาจีนเท่านั้น (เช่น 胃痛, 咳嗽) ค้นหาด้วยชื่อแผนกหรือแพทย์ได้", "Tìm theo triệu chứng chỉ hỗ trợ tiếng Trung (vd. 胃痛, 咳嗽). Có thể tìm theo tên khoa hoặc bác sĩ."],
  doctors_h: ["医生", "Doctors", "医師", "의사", "Врачи", "Médicos", "Médecins", "แพทย์", "Bác sĩ"],
  depts_h: ["科室", "Departments", "診療科", "진료과", "Отделения", "Departamentos", "Services", "แผนก", "Khoa"],
  fee: ["挂号费", "Fee", "診察料", "진료비", "Стоимость", "Tarifa", "Tarif", "ค่าลงทะเบียน", "Phí khám"],
  yuan: ["元", "CNY", "元", "위안", "юаней", "CNY", "CNY", "หยวน", "tệ"],
  specialty: ["擅长", "Specialties", "専門", "전문 분야", "Специализация", "Especialidades", "Spécialités", "ความเชี่ยวชาญ", "Chuyên môn"],
  match: ["匹配", "Matches", "一致", "일치", "Совпадения", "Coincidencias", "Correspondances", "ตรงกับ", "Khớp"],
  n_doctors: ["{n} 位医生", "{n} doctors", "医師 {n} 名", "의사 {n}명", "Врачей: {n}", "{n} médicos", "{n} médecins", "แพทย์ {n} คน", "{n} bác sĩ"],
  loc_tbd: ["位置待定", "Location TBD", "場所未定", "위치 미정", "Место уточняется", "Ubicación por confirmar", "Lieu à confirmer", "ยังไม่ระบุสถานที่", "Chưa có vị trí"],
  no_match: ["未找到匹配的科室或医生，可以换个说法，例如“胃痛”“咳嗽”“近视”，或输入医生姓名。", "No matching department or doctor. Try a department name, a doctor's name, or a symptom in Chinese.", "該当する診療科・医師が見つかりません。診療科名、医師名、または中国語の症状で検索してください。", "일치하는 진료과나 의사가 없습니다. 진료과명, 의사 이름 또는 중국어 증상으로 검색해 보세요.", "Ничего не найдено. Введите отделение, имя врача или симптом на китайском.", "Sin resultados. Pruebe con un departamento, un médico o un síntoma en chino.", "Aucun résultat. Essayez un service, un médecin ou un symptôme en chinois.", "ไม่พบแผนกหรือแพทย์ ลองค้นหาด้วยชื่อแผนก ชื่อแพทย์ หรืออาการเป็นภาษาจีน", "Không tìm thấy. Hãy thử tên khoa, tên bác sĩ hoặc triệu chứng bằng tiếng Trung."],
  er_hint: ["属于急症，<b>急诊无需预约</b>，请直接前往急诊科（24 小时开放），情况紧急请拨打 120。", " may be an emergency. <b>No appointment is needed</b> — go straight to the Emergency Department (open 24 h) or call 120.", "は救急の可能性があります。<b>救急は予約不要</b>です。救急外来（24時間）へ直接お越しいただくか、120番に電話してください。", "은(는) 응급일 수 있습니다. <b>응급실은 예약이 필요 없습니다</b>. 응급실(24시간)로 바로 가시거나 120에 전화하세요.", " — возможно, неотложный случай. <b>Запись не нужна</b>: обратитесь в приёмное отделение (круглосуточно) или звоните 120.", " puede ser una urgencia. <b>No necesita cita</b>: acuda directamente a Urgencias (24 h) o llame al 120.", " peut être une urgence. <b>Pas besoin de rendez-vous</b> : allez directement aux urgences (24 h/24) ou appelez le 120.", " อาจเป็นเหตุฉุกเฉิน <b>ไม่ต้องจองคิว</b> ไปที่แผนกฉุกเฉินได้ทันที (เปิด 24 ชม.) หรือโทร 120", " có thể là cấp cứu. <b>Không cần đặt lịch</b>, hãy đến thẳng khoa Cấp cứu (24 giờ) hoặc gọi 120."],
  other_hint: ["通常在<b>{dept}</b>就诊，本院暂未开设该科室，建议前往综合医院。", " is usually treated by <b>{dept}</b>, which this hospital does not have yet.", "は通常<b>{dept}</b>で受診しますが、当院にはまだありません。", "은(는) 보통 <b>{dept}</b>에서 진료하지만 본원에는 아직 없습니다.", " обычно лечит отделение <b>{dept}</b>, которого в больнице пока нет.", " suele tratarse en <b>{dept}</b>, que este hospital aún no tiene.", " relève généralement du service <b>{dept}</b>, que l'hôpital n'a pas encore.", " มักรักษาที่แผนก<b>{dept}</b> ซึ่งโรงพยาบาลยังไม่มี", " thường khám ở khoa <b>{dept}</b>, bệnh viện chưa có khoa này."],
  see_below: ["也可以看看下面的科室：", " You can also try these departments:", "以下の診療科もご覧ください：", " 아래 진료과도 확인해 보세요:", " Также посмотрите эти отделения:", " También puede ver estos departamentos:", " Vous pouvez aussi consulter ces services :", " ดูแผนกด้านล่างได้", " Bạn cũng có thể xem các khoa dưới đây:"],

  /* ---------- 第二步：医生与号源 ---------- */
  loading_slots: ["加载号源中…", "Loading available slots…", "空き状況を読み込み中…", "예약 가능 시간 불러오는 중…", "Загрузка свободного времени…", "Cargando horarios…", "Chargement des créneaux…", "กำลังโหลดคิวว่าง…", "Đang tải lịch trống…"],
  no_doctor: ["该科室暂无出诊医生。", "No doctors available in this department.", "この診療科には現在医師がいません。", "이 진료과에는 진료 중인 의사가 없습니다.", "В этом отделении сейчас нет врачей.", "No hay médicos disponibles en este departamento.", "Aucun médecin disponible dans ce service.", "แผนกนี้ยังไม่มีแพทย์ออกตรวจ", "Khoa này hiện chưa có bác sĩ."],
  st_avail: ["有号", "Available", "空きあり", "예약 가능", "Есть места", "Disponible", "Disponible", "ว่าง", "Còn chỗ"],
  st_tight: ["紧张", "Few left", "残りわずか", "얼마 안 남음", "Мало мест", "Quedan pocas", "Peu de places", "เหลือน้อย", "Sắp hết"],
  st_full: ["已满", "Full", "満員", "마감", "Мест нет", "Completo", "Complet", "เต็ม", "Hết chỗ"],
  view_slots: ["查看号源", "See times", "空き時間を見る", "시간 보기", "Время приёма", "Ver horarios", "Voir les créneaux", "ดูเวลา", "Xem giờ khám"],
  other_slots: ["查看其他时段", "Other times", "他の時間帯", "다른 시간", "Другое время", "Otros horarios", "Autres créneaux", "เวลาอื่น", "Khung giờ khác"],
  remain: ["余 {n}", "{n} left", "残り {n}", "{n}명 남음", "осталось {n}", "quedan {n}", "reste {n}", "เหลือ {n}", "còn {n}"],
  room: ["诊室", "Room", "診察室", "진료실", "Кабинет", "Consultorio", "Salle", "ห้องตรวจ", "Phòng"],
  tbd: ["待定", "TBD", "未定", "미정", "уточняется", "por confirmar", "à confirmer", "ยังไม่ระบุ", "chưa định"],
  today: ["今天", "Today", "今日", "오늘", "Сегодня", "Hoy", "Aujourd'hui", "วันนี้", "Hôm nay"],
  tomorrow: ["明天", "Tomorrow", "明日", "내일", "Завтра", "Mañana", "Demain", "พรุ่งนี้", "Ngày mai"],
  am: ["上午", "Morning", "午前", "오전", "Утро", "Mañana", "Matin", "ช่วงเช้า", "Buổi sáng"],
  pm: ["下午", "Afternoon", "午後", "오후", "День", "Tarde", "Après-midi", "ช่วงบ่าย", "Buổi chiều"],
  slot_full_alert: ["该时段已约满，请选择其他时段或医生，或点“排候补”。", "This time is fully booked. Choose another time or doctor, or join the waitlist.", "この時間帯は満員です。別の時間・医師を選ぶか、キャンセル待ちに登録してください。", "이 시간은 마감되었습니다. 다른 시간이나 의사를 선택하거나 대기 신청하세요.", "Это время занято. Выберите другое время или врача либо встаньте в лист ожидания.", "Este horario está completo. Elija otro o únase a la lista de espera.", "Ce créneau est complet. Choisissez-en un autre ou inscrivez-vous sur liste d'attente.", "เวลานี้เต็มแล้ว เลือกเวลาหรือแพทย์อื่น หรือลงชื่อรอคิว", "Khung giờ này đã kín. Hãy chọn giờ hoặc bác sĩ khác, hoặc đăng ký chờ."],
  load_slots_fail: ["加载号源失败：", "Could not load slots: ", "空き状況の読み込みに失敗しました：", "예약 시간을 불러오지 못했습니다: ", "Не удалось загрузить расписание: ", "No se pudieron cargar los horarios: ", "Impossible de charger les créneaux : ", "โหลดคิวไม่สำเร็จ: ", "Không tải được lịch: "],
  join_wl: ["排候补", "Join waitlist", "キャンセル待ち", "대기 신청", "В лист ожидания", "Lista de espera", "Liste d'attente", "ลงชื่อรอคิว", "Đăng ký chờ"],
  wl_pick_slot: ["号源已满，请在下面选一个已满的时段排候补。", "All slots are full. Pick a full time below to join its waitlist.", "満員です。下から満員の時間帯を選んでキャンセル待ちに登録してください。", "모두 마감되었습니다. 아래에서 마감된 시간을 골라 대기 신청하세요.", "Мест нет. Выберите занятое время ниже, чтобы встать в лист ожидания.", "Todo completo. Elija abajo un horario completo para la lista de espera.", "Tout est complet. Choisissez ci-dessous un créneau pour la liste d'attente.", "คิวเต็มแล้ว เลือกเวลาที่เต็มด้านล่างเพื่อรอคิว", "Đã kín chỗ. Chọn một khung giờ đã kín bên dưới để đăng ký chờ."],

  /* ---------- 第三步：确认与就诊人信息 ---------- */
  confirm_h: ["确认预约信息", "Confirm your appointment", "予約内容の確認", "예약 정보 확인", "Проверьте запись", "Confirme su cita", "Confirmez votre rendez-vous", "ยืนยันการนัดหมาย", "Xác nhận lịch hẹn"],
  f_dept: ["就诊科室", "Department", "診療科", "진료과", "Отделение", "Departamento", "Service", "แผนก", "Khoa"],
  f_doctor: ["接诊医生", "Doctor", "担当医師", "담당 의사", "Врач", "Médico", "Médecin", "แพทย์", "Bác sĩ"],
  f_time: ["就诊时间", "Time", "受診日時", "진료 시간", "Время", "Fecha y hora", "Date et heure", "วันเวลา", "Thời gian"],
  f_place: ["就诊地点", "Location", "場所", "장소", "Место", "Lugar", "Lieu", "สถานที่", "Địa điểm"],
  f_fee: ["挂号费用", "Fee", "診察料", "진료비", "Стоимость", "Tarifa", "Tarif", "ค่าลงทะเบียน", "Phí khám"],
  noshow_warn: ["爽约 3 次将进入黑名单，30 天内无法挂号。如需取消，请在就诊日前操作。", "Missing 3 appointments blocks online booking for 30 days. Please cancel before the visit day if you cannot come.", "無断キャンセルが3回になると30日間予約できなくなります。来られない場合は受診日の前日までにキャンセルしてください。", "노쇼 3회 시 30일간 예약할 수 없습니다. 못 오시면 진료일 전에 취소해 주세요.", "После 3 неявок онлайн-запись блокируется на 30 дней. Отменяйте запись заранее.", "Tres ausencias bloquean las citas en línea durante 30 días. Cancele antes del día de la cita si no puede venir.", "Trois absences bloquent la prise de rendez-vous en ligne pendant 30 jours. Annulez avant le jour du rendez-vous.", "ผิดนัด 3 ครั้งจะจองออนไลน์ไม่ได้ 30 วัน หากมาไม่ได้กรุณายกเลิกก่อนวันนัด", "Vắng mặt 3 lần sẽ bị khóa đặt lịch trực tuyến 30 ngày. Vui lòng hủy trước ngày khám nếu không đến được."],
  patient_h: ["就诊人信息", "Patient details", "患者情報", "환자 정보", "Данные пациента", "Datos del paciente", "Informations du patient", "ข้อมูลผู้ป่วย", "Thông tin bệnh nhân"],
  new_patient: ["+ 新就诊人", "+ New patient", "+ 新しい患者", "+ 새 환자", "+ Новый пациент", "+ Nuevo paciente", "+ Nouveau patient", "+ ผู้ป่วยใหม่", "+ Bệnh nhân mới"],
  name: ["姓名", "Full name", "氏名", "이름", "Имя", "Nombre", "Nom complet", "ชื่อ-นามสกุล", "Họ tên"],
  name_ph: ["与证件一致的姓名", "As shown on your ID / passport", "身分証・パスポートと同じ表記", "신분증·여권과 동일하게", "Как в документе (латиницей)", "Como en su documento", "Comme sur votre pièce d'identité", "ตามที่ระบุในเอกสาร", "Như trên giấy tờ"],
  id_type: ["证件类型", "ID type", "身分証の種類", "신분증 종류", "Тип документа", "Tipo de documento", "Type de pièce", "ประเภทเอกสาร", "Loại giấy tờ"],
  nationality: ["国籍 / 地区", "Nationality", "国籍・地域", "국적·지역", "Гражданство", "Nacionalidad", "Nationalité", "สัญชาติ", "Quốc tịch"],
  choose: ["请选择", "Select…", "選択してください", "선택하세요", "Выберите…", "Seleccione…", "Choisir…", "เลือก…", "Chọn…"],
  id_no: ["证件号码", "ID number", "番号", "번호", "Номер документа", "Número", "Numéro", "หมายเลข", "Số giấy tờ"],
  phone: ["手机号", "Mobile", "携帯番号", "휴대폰", "Телефон", "Móvil", "Mobile", "โทรศัพท์มือถือ", "Số điện thoại"],
  phone_cc: ["区号", "Code", "国番号", "국가번호", "Код", "Prefijo", "Indicatif", "รหัสประเทศ", "Mã vùng"],
  phone_ph_cn: ["11 位手机号", "11-digit number", "11桁の番号", "11자리 번호", "11 цифр", "11 dígitos", "11 chiffres", "11 หลัก", "11 chữ số"],
  phone_ph_intl: ["本地号码（不含区号）", "Number without country code", "国番号を除いた番号", "국가번호 제외 번호", "Номер без кода страны", "Número sin prefijo", "Numéro sans indicatif", "เบอร์ไม่รวมรหัสประเทศ", "Số không gồm mã quốc gia"],
  email: ["邮箱", "Email", "メール", "이메일", "Эл. почта", "Correo", "E-mail", "อีเมล", "Email"],
  email_ph: ["选填，用于就诊提醒", "Optional — for reminders", "任意・お知らせ用", "선택 — 알림용", "Необязательно — для напоминаний", "Opcional — para recordatorios", "Facultatif — pour les rappels", "ไม่บังคับ — สำหรับแจ้งเตือน", "Không bắt buộc — để nhắc lịch"],
  submit_booking: ["确认预约", "Book appointment", "予約を確定", "예약 확정", "Записаться", "Confirmar cita", "Confirmer le rendez-vous", "ยืนยันการจอง", "Xác nhận đặt lịch"],
  booking_ing: ["预约中…", "Booking…", "予約中…", "예약 중…", "Запись…", "Reservando…", "Réservation…", "กำลังจอง…", "Đang đặt…"],
  fill_required: ["请填写姓名、证件号码和手机号", "Please enter your name, ID number and mobile number.", "氏名・番号・携帯番号を入力してください。", "이름, 신분증 번호, 휴대폰 번호를 입력하세요.", "Укажите имя, номер документа и телефон.", "Introduzca nombre, número de documento y móvil.", "Saisissez nom, numéro de pièce et mobile.", "กรุณากรอกชื่อ หมายเลขเอกสาร และเบอร์โทร", "Vui lòng nhập họ tên, số giấy tờ và số điện thoại."],
  slot_expired: ["就诊时段已失效，请重新选择", "This time is no longer available. Please choose again.", "この時間帯は選択できなくなりました。選び直してください。", "이 시간은 더 이상 선택할 수 없습니다. 다시 선택하세요.", "Это время больше недоступно. Выберите снова.", "Este horario ya no está disponible.", "Ce créneau n'est plus disponible.", "เวลานี้ไม่ว่างแล้ว กรุณาเลือกใหม่", "Khung giờ không còn, vui lòng chọn lại."],
  captcha_wrong: ["验证码不正确，请重新计算", "Wrong answer, please try again.", "答えが違います。もう一度どうぞ。", "답이 틀렸습니다. 다시 시도하세요.", "Неверный ответ, попробуйте ещё раз.", "Respuesta incorrecta, inténtelo de nuevo.", "Mauvaise réponse, réessayez.", "คำตอบไม่ถูกต้อง ลองอีกครั้ง", "Sai đáp án, vui lòng thử lại."],
  captcha_why: ["该时段仅剩 {n} 个号，需要验证一下不是脚本在抢号。", "Only {n} left — please answer a quick question to show you are not a bot.", "残り {n} 枠です。自動予約防止のため簡単な問題に答えてください。", "{n}자리만 남았습니다. 자동 예약 방지를 위해 간단한 문제를 풀어 주세요.", "Осталось {n} мест — ответьте на простой вопрос (защита от ботов).", "Quedan {n}: responda una pregunta para confirmar que no es un robot.", "Plus que {n} places : répondez à une question pour prouver que vous n'êtes pas un robot.", "เหลือ {n} คิว กรุณาตอบคำถามเพื่อยืนยันว่าไม่ใช่บอท", "Chỉ còn {n} chỗ, vui lòng trả lời câu hỏi để xác nhận bạn không phải robot."],
  just_taken: ["这个号刚被约走了。为您保留已选条件，请换个时段或医生再试。", "Someone just took this slot. Please pick another time or doctor.", "この枠はちょうど埋まりました。別の時間か医師を選んでください。", "방금 마감되었습니다. 다른 시간이나 의사를 선택하세요.", "Это место только что заняли. Выберите другое время или врача.", "Alguien acaba de reservar este horario. Elija otro.", "Ce créneau vient d'être pris. Choisissez-en un autre.", "คิวนี้เพิ่งถูกจองไป กรุณาเลือกเวลาหรือแพทย์อื่น", "Chỗ này vừa có người đặt. Vui lòng chọn giờ hoặc bác sĩ khác."],
  fail: ["操作失败", "Something went wrong", "失敗しました", "실패했습니다", "Ошибка", "Error", "Échec", "ไม่สำเร็จ", "Thất bại"],

  /* 证件类型 */
  idt_CN_ID: ["中国居民身份证", "Chinese resident ID card", "中国居民身分証", "중국 주민신분증", "Удостоверение личности КНР", "DNI chino", "Carte d'identité chinoise", "บัตรประชาชนจีน", "CCCD Trung Quốc"],
  idt_PASSPORT: ["护照", "Passport", "パスポート", "여권", "Паспорт", "Pasaporte", "Passeport", "หนังสือเดินทาง", "Hộ chiếu"],
  idt_FRP: ["外国人永久居留身份证", "Foreigner's Permanent Residence ID", "外国人永住身分証", "외국인 영주 신분증", "Вид на жительство иностранца (КНР)", "Residencia permanente de extranjero", "Carte de résident permanent", "บัตรผู้พำนักถาวรต่างชาติ", "Thẻ thường trú người nước ngoài"],
  idt_HK_MO: ["港澳居民来往内地通行证", "Mainland Travel Permit (HK/Macao)", "港澳居民来往内地通行証", "홍콩·마카오 거주민 내지 통행증", "Пропуск для жителей Гонконга/Макао", "Permiso de viaje (HK/Macao)", "Permis de voyage (HK/Macao)", "บัตรผ่านแดน (ฮ่องกง/มาเก๊า)", "Giấy thông hành (HK/Ma Cao)"],
  idt_TW: ["台湾居民来往大陆通行证", "Mainland Travel Permit (Taiwan)", "台湾居民来往大陸通行証", "대만 거주민 대륙 통행증", "Пропуск для жителей Тайваня", "Permiso de viaje (Taiwán)", "Permis de voyage (Taïwan)", "บัตรผ่านแดน (ไต้หวัน)", "Giấy thông hành (Đài Loan)"],
  idt_HMT_RES: ["港澳台居民居住证", "Residence Permit (HK/Macao/Taiwan)", "港澳台居民居住証", "홍콩·마카오·대만 거주증", "Вид на жительство (Гонконг/Макао/Тайвань)", "Permiso de residencia (HK/Macao/Taiwán)", "Permis de séjour (HK/Macao/Taïwan)", "ใบอนุญาตพำนัก (ฮ่องกง/มาเก๊า/ไต้หวัน)", "Thẻ cư trú (HK/Ma Cao/Đài Loan)"],
  ph_CN_ID: ["18 位身份证号", "18 characters", "18桁", "18자리", "18 знаков", "18 caracteres", "18 caractères", "18 หลัก", "18 ký tự"],
  ph_PASSPORT: ["护照号码", "Passport number", "旅券番号", "여권 번호", "Номер паспорта", "Número de pasaporte", "Numéro de passeport", "หมายเลขหนังสือเดินทาง", "Số hộ chiếu"],
  ph_FRP: ["18 位（9 开头）或旧版 15 位", "18 chars starting with 9, or old 15-char", "9で始まる18桁、または旧版15桁", "9로 시작하는 18자리 또는 구형 15자리", "18 знаков с 9 или старый формат 15", "18 caracteres (empieza por 9) o 15 antiguo", "18 caractères (commence par 9) ou ancien 15", "18 หลักขึ้นต้นด้วย 9 หรือแบบเก่า 15 หลัก", "18 ký tự bắt đầu bằng 9 hoặc mẫu cũ 15"],
  ph_HK_MO: ["H/M 开头 + 8 或 10 位数字", "H or M + 8 or 10 digits", "H/M + 8桁または10桁", "H/M + 8자리 또는 10자리", "H или M + 8 или 10 цифр", "H o M + 8 o 10 dígitos", "H ou M + 8 ou 10 chiffres", "H หรือ M + 8 หรือ 10 หลัก", "H hoặc M + 8 hoặc 10 số"],
  ph_TW: ["8 或 10 位数字", "8 or 10 digits", "8桁または10桁", "8자리 또는 10자리", "8 или 10 цифр", "8 o 10 dígitos", "8 ou 10 chiffres", "8 หรือ 10 หลัก", "8 hoặc 10 số"],
  ph_HMT_RES: ["18 位，810000 / 820000 / 830000 开头", "18 chars starting 810000/820000/830000", "810000/820000/830000で始まる18桁", "810000/820000/830000으로 시작하는 18자리", "18 знаков, начало 810000/820000/830000", "18 caracteres, empieza por 810000/820000/830000", "18 caractères, début 810000/820000/830000", "18 หลัก ขึ้นต้น 810000/820000/830000", "18 ký tự, bắt đầu 810000/820000/830000"],

  /* 前端即时校验 */
  v_name: ["姓名需为 2–20 个中文字符，或与证件一致的英文字母", "Enter your name in Chinese, or in Latin letters as on your passport.", "氏名は中国語、またはパスポートと同じローマ字で入力してください。", "이름은 중국어 또는 여권과 같은 영문으로 입력하세요.", "Введите имя по-китайски или латиницей, как в паспорте.", "Escriba su nombre en chino o en letras latinas como en el pasaporte.", "Saisissez votre nom en chinois ou en lettres latines comme sur le passeport.", "กรอกชื่อเป็นภาษาจีน หรืออักษรละตินตามหนังสือเดินทาง", "Nhập tên bằng tiếng Trung hoặc chữ Latin như trên hộ chiếu."],
  v_doc_CN_ID: ["身份证号不正确（18 位，最后一位可能是 X，校验位要正确）", "Invalid Chinese ID number (18 characters with a valid check digit).", "身分証番号が正しくありません（18桁・チェック数字）。", "주민신분증 번호가 올바르지 않습니다(18자리, 검증 번호).", "Неверный номер удостоверения (18 знаков, контрольная цифра).", "Número de DNI chino no válido (18 caracteres).", "Numéro de carte d'identité chinoise invalide (18 caractères).", "เลขบัตรประชาชนจีนไม่ถูกต้อง (18 หลัก)", "Số CCCD Trung Quốc không hợp lệ (18 ký tự)."],
  v_doc_PASSPORT: ["护照号码应为 5–14 位字母或数字", "Passport number must be 5–14 letters or digits.", "旅券番号は英数字5〜14文字です。", "여권 번호는 영문·숫자 5~14자입니다.", "Номер паспорта: 5–14 латинских букв или цифр.", "El pasaporte debe tener de 5 a 14 letras o dígitos.", "Le passeport doit comporter 5 à 14 lettres ou chiffres.", "หมายเลขหนังสือเดินทางต้องเป็นตัวอักษรหรือตัวเลข 5–14 ตัว", "Số hộ chiếu gồm 5–14 chữ hoặc số."],
  v_doc_FRP: ["外国人永久居留身份证号码不正确", "Invalid Permanent Residence ID number.", "永住身分証番号が正しくありません。", "영주 신분증 번호가 올바르지 않습니다.", "Неверный номер вида на жительство.", "Número de residencia permanente no válido.", "Numéro de carte de résident invalide.", "หมายเลขบัตรผู้พำนักถาวรไม่ถูกต้อง", "Số thẻ thường trú không hợp lệ."],
  v_doc_HK_MO: ["通行证号码应为 H 或 M 开头加 8 或 10 位数字", "Permit number must be H or M followed by 8 or 10 digits.", "通行証番号はH/Mの後に8桁または10桁です。", "통행증 번호는 H/M 뒤에 8자리 또는 10자리입니다.", "Номер пропуска: H или M и 8 или 10 цифр.", "El permiso debe ser H o M seguido de 8 o 10 dígitos.", "Le permis doit être H ou M suivi de 8 ou 10 chiffres.", "หมายเลขต้องขึ้นต้นด้วย H หรือ M ตามด้วยตัวเลข 8 หรือ 10 หลัก", "Số giấy thông hành gồm H hoặc M và 8 hoặc 10 số."],
  v_doc_TW: ["台胞证号码应为 8 或 10 位数字", "Permit number must be 8 or 10 digits.", "通行証番号は8桁または10桁の数字です。", "통행증 번호는 8자리 또는 10자리 숫자입니다.", "Номер пропуска: 8 или 10 цифр.", "El permiso debe tener 8 o 10 dígitos.", "Le permis doit comporter 8 ou 10 chiffres.", "หมายเลขต้องเป็นตัวเลข 8 หรือ 10 หลัก", "Số giấy thông hành gồm 8 hoặc 10 số."],
  v_doc_HMT_RES: ["居住证号码应为 18 位，以 810000 / 820000 / 830000 开头", "Residence permit number: 18 characters starting with 810000/820000/830000.", "居住証番号は810000/820000/830000で始まる18桁です。", "거주증 번호는 810000/820000/830000으로 시작하는 18자리입니다.", "Номер: 18 знаков, начинается с 810000/820000/830000.", "Número de 18 caracteres que empieza por 810000/820000/830000.", "Numéro de 18 caractères commençant par 810000/820000/830000.", "หมายเลข 18 หลักขึ้นต้น 810000/820000/830000", "Số 18 ký tự bắt đầu bằng 810000/820000/830000."],
  v_nat: ["请选择国籍 / 地区", "Please select your nationality.", "国籍を選択してください。", "국적을 선택하세요.", "Выберите гражданство.", "Seleccione su nacionalidad.", "Choisissez votre nationalité.", "กรุณาเลือกสัญชาติ", "Vui lòng chọn quốc tịch."],
  v_phone_cn: ["手机号格式不正确（11 位，1 开头）", "Chinese mobile numbers have 11 digits starting with 1.", "中国の携帯番号は1で始まる11桁です。", "중국 휴대폰 번호는 1로 시작하는 11자리입니다.", "Китайский номер: 11 цифр, начинается с 1.", "Los móviles chinos tienen 11 dígitos y empiezan por 1.", "Un mobile chinois a 11 chiffres et commence par 1.", "เบอร์มือถือจีนมี 11 หลัก ขึ้นต้นด้วย 1", "Số di động Trung Quốc có 11 chữ số, bắt đầu bằng 1."],
  v_phone_intl: ["手机号应为 4–11 位数字（不含区号）", "Enter 4–11 digits without the country code.", "国番号を除いた4〜11桁で入力してください。", "국가번호를 제외한 4~11자리로 입력하세요.", "Введите 4–11 цифр без кода страны.", "Introduzca de 4 a 11 dígitos sin prefijo.", "Saisissez 4 à 11 chiffres sans indicatif.", "กรอก 4–11 หลัก ไม่รวมรหัสประเทศ", "Nhập 4–11 chữ số, không gồm mã quốc gia."],
  v_email: ["邮箱格式不正确", "Invalid email address.", "メールアドレスが正しくありません。", "이메일 형식이 올바르지 않습니다.", "Неверный адрес почты.", "Correo no válido.", "Adresse e-mail invalide.", "อีเมลไม่ถูกต้อง", "Email không hợp lệ."],

  /* ---------- 第四步：成功页 ---------- */
  success: ["预约成功", "Appointment booked", "予約が完了しました", "예약 완료", "Вы записаны", "Cita confirmada", "Rendez-vous confirmé", "จองสำเร็จ", "Đặt lịch thành công"],
  f_arrive: ["建议到院时间", "Please arrive", "来院時刻の目安", "도착 권장 시간", "Приходите", "Llegue", "Arrivée conseillée", "ควรมาถึง", "Nên đến"],
  arrive_am: ["请于 07:30 前到院取号候诊", "before 07:30 to check in", "07:30までに受付", "07:30 전까지 접수", "до 07:30 для регистрации", "antes de las 07:30", "avant 07 h 30", "ก่อน 07:30 น.", "trước 07:30 để lấy số"],
  arrive_pm: ["请于 13:00 前到院取号候诊", "before 13:00 to check in", "13:00までに受付", "13:00 전까지 접수", "до 13:00 для регистрации", "antes de las 13:00", "avant 13 h 00", "ก่อน 13:00 น.", "trước 13:00 để lấy số"],
  f_patient: ["就诊人", "Patient", "患者", "환자", "Пациент", "Paciente", "Patient", "ผู้ป่วย", "Bệnh nhân"],
  f_apt_no: ["挂号单号", "Booking no.", "予約番号", "예약 번호", "Номер записи", "N.º de cita", "N° de réservation", "เลขที่การจอง", "Mã lịch hẹn"],
  seq: ["序号", "Queue no.", "受付番号", "순번", "Очередь №", "Turno", "N° de passage", "ลำดับคิว", "Số thứ tự"],
  add_cal: ["📅 添加到日历", "📅 Add to calendar", "📅 カレンダーに追加", "📅 캘린더에 추가", "📅 В календарь", "📅 Añadir al calendario", "📅 Ajouter au calendrier", "📅 เพิ่มในปฏิทิน", "📅 Thêm vào lịch"],
  route: ["🗺️ 查看路线", "🗺️ Directions", "🗺️ 道順", "🗺️ 길찾기", "🗺️ Маршрут", "🗺️ Cómo llegar", "🗺️ Itinéraire", "🗺️ เส้นทาง", "🗺️ Chỉ đường"],
  cancel_appt: ["取消预约", "Cancel", "予約をキャンセル", "예약 취소", "Отменить", "Cancelar cita", "Annuler", "ยกเลิกนัด", "Hủy lịch"],
  continue_booking: ["继续挂号", "Book another", "続けて予約", "추가 예약", "Ещё запись", "Otra cita", "Autre rendez-vous", "จองเพิ่ม", "Đặt thêm"],
  bring_docs: ["请携带证件原件（护照 / 身份证）、医保卡（如有）、既往病历资料。", "Please bring your original ID or passport, insurance card (if any) and previous medical records.", "身分証またはパスポートの原本、保険証（あれば）、過去の診療記録をお持ちください。", "신분증 또는 여권 원본, 보험증(있는 경우), 이전 진료 기록을 지참하세요.", "Возьмите оригинал паспорта, страховой полис (если есть) и медицинские документы.", "Traiga su pasaporte o documento original, tarjeta de seguro (si tiene) e historial médico.", "Apportez votre passeport ou pièce d'identité, votre carte d'assurance (le cas échéant) et votre dossier médical.", "กรุณานำหนังสือเดินทางหรือบัตรประจำตัวฉบับจริง บัตรประกัน (ถ้ามี) และประวัติการรักษามาด้วย", "Vui lòng mang hộ chiếu/giấy tờ bản gốc, thẻ bảo hiểm (nếu có) và hồ sơ bệnh án."],
  confirm_cancel: ["确定取消这张挂号单？", "Cancel this appointment?", "この予約をキャンセルしますか？", "이 예약을 취소할까요?", "Отменить эту запись?", "¿Cancelar esta cita?", "Annuler ce rendez-vous ?", "ยกเลิกนัดนี้หรือไม่?", "Hủy lịch hẹn này?"],
  cancelled_ok: ["已取消", "Cancelled", "キャンセルしました", "취소되었습니다", "Запись отменена", "Cancelada", "Annulé", "ยกเลิกแล้ว", "Đã hủy"],
  cal_copied: ["已生成日历提醒（模拟）：", "Calendar reminder created (demo):", "カレンダーの予定を作成しました（デモ）：", "캘린더 알림을 만들었습니다(데모):", "Напоминание создано (демо):", "Recordatorio creado (demo):", "Rappel créé (démo) :", "สร้างการแจ้งเตือนแล้ว (สาธิต):", "Đã tạo nhắc lịch (mô phỏng):"],

  /* ---------- 个人中心 ---------- */
  center_h: ["个人中心", "My account", "マイページ", "마이페이지", "Мой кабинет", "Mi cuenta", "Mon compte", "บัญชีของฉัน", "Tài khoản"],
  tab_upcoming: ["待就诊", "Upcoming", "予定", "예정", "Предстоящие", "Próximas", "À venir", "กำลังจะถึง", "Sắp tới"],
  tab_completed: ["已完成", "Completed", "完了", "완료", "Завершённые", "Realizadas", "Terminés", "เสร็จสิ้น", "Đã khám"],
  tab_cancelled: ["已取消", "Cancelled", "キャンセル", "취소", "Отменённые", "Canceladas", "Annulés", "ยกเลิก", "Đã hủy"],
  tab_waitlist: ["候补", "Waitlist", "キャンセル待ち", "대기", "Ожидание", "Espera", "Attente", "รอคิว", "Danh sách chờ"],
  need_patient: ["本机还没有就诊人信息。挂一次号，或在“我的资料”中填写证件信息后即可查看。", "No patient saved on this device yet. Book once, or enter your ID in “My details”.", "この端末には患者情報がありません。一度予約するか「登録情報」で入力してください。", "이 기기에 저장된 환자가 없습니다. 한 번 예약하거나 '내 정보'에 입력하세요.", "На этом устройстве нет данных пациента. Запишитесь или введите документ в «Мои данные».", "Aún no hay paciente guardado. Pida una cita o introduzca su documento en «Mis datos».", "Aucun patient enregistré. Prenez un rendez-vous ou saisissez votre pièce dans « Mes informations ».", "ยังไม่มีข้อมูลผู้ป่วยในเครื่องนี้ จองคิวหนึ่งครั้งหรือกรอกใน 'ข้อมูลของฉัน'", "Chưa có bệnh nhân trên thiết bị này. Hãy đặt lịch hoặc nhập giấy tờ ở “Thông tin của tôi”."],
  loading: ["加载中…", "Loading…", "読み込み中…", "불러오는 중…", "Загрузка…", "Cargando…", "Chargement…", "กำลังโหลด…", "Đang tải…"],
  total_n: ["共 {n} 条", "{n} in total", "全 {n} 件", "총 {n}건", "Всего: {n}", "{n} en total", "{n} au total", "ทั้งหมด {n} รายการ", "Tổng {n}"],
  no_records: ["暂无记录。", "Nothing here yet.", "記録はありません。", "기록이 없습니다.", "Записей нет.", "No hay registros.", "Aucun élément.", "ยังไม่มีรายการ", "Chưa có dữ liệu."],
  load_fail: ["加载失败：", "Failed to load: ", "読み込みに失敗しました：", "불러오지 못했습니다: ", "Ошибка загрузки: ", "Error al cargar: ", "Échec du chargement : ", "โหลดไม่สำเร็จ: ", "Tải thất bại: "],
  reschedule: ["改约", "Change", "変更", "변경", "Перенести", "Cambiar", "Modifier", "เปลี่ยนนัด", "Đổi lịch"],
  confirm_reschedule: ["改约将先取消当前预约，并保留科室选择。确定吗？", "Changing will cancel this appointment first and keep the department. Continue?", "変更すると現在の予約をキャンセルし、診療科はそのまま残ります。よろしいですか？", "변경하면 현재 예약이 취소되고 진료과는 유지됩니다. 계속할까요?", "Текущая запись будет отменена, отделение сохранится. Продолжить?", "Se cancelará esta cita y se mantendrá el departamento. ¿Continuar?", "Ce rendez-vous sera annulé, le service sera conservé. Continuer ?", "การเปลี่ยนนัดจะยกเลิกนัดนี้ก่อน โดยคงแผนกเดิมไว้ ดำเนินการต่อหรือไม่?", "Đổi lịch sẽ hủy lịch hiện tại và giữ nguyên khoa. Tiếp tục?"],
  cd_past: ["已过期", "Past", "期限切れ", "지남", "Прошло", "Pasada", "Passé", "ผ่านไปแล้ว", "Đã qua"],
  cd_today: ["今天就诊", "Today", "本日受診", "오늘 진료", "Сегодня", "Hoy", "Aujourd'hui", "วันนี้", "Hôm nay"],
  cd_tomorrow: ["明天就诊", "Tomorrow", "明日受診", "내일 진료", "Завтра", "Mañana", "Demain", "พรุ่งนี้", "Ngày mai"],
  cd_n: ["还有 {n} 天就诊", "In {n} days", "あと {n} 日", "{n}일 후 진료", "Через {n} дн.", "En {n} días", "Dans {n} jours", "อีก {n} วัน", "Còn {n} ngày"],
  s_booked: ["待就诊", "Upcoming", "予定", "예정", "Ожидается", "Pendiente", "À venir", "รอเข้าตรวจ", "Chờ khám"],
  s_completed: ["已完成", "Completed", "完了", "완료", "Завершено", "Realizada", "Terminé", "เสร็จสิ้น", "Đã khám"],
  s_cancelled: ["已取消", "Cancelled", "キャンセル", "취소", "Отменено", "Cancelada", "Annulé", "ยกเลิก", "Đã hủy"],
  s_closed: ["已停诊", "Doctor unavailable", "休診", "휴진", "Приём отменён", "Médico no disponible", "Médecin indisponible", "แพทย์งดตรวจ", "Bác sĩ nghỉ"],
  s_no_show: ["爽约", "Missed", "無断欠席", "노쇼", "Неявка", "No asistió", "Absent", "ผิดนัด", "Vắng mặt"],
  no_reminders: ["暂无提醒。", "No reminders.", "お知らせはありません。", "알림이 없습니다.", "Напоминаний нет.", "Sin recordatorios.", "Aucun rappel.", "ไม่มีการแจ้งเตือน", "Không có nhắc nhở."],
  reminder: ["提醒", "Reminder", "お知らせ", "알림", "Напоминание", "Recordatorio", "Rappel", "แจ้งเตือน", "Nhắc nhở"],
  rem_lang_note: ["", "Reminder messages are generated by the hospital system in Chinese.", "お知らせの本文は中国語で作成されます。", "알림 내용은 중국어로 생성됩니다.", "Тексты напоминаний формируются на китайском.", "Los mensajes se generan en chino.", "Les messages sont rédigés en chinois.", "ข้อความแจ้งเตือนเป็นภาษาจีน", "Nội dung nhắc lịch được tạo bằng tiếng Trung."],

  prof_tip: ["修改姓名、手机号或邮箱。证件信息是身份标识，不可修改。", "You can change your name, phone and email. ID details cannot be changed.", "氏名・電話・メールを変更できます。身分証情報は変更できません。", "이름·전화·이메일을 변경할 수 있습니다. 신분증 정보는 변경할 수 없습니다.", "Можно изменить имя, телефон и почту. Данные документа изменить нельзя.", "Puede cambiar nombre, teléfono y correo. El documento no se puede cambiar.", "Vous pouvez modifier nom, téléphone et e-mail. La pièce d'identité ne peut pas être modifiée.", "แก้ไขชื่อ โทรศัพท์ และอีเมลได้ แต่แก้ไขข้อมูลเอกสารไม่ได้", "Có thể đổi tên, điện thoại, email. Không thể đổi giấy tờ."],
  load: ["加载", "Load", "読み込む", "불러오기", "Загрузить", "Cargar", "Charger", "โหลด", "Tải"],
  prof_need: ["请填写证件信息后点“加载”", "Enter your ID details and tap “Load”.", "身分証情報を入力して「読み込む」を押してください。", "신분증 정보를 입력하고 '불러오기'를 누르세요.", "Введите данные документа и нажмите «Загрузить».", "Introduzca su documento y pulse «Cargar».", "Saisissez votre pièce puis « Charger ».", "กรอกข้อมูลเอกสารแล้วกด 'โหลด'", "Nhập giấy tờ rồi bấm “Tải”."],
  prof_notfound: ["未找到该证件的就诊人记录，挂一次号系统会自动建档。", "No record for this ID yet — one will be created when you book.", "この身分証の記録はありません。予約すると自動で作成されます。", "이 신분증의 기록이 없습니다. 예약하면 자동으로 생성됩니다.", "Записи нет — она появится после первой записи на приём.", "No hay registro; se creará al pedir una cita.", "Aucun dossier — il sera créé lors de votre premier rendez-vous.", "ยังไม่มีข้อมูล ระบบจะสร้างให้เมื่อจองคิว", "Chưa có hồ sơ, hệ thống sẽ tạo khi bạn đặt lịch."],
  save: ["保存修改", "Save", "保存", "저장", "Сохранить", "Guardar", "Enregistrer", "บันทึก", "Lưu"],
  saving: ["保存中…", "Saving…", "保存中…", "저장 중…", "Сохранение…", "Guardando…", "Enregistrement…", "กำลังบันทึก…", "Đang lưu…"],
  saved: ["已保存", "Saved", "保存しました", "저장되었습니다", "Сохранено", "Guardado", "Enregistré", "บันทึกแล้ว", "Đã lưu"],
  kiosk_note: ["这是医院公共自助机：您的信息不会保存在本机，办完会自动清除。", "This is a hospital kiosk: your details are not saved here and are cleared when you finish.", "病院の共用端末です。情報はこの端末に保存されず、終了時に自動で消去されます。", "병원 공용 키오스크입니다. 정보는 이 기기에 저장되지 않으며 완료 후 자동 삭제됩니다.", "Это общий терминал больницы: ваши данные здесь не сохраняются и стираются по завершении.", "Este es un quiosco del hospital: sus datos no se guardan aquí y se borran al terminar.", "Borne publique de l'hôpital : vos données ne sont pas conservées et sont effacées à la fin.", "นี่คือตู้บริการสาธารณะของโรงพยาบาล ข้อมูลของคุณจะไม่ถูกบันทึกและจะถูกลบเมื่อเสร็จสิ้น", "Đây là máy tự phục vụ công cộng của bệnh viện: thông tin không được lưu và sẽ tự xóa khi xong."],
  kiosk_countdown: ["请记下就诊信息，{n} 秒后自动清除您的信息并返回首页", "Please note your details. Your information will be cleared in {n} s.", "受診情報を控えてください。{n} 秒後に情報を消去してトップに戻ります", "진료 정보를 메모하세요. {n}초 후 정보가 삭제되고 첫 화면으로 돌아갑니다", "Запишите данные визита. Через {n} с информация будет стёрта", "Anote los datos de su cita. Sus datos se borrarán en {n} s", "Notez vos informations. Elles seront effacées dans {n} s", "โปรดจดข้อมูลการนัด ข้อมูลของคุณจะถูกลบใน {n} วินาที", "Vui lòng ghi lại thông tin khám. Thông tin sẽ tự xóa sau {n} giây"],
  sex: ["性别", "Sex", "性別", "성별", "Пол", "Sexo", "Sexe", "เพศ", "Giới tính"],
  sex_choose: ["请选择", "Select", "選択してください", "선택하세요", "Выберите", "Seleccione", "Choisir", "โปรดเลือก", "Chọn"],
  sex_M: ["男", "Male", "男性", "남성", "Мужской", "Masculino", "Homme", "ชาย", "Nam"],
  sex_F: ["女", "Female", "女性", "여성", "Женский", "Femenino", "Femme", "หญิง", "Nữ"],
  v_sex: ["请选择性别", "Please select sex", "性別を選択してください", "성별을 선택하세요", "Укажите пол", "Seleccione el sexo", "Veuillez choisir le sexe", "โปรดเลือกเพศ", "Vui lòng chọn giới tính"],
  only_f: ["仅限女性", "Women only", "女性のみ", "여성 전용", "Только для женщин", "Solo mujeres", "Femmes uniquement", "เฉพาะผู้หญิง", "Chỉ nữ"],
  only_m: ["仅限男性", "Men only", "男性のみ", "남성 전용", "Только для мужчин", "Solo hombres", "Hommes uniquement", "เฉพาะผู้ชาย", "Chỉ nam"],
  e_only_f: ["该科室仅接诊女性患者", "This department only sees female patients.", "この診療科は女性患者のみ受け付けます", "이 진료과는 여성 환자만 진료합니다", "Это отделение принимает только женщин", "Este servicio solo atiende a mujeres", "Ce service ne reçoit que des patientes", "แผนกนี้รับเฉพาะผู้ป่วยหญิง", "Khoa này chỉ khám cho bệnh nhân nữ"],
  e_only_m: ["该科室仅接诊男性患者", "This department only sees male patients.", "この診療科は男性患者のみ受け付けます", "이 진료과는 남성 환자만 진료합니다", "Это отделение принимает только мужчин", "Este servicio solo atiende a hombres", "Ce service ne reçoit que des patients hommes", "แผนกนี้รับเฉพาะผู้ป่วยชาย", "Khoa này chỉ khám cho bệnh nhân nam"],
  ss_ph: ["输入文字搜索…", "Type to search…", "入力して検索…", "입력하여 검색…", "Введите для поиска…", "Escriba para buscar…", "Tapez pour rechercher…", "พิมพ์เพื่อค้นหา…", "Nhập để tìm…"],
  ss_none: ["没有匹配的选项", "No matches", "一致する項目がありません", "일치하는 항목이 없습니다", "Ничего не найдено", "Sin coincidencias", "Aucun résultat", "ไม่พบรายการที่ตรงกัน", "Không có kết quả phù hợp"],
  e_sex_mismatch: ["所选性别与该证件已登记的性别不一致，如需更正请到窗口办理", "The selected sex doesn't match the sex on file for this document. Please ask at the service desk to correct it.", "選択した性別がこの身分証の登録内容と一致しません。訂正は窓口でお手続きください。", "선택한 성별이 이 신분증에 등록된 성별과 다릅니다. 정정은 창구에서 해 주세요.", "Выбранный пол не совпадает с полом, указанным для этого документа. Для исправления обратитесь в регистратуру.", "El sexo seleccionado no coincide con el registrado para este documento. Para corregirlo, acuda al mostrador.", "Le sexe choisi ne correspond pas à celui enregistré pour ce document. Pour le corriger, adressez-vous à l'accueil.", "เพศที่เลือกไม่ตรงกับที่ลงทะเบียนไว้กับเอกสารนี้ หากต้องการแก้ไขโปรดติดต่อเคาน์เตอร์", "Giới tính đã chọn không khớp với giới tính đã đăng ký cho giấy tờ này. Vui lòng đến quầy để sửa."],
  remember_me: ["在本机记住就诊人", "Remember patient on this device", "この端末に患者情報を保存", "이 기기에 환자 정보 저장", "Запомнить пациента на этом устройстве", "Recordar paciente en este dispositivo", "Mémoriser le patient sur cet appareil", "จดจำผู้ป่วยบนอุปกรณ์นี้", "Ghi nhớ người bệnh trên thiết bị này"],
  remember_tip: ["仅限自己的手机或电脑。医院自助机、公用电脑请不要勾选：不勾选时信息不会保存，3 分钟无操作自动清除。", "Only on your own phone or computer. Don't tick this on hospital kiosks or shared computers: unticked, nothing is saved and details are cleared after 3 minutes of inactivity.", "ご自身の端末のみ。病院の受付機・共用PCではチェックしないでください。未チェックなら保存されず、3 分間操作がないと自動で消去されます。", "본인 휴대폰이나 컴퓨터에서만 사용하세요. 병원 키오스크·공용 PC에서는 체크하지 마세요. 체크하지 않으면 저장되지 않으며 3분간 조작이 없으면 자동 삭제됩니다.", "Только на своём телефоне или компьютере. Не отмечайте на больничных терминалах и общих ПК: без отметки ничего не сохраняется и данные стираются через 3 минуты бездействия.", "Solo en su propio teléfono u ordenador. No lo marque en quioscos del hospital ni equipos compartidos: sin marcar no se guarda nada y los datos se borran tras 3 minutos de inactividad.", "Uniquement sur votre téléphone ou ordinateur. Ne cochez pas sur les bornes de l'hôpital ou les ordinateurs partagés : sans coche, rien n'est enregistré et les données sont effacées après 3 minutes d'inactivité.", "ใช้เฉพาะโทรศัพท์หรือคอมพิวเตอร์ของคุณเอง อย่าเลือกบนตู้บริการหรือคอมพิวเตอร์สาธารณะของโรงพยาบาล หากไม่เลือก ข้อมูลจะไม่ถูกบันทึกและจะถูกลบเมื่อไม่มีการใช้งาน 3 นาที", "Chỉ dùng trên điện thoại hoặc máy tính của bạn. Không chọn trên máy tự phục vụ hay máy tính dùng chung của bệnh viện: khi không chọn, thông tin không được lưu và tự xóa sau 3 phút không thao tác."],
  done_clear: ["完成，清除我的信息", "Done – clear my details", "完了（情報を消去）", "완료 – 내 정보 삭제", "Готово — стереть мои данные", "Listo: borrar mis datos", "Terminé – effacer mes données", "เสร็จสิ้น – ลบข้อมูลของฉัน", "Xong – xóa thông tin của tôi"],
  switch_patient: ["切换就诊人 / 清除本机记录", "Switch patient / clear this device", "患者を切り替え／端末の記録を消去", "환자 전환 / 기기 기록 삭제", "Сменить пациента / очистить", "Cambiar paciente / borrar datos", "Changer de patient / effacer", "เปลี่ยนผู้ป่วย / ล้างข้อมูล", "Đổi bệnh nhân / xóa dữ liệu"],
  confirm_clear: ["确定清除本机保存的就诊人信息？", "Clear patient details saved on this device?", "この端末の患者情報を消去しますか？", "이 기기에 저장된 환자 정보를 삭제할까요?", "Удалить сохранённые данные пациента?", "¿Borrar los datos guardados en este dispositivo?", "Effacer les informations enregistrées sur cet appareil ?", "ล้างข้อมูลผู้ป่วยในเครื่องนี้หรือไม่?", "Xóa thông tin bệnh nhân đã lưu?"],
  cleared: ["已清除本机就诊人记录", "Cleared.", "消去しました", "삭제되었습니다", "Данные удалены", "Datos borrados", "Effacé", "ล้างแล้ว", "Đã xóa"],
  v_name_empty: ["姓名不能为空", "Name is required.", "氏名を入力してください。", "이름을 입력하세요.", "Укажите имя.", "El nombre es obligatorio.", "Le nom est obligatoire.", "กรุณากรอกชื่อ", "Vui lòng nhập tên."],
  v_phone_empty: ["手机号不能为空", "Mobile number is required.", "携帯番号を入力してください。", "휴대폰 번호를 입력하세요.", "Укажите телефон.", "El móvil es obligatorio.", "Le mobile est obligatoire.", "กรุณากรอกเบอร์โทร", "Vui lòng nhập số điện thoại."],

  /* ---------- 实名校验弹窗 ---------- */
  auth_h: ["实名校验", "Verify your identity", "本人確認", "본인 확인", "Подтверждение личности", "Verificar identidad", "Vérifier votre identité", "ยืนยันตัวตน", "Xác minh danh tính"],
  auth_tip: ["为保护隐私，查看或修改就诊人信息前需要校验一次姓名与证件，30 天内本机免校验。", "To protect your privacy, please confirm your name and ID once. This device will remember it for 30 days.", "プライバシー保護のため、氏名と身分証を一度確認します。この端末では30日間有効です。", "개인정보 보호를 위해 이름과 신분증을 한 번 확인합니다. 이 기기에서 30일간 유지됩니다.", "Для защиты данных подтвердите имя и документ. Устройство запомнит это на 30 дней.", "Para proteger su privacidad, confirme su nombre y documento. Se recordará 30 días.", "Pour protéger vos données, confirmez votre nom et votre pièce. Valable 30 jours sur cet appareil.", "เพื่อความเป็นส่วนตัว กรุณายืนยันชื่อและเอกสารหนึ่งครั้ง เครื่องนี้จะจำไว้ 30 วัน", "Để bảo vệ quyền riêng tư, vui lòng xác minh tên và giấy tờ một lần. Thiết bị sẽ ghi nhớ 30 ngày."],
  verify: ["校验", "Verify", "確認", "확인", "Подтвердить", "Verificar", "Vérifier", "ยืนยัน", "Xác minh"],
  cancel: ["取消", "Cancel", "キャンセル", "취소", "Отмена", "Cancelar", "Annuler", "ยกเลิก", "Hủy"],
  ok: ["确定", "OK", "OK", "확인", "OK", "Aceptar", "OK", "ตกลง", "OK"],

  /* ---------- 验证码弹窗 ---------- */
  cap_h: ["请先完成验证", "Quick check", "確認のお願い", "간단한 확인", "Проверка", "Verificación", "Vérification", "ตรวจสอบ", "Xác minh nhanh"],
  cap_why: ["该时段余号不多，需要验证一下不是脚本在抢号。", "Few slots left — please confirm you are not a bot.", "残りわずかのため、自動予約でないことを確認します。", "남은 자리가 적어 자동 예약이 아닌지 확인합니다.", "Мест мало — подтвердите, что вы не бот.", "Quedan pocas plazas: confirme que no es un robot.", "Peu de places : confirmez que vous n'êtes pas un robot.", "คิวเหลือน้อย กรุณายืนยันว่าไม่ใช่บอท", "Còn ít chỗ, vui lòng xác nhận bạn không phải robot."],
  answer: ["答案", "Answer", "答え", "답", "Ответ", "Respuesta", "Réponse", "คำตอบ", "Đáp án"],
  cap_tip: ["算错了可以点“换一题”。这道题 {n} 分钟内有效。", "You can get a new question. Valid for {n} min.", "別の問題に替えられます。{n}分間有効です。", "다른 문제로 바꿀 수 있습니다. {n}분간 유효합니다.", "Можно получить другой вопрос. Действует {n} мин.", "Puede pedir otra pregunta. Válida {n} min.", "Vous pouvez changer de question. Valable {n} min.", "เปลี่ยนคำถามได้ ใช้ได้ {n} นาที", "Có thể đổi câu hỏi. Hiệu lực {n} phút."],
  cap_refresh: ["换一题", "New question", "別の問題", "다른 문제", "Другой вопрос", "Otra pregunta", "Autre question", "คำถามใหม่", "Câu khác"],
  cap_fill: ["请填写答案", "Please enter the answer.", "答えを入力してください。", "답을 입력하세요.", "Введите ответ.", "Escriba la respuesta.", "Saisissez la réponse.", "กรุณากรอกคำตอบ", "Vui lòng nhập đáp án."],
  cap_load_fail: ["题目加载失败：", "Could not load question: ", "問題を読み込めませんでした：", "문제를 불러오지 못했습니다: ", "Не удалось загрузить вопрос: ", "No se pudo cargar: ", "Échec du chargement : ", "โหลดคำถามไม่สำเร็จ: ", "Không tải được câu hỏi: "],

  /* ---------- 候补 ---------- */
  wl_h: ["加入候补", "Join the waitlist", "キャンセル待ちに登録", "대기 신청", "Лист ожидания", "Lista de espera", "Liste d'attente", "ลงชื่อรอคิว", "Đăng ký chờ"],
  wl_why: ["{when} · {who} 已约满，可以排候补。", "{when} · {who} is fully booked — you can join the waitlist.", "{when} · {who} は満員です。キャンセル待ちに登録できます。", "{when} · {who} 마감 — 대기 신청할 수 있습니다.", "{when} · {who}: мест нет, можно встать в очередь.", "{when} · {who} está completo; puede apuntarse a la espera.", "{when} · {who} est complet ; inscrivez-vous sur liste d'attente.", "{when} · {who} เต็มแล้ว ลงชื่อรอคิวได้", "{when} · {who} đã kín, bạn có thể đăng ký chờ."],
  wl_tip: ["有人退号时会按排队顺序通知，号源为你保留 2 小时。", "When a slot opens we notify people in order and hold it for you for 2 hours.", "空きが出たら順番に通知し、2時間確保します。", "자리가 나면 순서대로 알리고 2시간 동안 보류해 드립니다.", "Когда освободится место, мы уведомим по очереди и придержим его 2 часа.", "Si se libera un hueco, avisamos por orden y se lo reservamos 2 horas.", "Si une place se libère, nous prévenons dans l'ordre et la réservons 2 heures.", "เมื่อมีคิวว่าง ระบบจะแจ้งตามลำดับและเก็บไว้ให้ 2 ชั่วโมง", "Khi có chỗ trống, hệ thống báo theo thứ tự và giữ chỗ 2 giờ."],
  wl_email_ph: ["选填，有空位时发邮件通知你", "Optional — we email you when a slot opens", "任意・空きが出たらメールで通知", "선택 — 자리가 나면 이메일로 알림", "Необязательно — сообщим письмом", "Opcional — le avisamos por correo", "Facultatif — nous vous écrirons", "ไม่บังคับ — แจ้งทางอีเมลเมื่อมีคิว", "Không bắt buộc — báo qua email khi có chỗ"],
  wl_submit: ["排队", "Join", "登録", "신청", "Встать в очередь", "Apuntarme", "M'inscrire", "ลงชื่อ", "Đăng ký"],
  wl_joined: ["已加入候补，排在第 {n} 位。有空位时会按顺序通知你，号源保留 2 小时。", "You're #{n} on the waitlist. We'll notify you in order and hold a slot for 2 hours.", "キャンセル待ち {n} 番目です。空きが出たら通知し、2時間確保します。", "대기 {n}번째입니다. 자리가 나면 알려 드리고 2시간 보류합니다.", "Вы №{n} в очереди. Мы уведомим вас и придержим место 2 часа.", "Es el n.º {n} en espera. Le avisaremos y reservaremos 2 horas.", "Vous êtes n° {n} sur la liste. Nous vous préviendrons et réserverons 2 heures.", "คุณอยู่ลำดับที่ {n} ระบบจะแจ้งและเก็บคิวไว้ 2 ชั่วโมง", "Bạn đứng thứ {n}. Hệ thống sẽ báo và giữ chỗ 2 giờ."],
  wl_s_waiting: ["排队中", "Waiting", "待機中", "대기 중", "В очереди", "En espera", "En attente", "รอคิว", "Đang chờ"],
  wl_s_offered: ["已通知", "Slot offered", "空きあり", "자리 확보", "Место предложено", "Plaza ofrecida", "Place proposée", "มีคิวว่าง", "Đã có chỗ"],
  wl_s_converted: ["已转正", "Booked", "予約済み", "예약됨", "Записан", "Reservada", "Réservé", "จองแล้ว", "Đã đặt"],
  wl_s_expired: ["已过期", "Expired", "期限切れ", "만료", "Истекло", "Caducada", "Expiré", "หมดอายุ", "Hết hạn"],
  wl_s_cancelled: ["已放弃", "Left", "取り消し", "포기", "Отказ", "Abandonada", "Abandonné", "ยกเลิก", "Đã bỏ"],
  wl_pos: ["第 {n} 位", "#{n}", "{n} 番目", "{n}번째", "№{n}", "N.º {n}", "N° {n}", "ลำดับ {n}", "Thứ {n}"],
  wl_confirm: ["确认挂号", "Book it", "予約する", "예약하기", "Записаться", "Reservar", "Réserver", "จองเลย", "Đặt lịch"],
  wl_giveup: ["放弃", "Decline", "辞退", "포기", "Отказаться", "Rechazar", "Refuser", "สละสิทธิ์", "Từ chối"],
  wl_leave: ["放弃排队", "Leave waitlist", "登録を取り消す", "대기 취소", "Покинуть очередь", "Salir de la espera", "Quitter la liste", "ออกจากคิว", "Rời danh sách"],
  wl_keep: ["号源为你保留到 {t}，过期自动顺延给下一位。", "Held for you until {t}; after that it goes to the next person.", "{t} まで確保します。過ぎると次の方に回ります。", "{t}까지 보류합니다. 이후에는 다음 분께 넘어갑니다.", "Место ваше до {t}, затем перейдёт следующему.", "Reservada hasta las {t}; después pasa al siguiente.", "Réservée jusqu'à {t}, puis proposée au suivant.", "เก็บไว้ให้ถึง {t} หลังจากนั้นจะส่งต่อคนถัดไป", "Giữ chỗ đến {t}, sau đó chuyển cho người kế tiếp."],
  wl_email_yes: ["已留邮箱，会收到邮件通知", "You'll get an email", "メールでお知らせします", "이메일로 알림", "Уведомим по почте", "Recibirá un correo", "Vous recevrez un e-mail", "จะได้รับอีเมล", "Sẽ nhận email"],
  wl_email_no: ["未留邮箱，只在站内通知", "No email — check your reminders here", "メール未登録・サイト内でお知らせ", "이메일 없음 — 사이트에서 알림", "Без почты — смотрите напоминания здесь", "Sin correo: revise los avisos aquí", "Sans e-mail : consultez vos rappels ici", "ไม่มีอีเมล — ดูการแจ้งเตือนที่นี่", "Không có email — xem nhắc nhở tại đây"],
  wl_live: ["生效中的候补 {a} 条 · 历史 {b} 条", "{a} active · {b} past", "有効 {a} 件 · 履歴 {b} 件", "진행 중 {a}건 · 지난 {b}건", "Активных: {a} · прошлых: {b}", "{a} activas · {b} anteriores", "{a} en cours · {b} passées", "ใช้งาน {a} · ประวัติ {b}", "{a} đang chờ · {b} trước đây"],
  wl_empty: ["还没有候补记录。号源约满时，在时段卡片上点“排候补”。", "No waitlist entries. When a time is full, tap “Join waitlist” on it.", "キャンセル待ちはありません。満員の時間帯で「キャンセル待ち」を押してください。", "대기 기록이 없습니다. 마감된 시간에서 '대기 신청'을 누르세요.", "Записей нет. На занятом времени нажмите «В лист ожидания».", "Sin registros. En un horario completo pulse «Lista de espera».", "Aucune inscription. Sur un créneau complet, appuyez sur « Liste d'attente ».", "ยังไม่มีรายการ เมื่อเวลาเต็มให้กด 'ลงชื่อรอคิว'", "Chưa có đăng ký. Khi khung giờ kín, bấm “Đăng ký chờ”."],
  wl_confirm_q: ["确认把保留的号挂下来？", "Book the slot being held for you?", "確保中の枠で予約しますか？", "보류 중인 자리로 예약할까요?", "Записаться на придержанное место?", "¿Reservar la plaza guardada?", "Réserver la place gardée pour vous ?", "จองคิวที่เก็บไว้หรือไม่?", "Đặt chỗ đang được giữ?"],
  wl_ok: ["候补转正成功，挂号单号 {id}，取号序号 {seq} 号", "Booked! No. {id}, queue no. {seq}.", "予約できました。番号 {id}、受付番号 {seq}。", "예약 완료! 번호 {id}, 순번 {seq}.", "Вы записаны! № {id}, очередь {seq}.", "¡Reservada! N.º {id}, turno {seq}.", "Réservé ! N° {id}, passage {seq}.", "จองสำเร็จ เลขที่ {id} ลำดับ {seq}", "Đặt thành công! Mã {id}, số {seq}."],
  wl_cancel_q: ["确认放弃这个候补？放弃后位置就没了。", "Leave this waitlist? You will lose your place.", "取り消すと順番がなくなります。よろしいですか？", "취소하면 순서가 사라집니다. 계속할까요?", "Покинуть очередь? Место будет потеряно.", "¿Salir de la espera? Perderá su puesto.", "Quitter la liste ? Vous perdrez votre place.", "ออกจากคิวหรือไม่? จะเสียลำดับ", "Rời danh sách? Bạn sẽ mất vị trí."],

  /* ---------- 服务端提示（按中文原文匹配后翻译） ---------- */
  e_network: ["连不上服务器，请稍后再试", "Cannot reach the server. Please try again later.", "サーバーに接続できません。後でもう一度お試しください。", "서버에 연결할 수 없습니다. 잠시 후 다시 시도하세요.", "Нет связи с сервером. Попробуйте позже.", "No se puede conectar con el servidor.", "Impossible de joindre le serveur.", "เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ ลองใหม่ภายหลัง", "Không kết nối được máy chủ, vui lòng thử lại."],
  e_auth: ["为保护隐私，请先验证就诊人身份", "To protect your privacy, please verify the patient's identity first.", "プライバシー保護のため、まず本人確認をしてください。", "개인정보 보호를 위해 먼저 본인 확인을 해 주세요.", "Для защиты данных сначала подтвердите личность пациента.", "Para proteger su privacidad, verifique primero la identidad.", "Pour protéger vos données, vérifiez d'abord l'identité du patient.", "เพื่อความเป็นส่วนตัว กรุณายืนยันตัวตนก่อน", "Để bảo vệ quyền riêng tư, vui lòng xác minh danh tính trước."],
  e_realname: ["实名校验未通过：姓名与证件号不匹配，请核对后重试", "Identity check failed: the name does not match this ID. Please check and try again.", "本人確認に失敗しました。氏名と番号が一致しません。", "본인 확인 실패: 이름과 신분증이 일치하지 않습니다.", "Проверка не пройдена: имя не совпадает с документом.", "Verificación fallida: el nombre no coincide con el documento.", "Échec de la vérification : le nom ne correspond pas à la pièce.", "ยืนยันตัวตนไม่ผ่าน: ชื่อไม่ตรงกับเอกสาร", "Xác minh thất bại: tên không khớp với giấy tờ."],
  e_no_record: ["实名校验通过，但还没有就诊档案，挂一次号即可自动建档", "Verified, but you have no records yet — one is created when you book.", "確認できましたが、まだ記録がありません。予約すると作成されます。", "확인되었지만 아직 기록이 없습니다. 예약하면 생성됩니다.", "Личность подтверждена, но записей пока нет.", "Verificado, pero aún no tiene historial.", "Vérifié, mais aucun dossier pour l'instant.", "ยืนยันแล้ว แต่ยังไม่มีประวัติ", "Đã xác minh nhưng chưa có hồ sơ."],
  e_full: ["该时段号源已挂完，请选择其他时段", "This time is fully booked. Please choose another.", "この時間帯は満員です。", "이 시간은 마감되었습니다.", "На это время мест нет.", "Este horario está completo.", "Ce créneau est complet.", "เวลานี้เต็มแล้ว", "Khung giờ này đã kín."],
  e_dup: ["您已预约该时段，请勿重复挂号", "You already have this appointment.", "この時間帯はすでに予約済みです。", "이미 이 시간을 예약했습니다.", "Вы уже записаны на это время.", "Ya tiene esta cita.", "Vous avez déjà ce rendez-vous.", "คุณจองเวลานี้แล้ว", "Bạn đã đặt khung giờ này."],
  e_same_dept: ["同一就诊人当天在该科室已有有效预约，请勿重复挂号", "You already have an appointment in this department that day.", "同じ日にこの診療科の予約があります。", "같은 날 이 진료과 예약이 이미 있습니다.", "У вас уже есть запись в это отделение в этот день.", "Ya tiene una cita en este departamento ese día.", "Vous avez déjà un rendez-vous dans ce service ce jour-là.", "คุณมีนัดแผนกนี้ในวันเดียวกันแล้ว", "Bạn đã có lịch ở khoa này trong ngày."],
  e_max2: ["同一就诊人同一天最多预约 2 个号，请先取消不需要的", "You can book at most 2 appointments per day.", "1日の予約は2件までです。", "하루 최대 2건까지 예약할 수 있습니다.", "Не более 2 записей в день.", "Máximo 2 citas por día.", "Maximum 2 rendez-vous par jour.", "จองได้สูงสุดวันละ 2 คิว", "Tối đa 2 lịch hẹn mỗi ngày."],
  e_cancel_limit: ["近 30 天取消次数过多，请到院窗口办理", "Too many cancellations in 30 days. Please book at the hospital counter.", "30日間のキャンセルが多すぎます。窓口で手続きしてください。", "30일 내 취소가 너무 많습니다. 병원 창구를 이용하세요.", "Слишком много отмен за 30 дней. Обратитесь в регистратуру.", "Demasiadas cancelaciones en 30 días. Acuda al mostrador.", "Trop d'annulations en 30 jours. Adressez-vous au guichet.", "ยกเลิกบ่อยเกินไปใน 30 วัน กรุณาติดต่อเคาน์เตอร์", "Hủy quá nhiều trong 30 ngày. Vui lòng đến quầy."],
  e_noshow_limit: ["多次爽约，已暂停线上挂号，请到院窗口办理", "Online booking is paused after several missed visits. Please go to the counter.", "無断欠席が多いためオンライン予約を停止しています。窓口へお越しください。", "노쇼가 많아 온라인 예약이 중지되었습니다. 창구를 이용하세요.", "Онлайн-запись приостановлена из-за неявок. Обратитесь в регистратуру.", "Citas en línea suspendidas por ausencias. Acuda al mostrador.", "Réservation en ligne suspendue après des absences. Allez au guichet.", "ระงับการจองออนไลน์เพราะผิดนัดหลายครั้ง", "Tạm khóa đặt trực tuyến do vắng nhiều lần."],
  e_blacklist: ["该就诊人已被限制挂号，请联系门诊服务台", "Booking is restricted for this patient. Please contact the service desk.", "この患者は予約が制限されています。受付にお問い合わせください。", "이 환자는 예약이 제한되었습니다. 안내 데스크에 문의하세요.", "Запись для пациента ограничена. Обратитесь в справочную.", "Las citas de este paciente están restringidas.", "Les rendez-vous de ce patient sont restreints.", "ผู้ป่วยนี้ถูกจำกัดการจอง กรุณาติดต่อเคาน์เตอร์", "Bệnh nhân bị hạn chế đặt lịch, vui lòng liên hệ quầy."],
  e_closed: ["该医生已停诊，无法挂号", "This doctor is not available at this time.", "この医師はこの時間休診です。", "이 의사는 이 시간에 진료하지 않습니다.", "Врач в это время не принимает.", "El médico no atiende en este horario.", "Le médecin ne consulte pas à ce moment.", "แพทย์งดตรวจในเวลานี้", "Bác sĩ nghỉ khám giờ này."],
  e_past: ["不能预约已过去的日期", "You cannot book a past date.", "過去の日付は予約できません。", "지난 날짜는 예약할 수 없습니다.", "Нельзя записаться на прошедшую дату.", "No puede reservar una fecha pasada.", "Impossible de réserver une date passée.", "จองวันที่ผ่านมาแล้วไม่ได้", "Không thể đặt ngày đã qua."],
  e_rate: ["请求过于频繁，请稍后再试", "Too many requests. Please wait a moment.", "操作が多すぎます。しばらくお待ちください。", "요청이 너무 많습니다. 잠시 후 다시 시도하세요.", "Слишком много запросов. Подождите.", "Demasiadas solicitudes. Espere un momento.", "Trop de requêtes. Patientez un instant.", "ส่งคำขอบ่อยเกินไป กรุณารอสักครู่", "Quá nhiều yêu cầu, vui lòng chờ."],
};

/* 服务端报错是中文：按原文里的关键字认出是哪一种，换成当前语言。认不出来就原样显示 */
const SERVER_ERRORS = [
  ['已登记的性别不一致', 'e_sex_mismatch'],
  ['仅接诊女性', 'e_only_f'],
  ['仅接诊男性', 'e_only_m'],
  ['请选择性别', 'v_sex'],
  ['请先验证就诊人身份', 'e_auth'],
  ['实名校验未通过', 'e_realname'],
  ['还没有就诊档案', 'e_no_record'],
  ['号源已挂完', 'e_full'],
  ['已预约该时段', 'e_dup'],
  ['在该科室已有有效预约', 'e_same_dept'],
  ['最多预约 2 个号', 'e_max2'],
  ['次挂号，超出限制', 'e_cancel_limit'],
  ['已暂停线上挂号', 'e_noshow_limit'],
  ['限制挂号', 'e_blacklist'],
  ['已停诊', 'e_closed'],
  ['已过去的日期', 'e_past'],
  ['请求过于频繁', 'e_rate'],
  ['连不上服务器', 'e_network'],
];

let LANG = 'zh';

function langIndex() {
  for (let i = 0; i < LANGS.length; i++) { if (LANGS[i][0] === LANG) return i; }
  return 0;
}

/* 取词条。vars 里的值替换 {名字} 占位符 */
function t(key, vars) {
  const row = I18N[key];
  let s = row ? (row[langIndex()] || row[0]) : key;
  if (vars) {
    for (const k in vars) s = s.split('{' + k + '}').join(vars[k]);
  }
  return s;
}

/* 服务端的中文报错 → 当前语言 */
function trError(msg) {
  if (!msg || LANG === 'zh') return msg;
  for (let i = 0; i < SERVER_ERRORS.length; i++) {
    if (msg.indexOf(SERVER_ERRORS[i][0]) >= 0) return t(SERVER_ERRORS[i][1]);
  }
  return msg;
}

/* 当前语言对应的 BCP 47 代码（给 Intl 格式化日期、国家名用） */
function langTag() { return LANGS[langIndex()][2]; }

function detectLang() {
  try {
    const saved = localStorage.getItem(LANG_KEY);
    if (saved) return saved;
  } catch (e) { /* 读不到就按浏览器语言 */ }
  const nav = (navigator.language || 'zh').toLowerCase();
  for (let i = 0; i < LANGS.length; i++) { if (nav.indexOf(LANGS[i][0]) === 0) return LANGS[i][0]; }
  return 'zh';
}

/* 静态页面上的文字：data-i18n 换正文，data-i18n-ph 换占位提示，data-i18n-title 换悬停提示 */
function applyI18n(root) {
  root = root || document;
  root.querySelectorAll('[data-i18n]').forEach(function (el) { el.innerHTML = t(el.getAttribute('data-i18n')); });
  root.querySelectorAll('[data-i18n-ph]').forEach(function (el) { el.placeholder = t(el.getAttribute('data-i18n-ph')); });
  root.querySelectorAll('[data-i18n-title]').forEach(function (el) { el.title = t(el.getAttribute('data-i18n-title')); });
  document.documentElement.lang = langTag();
  document.title = t('brand');
}
