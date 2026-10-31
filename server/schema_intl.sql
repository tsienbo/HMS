-- ============================================================
-- v3.5 国际化：多种证件、外国姓名、国际手机号
-- ------------------------------------------------------------
-- 外国留学生、港澳台居民来就诊时手里不是 18 位居民身份证，而是：
--   CN_ID     居民身份证                     18 位，GB 11643 校验位
--   HMT_RES   港澳台居民居住证               18 位，810000/820000/830000 开头，同样有校验位
--   FRP       外国人永久居留身份证           新版 18 位以 9 开头（有校验位）；旧版 3 字母 + 12 数字
--   HK_MO     港澳居民来往内地通行证（回乡证） H / M + 8 位或 10 位数字
--   TW        台湾居民来往大陆通行证（台胞证） 8 位或 10 位数字
--   PASSPORT  护照                           字母数字 5–14 位，必须同时给出国籍
--
-- 「一个人只有一份档案」靠证件键 doc_key 保证：
--   护照号只在签发国内唯一，所以护照的键是  P:国籍:护照号；
--   其余证件号在全国范围内唯一，键就是证件号本身 —— 居民身份证的键与原来的 id_card 完全相同，
--   旧数据、旧的患者凭证都不受影响。
-- doc_key 是由 (id_type, nationality, id_card) 推出的生成列（GENERATED ALWAYS … STORED），
-- 不可能与证件信息不一致。
--
-- 本文件可重复执行（IF NOT EXISTS / OR REPLACE / 先查后加）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 证件工具函数（IMMUTABLE：可用于生成列与 CHECK 约束）
-- ------------------------------------------------------------

