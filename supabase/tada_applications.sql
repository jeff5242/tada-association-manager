-- TADA 入會申請資料表（完整版，含最多 3 位團體代表人）
-- 執行位置：Supabase SQL Editor　→　貼上整段後按 RUN
-- 可重複執行，不會報錯

CREATE TABLE IF NOT EXISTS tada_applications (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  type            TEXT NOT NULL CHECK (type IN ('personal', 'group')),
  is_renewal      BOOLEAN DEFAULT FALSE,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'payment_confirmed', 'approved', 'rejected')),

  -- 個人欄位
  name            TEXT,
  gender          TEXT,
  birthday        TEXT,
  birthplace      TEXT,
  id_number       TEXT,
  education       TEXT,
  experience      TEXT,
  job             TEXT,
  expertise       TEXT,
  addr_domicile   TEXT,
  addr_mail       TEXT,
  tel_office      TEXT,
  tel_mobile      TEXT,
  email           TEXT,

  -- 團體欄位
  org_name        TEXT,
  org_addr        TEXT,
  org_tel         TEXT,
  org_founded     TEXT,
  ceo_name        TEXT,
  member_count    TEXT,
  license_no      TEXT,
  license_org     TEXT,
  business_scope  TEXT,
  contact_tel     TEXT,
  contact_email   TEXT,

  -- 團體代表人 1（主要）
  rep_name        TEXT,
  rep_gender      TEXT,
  rep_birthday    TEXT,
  rep_birthplace  TEXT,
  rep_education   TEXT,
  rep_experience  TEXT,
  rep_email       TEXT,
  rep_tel         TEXT,

  -- 團體代表人 2
  rep2_name       TEXT,
  rep2_gender     TEXT,
  rep2_birthday   TEXT,
  rep2_birthplace TEXT,
  rep2_education  TEXT,
  rep2_experience TEXT,
  rep2_email      TEXT,
  rep2_tel        TEXT,

  -- 團體代表人 3
  rep3_name       TEXT,
  rep3_gender     TEXT,
  rep3_birthday   TEXT,
  rep3_birthplace TEXT,
  rep3_education  TEXT,
  rep3_experience TEXT,
  rep3_email      TEXT,
  rep3_tel        TEXT,

  -- 共用
  ref1            TEXT,
  ref2            TEXT,

  -- 後台審核欄位
  payment_confirmed_at  TIMESTAMPTZ,
  approved_at           TIMESTAMPTZ,
  rejected_at           TIMESTAMPTZ,
  admin_notes           TEXT,

  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 若資料表先前已建立但缺代表人 2、3 欄位，補上（可重複執行）
ALTER TABLE tada_applications
  ADD COLUMN IF NOT EXISTS rep2_name TEXT,  ADD COLUMN IF NOT EXISTS rep2_gender TEXT,
  ADD COLUMN IF NOT EXISTS rep2_birthday TEXT, ADD COLUMN IF NOT EXISTS rep2_birthplace TEXT,
  ADD COLUMN IF NOT EXISTS rep2_education TEXT, ADD COLUMN IF NOT EXISTS rep2_experience TEXT,
  ADD COLUMN IF NOT EXISTS rep2_email TEXT, ADD COLUMN IF NOT EXISTS rep2_tel TEXT,
  ADD COLUMN IF NOT EXISTS rep3_name TEXT,  ADD COLUMN IF NOT EXISTS rep3_gender TEXT,
  ADD COLUMN IF NOT EXISTS rep3_birthday TEXT, ADD COLUMN IF NOT EXISTS rep3_birthplace TEXT,
  ADD COLUMN IF NOT EXISTS rep3_education TEXT, ADD COLUMN IF NOT EXISTS rep3_experience TEXT,
  ADD COLUMN IF NOT EXISTS rep3_email TEXT, ADD COLUMN IF NOT EXISTS rep3_tel TEXT;

-- Row Level Security
ALTER TABLE tada_applications ENABLE ROW LEVEL SECURITY;

-- 公開表單可以新增（anon）
DROP POLICY IF EXISTS "anon_insert_applications" ON tada_applications;
CREATE POLICY "anon_insert_applications"
  ON tada_applications FOR INSERT
  TO anon WITH CHECK (true);

-- 所有人可讀（後台已有密碼牆保護）
DROP POLICY IF EXISTS "anon_select_applications" ON tada_applications;
CREATE POLICY "anon_select_applications"
  ON tada_applications FOR SELECT
  USING (true);

-- 更新（後台審核用）
DROP POLICY IF EXISTS "anon_update_applications" ON tada_applications;
CREATE POLICY "anon_update_applications"
  ON tada_applications FOR UPDATE
  USING (true);
