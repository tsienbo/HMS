/* ============================================================
 * 多语言：科室、医生、职称、院内位置、国家与区号
 * 语言顺序同 i18n.js 的 LANGS：zh / en / ja / ko / ru / es / fr / th / vi
 * 数据库里存的是中文，这里只负责「给外国患者看时怎么显示」。
 * ============================================================ */

/* 科室名称与简介（编号与 seed_data.DEPARTMENTS 一致） */
const DEPT_TR = {
  D01: { name: ["内科", "Internal Medicine", "内科", "내과", "Терапия", "Medicina Interna", "Médecine interne", "อายุรกรรม", "Nội khoa"],
         desc: ["感冒发热、高血压、糖尿病等常见内科疾病", "Colds, fever, high blood pressure, diabetes and other common illnesses", "風邪・発熱・高血圧・糖尿病などの一般的な内科疾患", "감기·발열·고혈압·당뇨병 등 일반 내과 질환", "Простуда, температура, давление, диабет и другие частые болезни", "Resfriados, fiebre, hipertensión, diabetes y otras dolencias comunes", "Rhumes, fièvre, hypertension, diabète et autres maladies courantes", "หวัด ไข้ ความดันสูง เบาหวาน และโรคทั่วไป", "Cảm sốt, cao huyết áp, tiểu đường và các bệnh nội khoa thường gặp"] },
  D02: { name: ["外科", "General Surgery", "外科", "외과", "Хирургия", "Cirugía General", "Chirurgie générale", "ศัลยกรรม", "Ngoại khoa"],
         desc: ["外伤处理、体表肿物、术后复查", "Injuries, lumps and bumps, post-operative check-ups", "けがの処置・体表のしこり・術後の診察", "외상 처치·체표 종양·수술 후 검진", "Травмы, новообразования на коже, послеоперационные осмотры", "Heridas, bultos y revisiones postoperatorias", "Blessures, masses cutanées, suivi post-opératoire", "รักษาบาดแผล ก้อนเนื้อ และตรวจหลังผ่าตัด", "Xử lý chấn thương, khối u ngoài da, tái khám sau mổ"] },
  D03: { name: ["儿科", "Pediatrics", "小児科", "소아과", "Педиатрия", "Pediatría", "Pédiatrie", "กุมารเวชกรรม", "Nhi khoa"],
         desc: ["0-14 岁儿童常见病、生长发育咨询", "Common illnesses and growth advice for children aged 0–14", "0〜14歳の子どもの病気・発育相談", "0~14세 어린이 질환·성장 상담", "Детские болезни и развитие (0–14 лет)", "Enfermedades comunes y desarrollo de 0 a 14 años", "Maladies courantes et croissance des 0–14 ans", "โรคเด็กและพัฒนาการ อายุ 0–14 ปี", "Bệnh thường gặp và tư vấn phát triển cho trẻ 0–14 tuổi"] },
  D04: { name: ["骨科", "Orthopedics", "整形外科", "정형외과", "Ортопедия", "Traumatología", "Orthopédie", "ศัลยกรรมกระดูก", "Chấn thương chỉnh hình"],
         desc: ["骨折、关节疼痛、颈腰椎疾病", "Fractures, joint pain, neck and back problems", "骨折・関節痛・首や腰の病気", "골절·관절통·목과 허리 질환", "Переломы, боли в суставах, шея и спина", "Fracturas, dolor articular, cuello y espalda", "Fractures, douleurs articulaires, cou et dos", "กระดูกหัก ปวดข้อ ปวดคอและหลัง", "Gãy xương, đau khớp, bệnh cột sống cổ và thắt lưng"] },
  D05: { name: ["眼科", "Ophthalmology", "眼科", "안과", "Офтальмология", "Oftalmología", "Ophtalmologie", "จักษุวิทยา", "Nhãn khoa"],
         desc: ["视力检查、结膜炎、白内障筛查", "Eye tests, conjunctivitis, cataract screening", "視力検査・結膜炎・白内障の検査", "시력 검사·결막염·백내장 검진", "Проверка зрения, конъюнктивит, катаракта", "Revisión de la vista, conjuntivitis, cataratas", "Examen de la vue, conjonctivite, cataracte", "ตรวจสายตา ตาแดง คัดกรองต้อกระจก", "Đo thị lực, viêm kết mạc, tầm soát đục thủy tinh thể"] },
  D06: { name: ["妇产科", "Obstetrics & Gynecology", "産婦人科", "산부인과", "Гинекология и акушерство", "Ginecología y Obstetricia", "Gynécologie-obstétrique", "สูตินรีเวช", "Sản phụ khoa"],
         desc: ["月经不调、妇科炎症、孕期检查与产后复查", "Period problems, gynecological infections, pregnancy and postnatal check-ups", "月経不順・婦人科の炎症・妊婦健診と産後健診", "생리불순·부인과 염증·임신 검진과 산후 검진", "Нарушения цикла, воспаления, ведение беременности", "Trastornos menstruales, infecciones, control de embarazo", "Troubles des règles, infections, suivi de grossesse", "ประจำเดือนผิดปกติ การอักเสบ ฝากครรภ์และตรวจหลังคลอด", "Rối loạn kinh nguyệt, viêm phụ khoa, khám thai và sau sinh"] },
  D07: { name: ["皮肤科", "Dermatology", "皮膚科", "피부과", "Дерматология", "Dermatología", "Dermatologie", "ผิวหนัง", "Da liễu"],
         desc: ["湿疹、痤疮、皮炎、荨麻疹、真菌感染", "Eczema, acne, dermatitis, hives, fungal infections", "湿疹・にきび・皮膚炎・じんましん・真菌感染", "습진·여드름·피부염·두드러기·진균 감염", "Экзема, акне, дерматит, крапивница, грибок", "Eccema, acné, dermatitis, urticaria, hongos", "Eczéma, acné, dermatite, urticaire, mycoses", "ผื่นแพ้ สิว ผิวหนังอักเสบ ลมพิษ เชื้อรา", "Chàm, mụn, viêm da, mề đay, nấm da"] },
  D08: { name: ["耳鼻喉科", "ENT", "耳鼻咽喉科", "이비인후과", "ЛОР", "Otorrinolaringología", "ORL", "หู คอ จมูก", "Tai mũi họng"],
         desc: ["鼻炎、咽喉炎、中耳炎、听力下降", "Rhinitis, sore throat, ear infections, hearing loss", "鼻炎・咽喉炎・中耳炎・難聴", "비염·인후염·중이염·청력 저하", "Насморк, ангина, отит, снижение слуха", "Rinitis, faringitis, otitis, pérdida de audición", "Rhinite, mal de gorge, otite, perte auditive", "จมูกอักเสบ คอหอยอักเสบ หูชั้นกลางอักเสบ การได้ยินลดลง", "Viêm mũi, viêm họng, viêm tai giữa, giảm thính lực"] },
  D09: { name: ["口腔科", "Dental", "歯科", "치과", "Стоматология", "Odontología", "Dentaire", "ทันตกรรม", "Răng hàm mặt"],
         desc: ["牙痛、龋齿、牙周病、口腔溃疡", "Toothache, cavities, gum disease, mouth ulcers", "歯痛・虫歯・歯周病・口内炎", "치통·충치·잇몸병·구내염", "Зубная боль, кариес, дёсны, язвочки во рту", "Dolor de muelas, caries, encías, aftas", "Mal de dents, caries, gencives, aphtes", "ปวดฟัน ฟันผุ โรคเหงือก แผลในปาก", "Đau răng, sâu răng, nha chu, nhiệt miệng"] },
  D10: { name: ["中医科", "Traditional Chinese Medicine", "中医科", "한의과", "Традиционная китайская медицина", "Medicina Tradicional China", "Médecine traditionnelle chinoise", "แพทย์แผนจีน", "Y học cổ truyền"],
         desc: ["中医调理、针灸推拿、慢性病调养", "Herbal medicine, acupuncture, massage, chronic conditions", "漢方・鍼灸・推拿・慢性疾患のケア", "한방 치료·침·추나·만성질환 관리", "Фитотерапия, иглоукалывание, массаж, хронические болезни", "Herbolaria, acupuntura, masaje, enfermedades crónicas", "Phytothérapie, acupuncture, massage, maladies chroniques", "สมุนไพรจีน ฝังเข็ม นวด โรคเรื้อรัง", "Thuốc bắc, châm cứu, xoa bóp, bệnh mạn tính"] },
  D11: { name: ["精神心理科", "Psychiatry & Psychology", "精神科・心療内科", "정신건강의학과", "Психиатрия и психология", "Psiquiatría y Psicología", "Psychiatrie et psychologie", "จิตเวชและจิตวิทยา", "Tâm thần – Tâm lý"],
         desc: ["失眠、焦虑、抑郁、心理咨询", "Insomnia, anxiety, depression, counselling", "不眠・不安・うつ・カウンセリング", "불면·불안·우울·심리 상담", "Бессонница, тревога, депрессия, консультации", "Insomnio, ansiedad, depresión, orientación", "Insomnie, anxiété, dépression, soutien psychologique", "นอนไม่หลับ วิตกกังวล ซึมเศร้า ให้คำปรึกษา", "Mất ngủ, lo âu, trầm cảm, tư vấn tâm lý"] },
  D12: { name: ["肿瘤科", "Oncology", "腫瘍科", "종양내과", "Онкология", "Oncología", "Oncologie", "มะเร็งวิทยา", "Ung bướu"],
         desc: ["肿瘤筛查、放化疗随访、肿瘤综合治疗", "Cancer screening, chemo- and radiotherapy follow-up, cancer care", "がん検診・化学療法と放射線療法の経過観察・総合治療", "암 검진·항암·방사선 치료 추적·종합 치료", "Скрининг, наблюдение после химио- и лучевой терапии", "Cribado, seguimiento de quimio y radioterapia", "Dépistage, suivi de chimio et radiothérapie", "คัดกรองมะเร็ง ติดตามเคมีบำบัดและรังสีรักษา", "Tầm soát ung thư, theo dõi hóa trị và xạ trị"] },
  D13: { name: ["男科", "Andrology", "男性科", "남성의학과", "Андрология", "Andrología", "Andrologie", "เวชศาสตร์ชาย", "Nam khoa"],
         desc: ["前列腺疾病、男性泌尿生殖问题", "Prostate and male urological problems", "前立腺の病気・男性の泌尿生殖器の問題", "전립선 질환·남성 비뇨생식기 문제", "Простата и мужская урология", "Próstata y salud urológica masculina", "Prostate et urologie masculine", "ต่อมลูกหมากและระบบทางเดินปัสสาวะชาย", "Bệnh tuyến tiền liệt, tiết niệu sinh dục nam"] },
};