-- GB 11643 校验位：前 17 位加权求和对 11 取余，查表得第 18 位
CREATE OR REPLACE FUNCTION fn_gb11643_ok(p TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  w INT[] := ARRAY[7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  s INT := 0;
BEGIN
  IF p IS NULL OR p !~ '^[0-9]{17}[0-9X]$' THEN
    RETURN FALSE;
  END IF;
  FOR i IN 1..17 LOOP
    s := s + substr(p, i, 1)::INT * w[i];
  END LOOP;
  RETURN substr('10X98765432', s % 11 + 1, 1) = substr(p, 18, 1);
END;
$$;

-- 证件号格式是否合法（按证件类型分别判断）
CREATE OR REPLACE FUNCTION fn_doc_valid(p_type TEXT, p_nat TEXT, p_no TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
    WHEN 'CN_ID'    THEN fn_gb11643_ok(p_no) AND p_no !~ '^(81|82|83|9)'
    WHEN 'HMT_RES'  THEN fn_gb11643_ok(p_no) AND p_no ~ '^8[123]0000'
    WHEN 'FRP'      THEN (fn_gb11643_ok(p_no) AND p_no ~ '^9') OR p_no ~ '^[A-Z]{3}[0-9]{12}$'
    WHEN 'HK_MO'    THEN p_no ~ '^[HM][0-9]{8}([0-9]{2})?$'
    WHEN 'TW'       THEN p_no ~ '^[0-9]{8}([0-9]{2})?$'
    WHEN 'PASSPORT' THEN p_no ~ '^[A-Z0-9]{5,14}$' AND coalesce(p_nat, '') ~ '^[A-Z]{2}$'
    ELSE FALSE
  END;
$$;

-- 证件键：护照带上国籍，其余就是证件号
CREATE OR REPLACE FUNCTION fn_doc_key(p_type TEXT, p_nat TEXT, p_no TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type = 'PASSPORT'
              THEN 'P:' || upper(coalesce(p_nat, '')) || ':' || upper(p_no)
              ELSE upper(p_no) END;
$$;

-- 证件号脱敏：18 位保留前 6 后 4；短证件（护照、通行证）只留首尾各 2 位，避免长度短时露出大半
CREATE OR REPLACE FUNCTION fn_mask_doc(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p IS NULL THEN NULL
    WHEN char_length(p) >= 15 THEN left(p, 6) || repeat('*', char_length(p) - 10) || right(p, 4)
    WHEN char_length(p) >= 6  THEN left(p, 2) || repeat('*', char_length(p) - 4) || right(p, 2)
    ELSE repeat('*', char_length(p))
  END;
$$;

-- ------------------------------------------------------------
-- 2. patients：证件类型、国籍、证件键、手机区号
-- ------------------------------------------------------------
ALTER TABLE patients ADD COLUMN IF NOT EXISTS id_type     VARCHAR(10) NOT NULL DEFAULT 'CN_ID';
ALTER TABLE patients ADD COLUMN IF NOT EXISTS nationality CHAR(2);              -- ISO 3166-1 二位码，如 US / KR
ALTER TABLE patients ADD COLUMN IF NOT EXISTS phone_cc    VARCHAR(4) NOT NULL DEFAULT '86';  -- 国际区号
ALTER TABLE patients ADD COLUMN IF NOT EXISTS doc_key     VARCHAR(40)
  GENERATED ALWAYS AS (fn_doc_key(id_type, nationality, id_card)) STORED;

DO $$
BEGIN
  -- 旧约束：只认 18 位身份证、只认大陆手机号、按身份证号唯一 —— 换成按证件类型的版本
  ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_idcard;
  ALTER TABLE patients DROP CONSTRAINT IF EXISTS ck_patients_phone;
  ALTER TABLE patients DROP CONSTRAINT IF EXISTS uq_patients_id_card;
  DROP INDEX IF EXISTS idx_patients_id_card_ci;   -- doc_key 本身就是大写的，不再需要表达式唯一索引

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_patients_id_type') THEN
    ALTER TABLE patients ADD CONSTRAINT ck_patients_id_type
      CHECK (id_type IN ('CN_ID', 'HMT_RES', 'FRP', 'HK_MO', 'TW', 'PASSPORT'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_patients_doc') THEN
    ALTER TABLE patients ADD CONSTRAINT ck_patients_doc
      CHECK (fn_doc_valid(id_type, nationality, id_card));
  END IF;
  -- 护照、外国人永居证必须有国籍；国籍若填写须是两位大写字母
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_patients_nationality') THEN
    ALTER TABLE patients ADD CONSTRAINT ck_patients_nationality
      CHECK ((nationality IS NULL OR nationality ~ '^[A-Z]{2}$')
             AND (id_type NOT IN ('PASSPORT', 'FRP') OR nationality IS NOT NULL));
  END IF;
  -- 大陆手机 11 位；其他国家 / 地区只存本地号码（4–11 位数字），区号单独一列
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_patients_phone_intl') THEN
    ALTER TABLE patients ADD CONSTRAINT ck_patients_phone_intl
      CHECK (phone_cc ~ '^[1-9][0-9]{0,3}$'
             AND CASE WHEN phone_cc = '86' THEN phone ~ '^1[3-9][0-9]{9}$'
                      ELSE phone ~ '^[0-9]{4,11}$' END);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_patients_doc_key') THEN
    ALTER TABLE patients ADD CONSTRAINT uq_patients_doc_key UNIQUE (doc_key);
  END IF;
END $$;

-- ------------------------------------------------------------
-- 3. 实名库、实名校验日志、黑名单：id_card 列改存证件键（护照键最长 P:XX:14 位）
-- ------------------------------------------------------------
ALTER TABLE citizen_registry    ALTER COLUMN id_card TYPE VARCHAR(40);
ALTER TABLE identity_verify_log ALTER COLUMN id_card TYPE VARCHAR(40);
ALTER TABLE blacklist           ALTER COLUMN id_card TYPE VARCHAR(40);

DO $$
BEGIN
  ALTER TABLE citizen_registry DROP CONSTRAINT IF EXISTS ck_registry_id_card;
  ALTER TABLE blacklist        DROP CONSTRAINT IF EXISTS ck_blacklist_idcard;
  DROP INDEX IF EXISTS idx_blacklist_id_card_ci;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_registry_doc_key') THEN
    ALTER TABLE citizen_registry ADD CONSTRAINT ck_registry_doc_key
      CHECK (id_card = upper(id_card) AND char_length(id_card) BETWEEN 5 AND 40);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_blacklist_doc_key') THEN
    ALTER TABLE blacklist ADD CONSTRAINT ck_blacklist_doc_key
      CHECK (id_card = upper(id_card) AND char_length(id_card) BETWEEN 5 AND 40);
  END IF;
END $$;

-- ------------------------------------------------------------
-- 4. 实名校验：姓名比对忽略大小写与多余空格（外文姓名 John  smith = JOHN SMITH）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_norm_name(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'));
$$;

CREATE OR REPLACE FUNCTION fn_verify_identity(
  p_name TEXT, p_id_card TEXT, p_purpose TEXT DEFAULT 'booking', p_ip TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
-- p_id_card 传的是证件键 doc_key（居民身份证就是身份证号本身）
DECLARE
  v_name TEXT;
  v_new  BOOLEAN := FALSE;
  v_ok   BOOLEAN;
BEGIN
  p_id_card := upper(btrim(p_id_card));
  p_name := regexp_replace(btrim(p_name), '\s+', ' ', 'g');

  SELECT name INTO v_name FROM citizen_registry WHERE id_card = p_id_card;
  IF NOT FOUND THEN
    -- 模拟「查询成功」：第一次出现的证件按本次姓名登记，此后只认这个姓名
    INSERT INTO citizen_registry (id_card, name, source)
    VALUES (p_id_card, p_name, 'auto')
    ON CONFLICT (id_card) DO NOTHING;            -- 并发时主键保证只登记一次
    v_new := FOUND;
    SELECT name INTO v_name FROM citizen_registry WHERE id_card = p_id_card;
  END IF;

  v_ok := fn_norm_name(v_name) = fn_norm_name(p_name);

  INSERT INTO identity_verify_log (id_card, name_input, passed, reason, purpose, client_ip)
  VALUES (p_id_card, p_name, v_ok,
          CASE WHEN NOT v_ok THEN 'name_mismatch' WHEN v_new THEN 'new' ELSE 'match' END,
          p_purpose, p_ip);
  RETURN v_ok;
END;
$$;

-- ------------------------------------------------------------
-- 5. 脱敏视图：短证件不能再按 18 位的位置打星
--    v_appointment_public / v_waitlist_detail 原来用 overlay(… FROM 7 FOR 8)，
--    对 8 位的台胞证会露出前 6 位。这里取出视图当前定义，只把这一个表达式
--    换成 fn_mask_doc，再 CREATE OR REPLACE —— 列名、列序都不变。
-- ------------------------------------------------------------
DO $$
DECLARE
  v TEXT;
  def TEXT;
BEGIN
  FOREACH v IN ARRAY ARRAY['v_appointment_public', 'v_waitlist_detail'] LOOP
    def := pg_get_viewdef(v::regclass, true);
    IF position('OVERLAY(p.id_card' IN def) > 0 THEN
      def := replace(def, 'OVERLAY(p.id_card PLACING ''********''::text FROM 7 FOR 8)', 'fn_mask_doc(p.id_card::text)');
      EXECUTE format('CREATE OR REPLACE VIEW %I AS %s', v, def);
    END IF;
  END LOOP;
END $$;
