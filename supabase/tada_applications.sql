-- TADA 入會申請資料表
-- 執行位置：Supabase SQL Editor

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
  rep_name        TEXT,
  rep_gender      TEXT,
  rep_birthday    TEXT,
  rep_birthplace  TEXT,
  rep_education   TEXT,
  rep_experience  TEXT,
  rep_email       TEXT,
  rep_tel         TEXT,
  contact_tel     TEXT,
  contact_email   TEXT,

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

-- Row Level Security
ALTER TABLE tada_applications ENABLE ROW LEVEL SECURITY;

-- 公開表單可以新增（anon）
CREATE POLICY "anon_insert_applications"
  ON tada_applications FOR INSERT
  TO anon WITH CHECK (true);

-- 所有人可讀（後台已有密碼牆保護）
CREATE POLICY "anon_select_applications"
  ON tada_applications FOR SELECT
  USING (true);

-- 更新（後台審核用）
CREATE POLICY "anon_update_applications"
  ON tada_applications FOR UPDATE
  USING (true);