/* 职称 */
const TITLE_TR = {
  "主任医师": ["主任医师", "Chief Physician", "主任医師", "주임의사", "Главный врач", "Médico Jefe", "Médecin chef", "แพทย์หัวหน้า", "Bác sĩ trưởng"],
  "副主任医师": ["副主任医师", "Associate Chief Physician", "副主任医師", "부주임의사", "Заместитель главного врача", "Médico Jefe Adjunto", "Médecin chef adjoint", "รองแพทย์หัวหน้า", "Phó bác sĩ trưởng"],
  "主治医师": ["主治医师", "Attending Physician", "主治医", "전문의", "Лечащий врач", "Médico Adjunto", "Médecin traitant", "แพทย์ประจำ", "Bác sĩ điều trị"],
};

/* 医生姓名的拼音（中文界面不用；其他语言显示「中文名 (拼音)」，方便到院后对照门牌） */
const DOCTOR_PINYIN = {
  DR01: 'Zhang Jianguo', DR02: 'Li Huimin', DR03: 'Wang Zhenyu', DR04: 'Chen Guoqiang', DR05: 'Liu Wenbo',
  DR06: 'Zhao Xiaoping', DR07: 'Sun Ning', DR08: 'Zhou Haitao', DR09: 'Wu Lei', DR10: 'Zheng Xiaolan',
  DR11: 'Lin Yaqin', DR12: 'He Jing', DR13: 'Xu Wenhua', DR14: 'Peng Yue', DR15: 'Fang Lixin',
  DR16: 'Song Jia', DR17: 'Tang Mingyuan', DR18: 'Han Xue', DR19: 'Huang Dechang', DR20: 'Deng Xin',
  DR21: 'Cao Lei', DR22: 'Luo Chen', DR23: 'Wei Dongsheng', DR24: 'Jiang Ting', DR25: 'Feng Zhigang', DR26: 'Xue Kai',
};

/* 医生擅长方向（中文在 app.js 的 DOCTOR_INTRO；这里是其他八种语言，顺序 en / ja / ko / ru / es / fr / th / vi） */
const INTRO_TR = {
  DR01: ["Hypertension, coronary heart disease, arrhythmia", "高血圧・冠動脈疾患・不整脈", "고혈압·관상동맥질환·부정맥", "Гипертония, ИБС, аритмия", "Hipertensión, cardiopatía coronaria, arritmias", "Hypertension, maladie coronarienne, arythmie", "ความดันสูง โรคหลอดเลือดหัวใจ หัวใจเต้นผิดจังหวะ", "Tăng huyết áp, bệnh mạch vành, rối loạn nhịp tim"],
  DR02: ["Diabetes, thyroid disease, hormonal disorders", "糖尿病・甲状腺疾患・内分泌異常", "당뇨병·갑상선 질환·내분비 이상", "Диабет, щитовидная железа, эндокринные нарушения", "Diabetes, tiroides, trastornos hormonales", "Diabète, thyroïde, troubles hormonaux", "เบาหวาน โรคไทรอยด์ ฮอร์โมนผิดปกติ", "Tiểu đường, tuyến giáp, rối loạn nội tiết"],
  DR03: ["Respiratory infections, gastroenteritis, general medicine", "呼吸器感染症・胃腸炎・一般内科", "호흡기 감염·위장염·일반 내과", "Инфекции дыхательных путей, гастроэнтерит", "Infecciones respiratorias, gastroenteritis", "Infections respiratoires, gastro-entérite", "ติดเชื้อทางเดินหายใจ กระเพาะลำไส้อักเสบ", "Nhiễm trùng hô hấp, viêm dạ dày ruột, nội tổng quát"],
  DR04: ["General surgery, gallbladder disease, hernia", "一般外科手術・胆のう疾患・ヘルニア", "일반외과 수술·담낭 질환·탈장", "Общая хирургия, желчный пузырь, грыжи", "Cirugía general, vesícula biliar, hernias", "Chirurgie générale, vésicule biliaire, hernies", "ผ่าตัดทั่วไป ถุงน้ำดี ไส้เลื่อน", "Phẫu thuật tổng quát, túi mật, thoát vị"],
  DR05: ["Wound care, removal of skin lumps", "外傷の処置・体表のしこりの切除", "상처 처치·체표 종양 제거", "Обработка ран, удаление образований кожи", "Curas de heridas, extirpación de bultos", "Soins des plaies, ablation de masses cutanées", "ทำแผล ตัดก้อนเนื้อใต้ผิวหนัง", "Xử lý vết thương, cắt bỏ khối u ngoài da"],
  DR06: ["Children's respiratory infections, diarrhea, allergies", "小児の呼吸器感染症・下痢・アレルギー", "소아 호흡기 감염·설사·알레르기", "Детские инфекции дыхательных путей, диарея, аллергия", "Infecciones respiratorias infantiles, diarrea, alergias", "Infections respiratoires de l'enfant, diarrhée, allergies", "ติดเชื้อทางเดินหายใจในเด็ก ท้องเสีย ภูมิแพ้", "Nhiễm trùng hô hấp ở trẻ, tiêu chảy, dị ứng"],
  DR07: ["Newborn jaundice, child health, vaccinations", "新生児黄疸・小児保健・予防接種相談", "신생아 황달·소아 보건·예방접종 상담", "Желтуха новорождённых, здоровье детей, прививки", "Ictericia neonatal, salud infantil, vacunas", "Ictère du nouveau-né, santé de l'enfant, vaccins", "ตัวเหลืองในทารก สุขภาพเด็ก วัคซีน", "Vàng da sơ sinh, chăm sóc trẻ, tiêm chủng"],
  DR08: ["Joint replacement, minimally invasive spine surgery, complex fractures", "人工関節・脊椎低侵襲手術・複雑骨折", "인공관절·척추 최소침습·복합 골절", "Эндопротезирование, малоинвазивная хирургия позвоночника", "Prótesis articulares, columna mínimamente invasiva, fracturas complejas", "Prothèses articulaires, chirurgie mini-invasive du rachis, fractures complexes", "เปลี่ยนข้อ ผ่าตัดกระดูกสันหลังแผลเล็ก กระดูกหักซับซ้อน", "Thay khớp, mổ cột sống ít xâm lấn, gãy xương phức tạp"],
  DR09: ["Fracture treatment, sports injuries, lower back strain", "骨折整復・スポーツ外傷・腰痛", "골절 정복·스포츠 손상·요통", "Лечение переломов, спортивные травмы, боли в пояснице", "Fracturas, lesiones deportivas, lumbalgia", "Fractures, blessures sportives, lombalgie", "จัดกระดูก บาดเจ็บจากกีฬา ปวดหลัง", "Nắn xương, chấn thương thể thao, đau lưng"],
  DR10: ["Cataract, glaucoma, retinal disease", "白内障・緑内障・眼底疾患", "백내장·녹내장·망막 질환", "Катаракта, глаукома, болезни сетчатки", "Cataratas, glaucoma, retina", "Cataracte, glaucome, rétine", "ต้อกระจก ต้อหิน โรคจอประสาทตา", "Đục thủy tinh thể, tăng nhãn áp, bệnh võng mạc"],
  DR11: ["Gynecological tumors, menstrual disorders, high-risk pregnancy", "婦人科腫瘍・月経異常・ハイリスク妊娠", "부인과 종양·월경 이상·고위험 임신", "Гинекологические опухоли, нарушения цикла, беременность высокого риска", "Tumores ginecológicos, trastornos menstruales, embarazo de riesgo", "Tumeurs gynécologiques, troubles des règles, grossesse à risque", "เนื้องอกทางนรีเวช ประจำเดือนผิดปกติ ครรภ์เสี่ยงสูง", "U phụ khoa, rối loạn kinh nguyệt, thai kỳ nguy cơ cao"],
  DR12: ["Gynecological infections, prenatal care, postnatal check-ups", "婦人科の炎症・妊婦健診・産後健診", "부인과 염증·산전 관리·산후 검진", "Воспаления, ведение беременности, послеродовые осмотры", "Infecciones ginecológicas, control prenatal y posparto", "Infections gynécologiques, suivi prénatal et postnatal", "การอักเสบทางนรีเวช ฝากครรภ์ ตรวจหลังคลอด", "Viêm phụ khoa, khám thai, khám sau sinh"],
  DR13: ["Eczema, psoriasis, allergic skin disease", "湿疹・乾癬・アレルギー性皮膚疾患", "습진·건선·알레르기성 피부질환", "Экзема, псориаз, аллергические заболевания кожи", "Eccema, psoriasis, alergias cutáneas", "Eczéma, psoriasis, allergies cutanées", "ผื่นแพ้ สะเก็ดเงิน ผิวหนังแพ้ง่าย", "Chàm, vảy nến, dị ứng da"],
  DR14: ["Acne, dermatitis, fungal infections", "にきび・皮膚炎・真菌感染", "여드름·피부염·진균 감염", "Акне, дерматит, грибковые инфекции", "Acné, dermatitis, hongos", "Acné, dermatite, mycoses", "สิว ผิวหนังอักเสบ เชื้อรา", "Mụn, viêm da, nấm da"],
  DR15: ["Sinusitis, throat disorders, nasal endoscopic surgery", "副鼻腔炎・咽喉疾患・内視鏡下鼻手術", "부비동염·인후 질환·코 내시경 수술", "Синусит, болезни горла, эндоскопия носа", "Sinusitis, garganta, cirugía endoscópica nasal", "Sinusite, gorge, chirurgie endoscopique nasale", "ไซนัสอักเสบ โรคคอ ผ่าตัดส่องกล้องจมูก", "Viêm xoang, bệnh họng, phẫu thuật nội soi mũi"],
  DR16: ["Ear infections, allergic rhinitis, hearing tests", "中耳炎・アレルギー性鼻炎・聴力検査", "중이염·알레르기 비염·청력 검사", "Отит, аллергический ринит, проверка слуха", "Otitis, rinitis alérgica, audiometría", "Otite, rhinite allergique, audiométrie", "หูชั้นกลางอักเสบ ภูมิแพ้จมูก ตรวจการได้ยิน", "Viêm tai giữa, viêm mũi dị ứng, đo thính lực"],
  DR17: ["Gum disease, dental restoration, implant consultation", "歯周病・補綴治療・インプラント相談", "잇몸병·보철 치료·임플란트 상담", "Пародонт, протезирование, импланты", "Encías, prótesis dentales, implantes", "Parodontie, prothèses, implants", "โรคเหงือก ทำฟันปลอม ปรึกษารากฟันเทียม", "Nha chu, phục hình răng, tư vấn cấy ghép"],
  DR18: ["Fillings, root canal treatment, mouth ulcers", "虫歯の充填・根管治療・口内炎", "충치 치료·신경 치료·구내염", "Пломбы, лечение каналов, язвочки во рту", "Empastes, endodoncias, aftas", "Plombages, traitement de canal, aphtes", "อุดฟัน รักษารากฟัน แผลในปาก", "Trám răng, chữa tủy, nhiệt miệng"],
  DR19: ["Chronic stomach problems, sleep problems, acupuncture and massage", "慢性胃炎・不眠の調整・鍼灸推拿", "만성 위장병·불면 조절·침·추나", "Хронические болезни желудка, сон, иглоукалывание", "Problemas gástricos crónicos, sueño, acupuntura", "Troubles gastriques chroniques, sommeil, acupuncture", "โรคกระเพาะเรื้อรัง ปรับการนอน ฝังเข็ม", "Bệnh dạ dày mạn tính, mất ngủ, châm cứu xoa bóp"],
  DR20: ["Body constitution care, neck/shoulder/back pain, herbal medicine", "体質改善・首肩腰の痛み・漢方", "체질 개선·목·어깨·허리 통증·한약", "Укрепление организма, боли в шее и спине, травы", "Constitución, dolor de cuello y espalda, hierbas", "Constitution, douleurs cou et dos, plantes", "ปรับสมดุลร่างกาย ปวดคอบ่าหลัง ยาจีน", "Điều chỉnh thể trạng, đau cổ vai lưng, thuốc bắc"],
  DR21: ["Depression, anxiety, sleep disorders", "うつ・不安・睡眠障害", "우울·불안·수면 장애", "Депрессия, тревога, нарушения сна", "Depresión, ansiedad, trastornos del sueño", "Dépression, anxiété, troubles du sommeil", "ซึมเศร้า วิตกกังวล นอนไม่หลับ", "Trầm cảm, lo âu, rối loạn giấc ngủ"],
  DR22: ["Counselling, emotional management, stress", "カウンセリング・感情のコントロール・ストレス", "심리 상담·감정 관리·스트레스", "Консультации, эмоции, стресс", "Orientación, gestión emocional, estrés", "Soutien psychologique, émotions, stress", "ให้คำปรึกษา จัดการอารมณ์ ความเครียด", "Tư vấn tâm lý, quản lý cảm xúc, căng thẳng"],
  DR23: ["Digestive cancers, lung cancer treatment", "消化器がん・肺がんの総合治療", "소화기암·폐암 종합 치료", "Рак органов пищеварения, рак лёгких", "Cánceres digestivos, cáncer de pulmón", "Cancers digestifs, cancer du poumon", "มะเร็งทางเดินอาหาร มะเร็งปอด", "Ung thư tiêu hóa, ung thư phổi"],
  DR24: ["Cancer screening, chemotherapy follow-up, cancer pain", "がん検診・化学療法の経過観察・がん性疼痛", "암 검진·항암 치료 추적·암성 통증", "Скрининг, наблюдение после химиотерапии, боль", "Cribado, seguimiento de quimioterapia, dolor", "Dépistage, suivi de chimiothérapie, douleur", "คัดกรองมะเร็ง ติดตามเคมีบำบัด ความปวด", "Tầm soát, theo dõi hóa trị, giảm đau ung thư"],
  DR25: ["Prostatitis, enlarged prostate", "前立腺炎・前立腺肥大", "전립선염·전립선 비대", "Простатит, аденома простаты", "Prostatitis, hiperplasia prostática", "Prostatite, hypertrophie de la prostate", "ต่อมลูกหมากอักเสบ ต่อมลูกหมากโต", "Viêm tuyến tiền liệt, phì đại tuyến tiền liệt"],
  DR26: ["Male urinary infections, sexual dysfunction", "男性の尿路感染症・性機能障害", "남성 요로 감염·성기능 장애", "Мочевые инфекции у мужчин, сексуальные расстройства", "Infecciones urinarias masculinas, disfunción sexual", "Infections urinaires masculines, troubles sexuels", "ติดเชื้อทางเดินปัสสาวะชาย สมรรถภาพทางเพศ", "Nhiễm trùng tiết niệu nam, rối loạn tình dục"],
};

/* 院内位置：数据库里是「门诊楼 4 层东区」这样的中文，拆成 楼 / 层 / 方位 再按语言拼 */
const LOC_PARTS = {
  bld: { "门诊楼": ["门诊楼", "Outpatient Building", "外来棟", "외래동", "Поликлинический корпус", "Edificio de Consultas", "Bâtiment des consultations", "อาคารผู้ป่วยนอก", "Tòa nhà khám bệnh"],
         "医技楼": ["医技楼", "Medical Technology Building", "医療技術棟", "의료기술동", "Корпус диагностики", "Edificio Técnico", "Bâtiment technique", "อาคารเทคนิคการแพทย์", "Tòa nhà kỹ thuật y tế"] },
  floor: ["{n} 层", "Floor {n}", "{n}階", "{n}층", "{n} этаж", "Planta {n}", "{n}e étage", "ชั้น {n}", "Tầng {n}"],
  side: { "东区": ["东区", "East", "東側", "동쪽", "восточная часть", "zona este", "côté est", "ฝั่งตะวันออก", "khu Đông"],
          "西区": ["西区", "West", "西側", "서쪽", "западная часть", "zona oeste", "côté ouest", "ฝั่งตะวันตก", "khu Tây"],
          "北侧": ["北侧", "North side", "北側", "북쪽", "северная сторона", "lado norte", "côté nord", "ฝั่งเหนือ", "phía Bắc"],
          "南侧": ["南侧", "South side", "南側", "남쪽", "южная сторона", "lado sur", "côté sud", "ฝั่งใต้", "phía Nam"] },
  kids: ["儿童医学中心", "Children's Medical Center", "小児医療センター", "어린이의료센터", "Детский медицинский центр", "Centro Médico Infantil", "Centre médical pour enfants", "ศูนย์การแพทย์เด็ก", "Trung tâm Y tế Nhi"],
};

/* 常用国家 / 地区与国际区号。名称由浏览器 Intl.DisplayNames 按当前语言生成，这里只存代码 */
const COUNTRIES = [
  ['CN', '86'], ['HK', '852'], ['MO', '853'], ['TW', '886'],
  ['KR', '82'], ['JP', '81'], ['RU', '7'], ['KZ', '7'], ['US', '1'], ['CA', '1'], ['GB', '44'], ['FR', '33'],
  ['DE', '49'], ['IT', '39'], ['ES', '34'], ['PT', '351'], ['NL', '31'], ['BE', '32'], ['CH', '41'], ['AT', '43'],
  ['SE', '46'], ['NO', '47'], ['DK', '45'], ['FI', '358'], ['PL', '48'], ['CZ', '420'], ['UA', '380'], ['BY', '375'],
  ['TR', '90'], ['GR', '30'], ['IE', '353'], ['AU', '61'], ['NZ', '64'], ['MX', '52'], ['BR', '55'], ['AR', '54'],
  ['CL', '56'], ['CO', '57'], ['PE', '51'], ['VE', '58'], ['CU', '53'], ['TH', '66'], ['VN', '84'], ['LA', '856'],
  ['KH', '855'], ['MM', '95'], ['MY', '60'], ['SG', '65'], ['ID', '62'], ['PH', '63'], ['IN', '91'], ['PK', '92'],
  ['BD', '880'], ['NP', '977'], ['LK', '94'], ['MN', '976'], ['UZ', '998'], ['KG', '996'], ['TJ', '992'], ['TM', '993'],
  ['AF', '93'], ['IR', '98'], ['IQ', '964'], ['SA', '966'], ['AE', '971'], ['EG', '20'], ['MA', '212'], ['DZ', '213'],
  ['TN', '216'], ['SD', '249'], ['ET', '251'], ['KE', '254'], ['TZ', '255'], ['UG', '256'], ['RW', '250'], ['NG', '234'],
  ['GH', '233'], ['CM', '237'], ['CD', '243'], ['ZA', '27'], ['ZM', '260'], ['ZW', '263'], ['MZ', '258'], ['AO', '244'],
];

function trIdx() { return typeof langIndex === 'function' ? langIndex() : 0; }

function trDeptName(d) {
  const tr = DEPT_TR[d.id];
  return tr ? (tr.name[trIdx()] || d.name) : d.name;
}
function trDeptDesc(d) {
  const tr = DEPT_TR[d.id];
  return tr ? (tr.desc[trIdx()] || d.desc) : d.desc;
}
function trTitle(title) {
  const tr = TITLE_TR[title];
  return tr ? (tr[trIdx()] || title) : title;
}
/* 中文界面只显示中文名；其他语言显示「张建国 (Zhang Jianguo)」 */
function trDoctorName(doc) {
  if (trIdx() === 0 || !DOCTOR_PINYIN[doc.id]) return doc.name;
  return doc.name + ' (' + DOCTOR_PINYIN[doc.id] + ')';
}
function trIntro(docId) {
  const i = trIdx();
  if (i === 0) return DOCTOR_INTRO[docId] || '';
  const tr = INTRO_TR[docId];
  return tr ? (tr[i - 1] || DOCTOR_INTRO[docId] || '') : (DOCTOR_INTRO[docId] || '');
}
function trLocation(loc) {
  const i = trIdx();
  if (!loc || i === 0) return loc || '';
  const m = /^(门诊楼|医技楼)\s*(\d+)\s*层(东区|西区|北侧|南侧)?(（儿童医学中心）)?$/.exec(loc.trim());
  if (!m) return loc;
  let s = LOC_PARTS.bld[m[1]][i] + ', ' + LOC_PARTS.floor[i].replace('{n}', m[2]);
  if (m[3]) s += ', ' + LOC_PARTS.side[m[3]][i];
  if (m[4]) s += ' (' + LOC_PARTS.kids[i] + ')';
  return s;
}
/* 上午 / 下午（服务端给的是中文） */
function trPeriod(p) {
  if (p === '上午') return t('am');
  if (p === '下午') return t('pm');
  return p || '';
}

let regionNames = null;
function countryName(code) {
  try {
    if (!regionNames || regionNames._lang !== LANG) {
      regionNames = new Intl.DisplayNames([langTag()], { type: 'region' });
      regionNames._lang = LANG;
    }
    return regionNames.of(code) || code;
  } catch (e) {
    return code;
  }
}
