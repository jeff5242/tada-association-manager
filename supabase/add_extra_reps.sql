-- 新增第二、第三位會員代表欄位
-- 執行位置：Supabase SQL Editor

ALTER TABLE tada_applications
  ADD COLUMN IF NOT EXISTS rep2_name        TEXT,
  ADD COLUMN IF NOT EXISTS rep2_gender      TEXT,
  ADD COLUMN IF NOT EXISTS rep2_birthday    TEXT,
  ADD COLUMN IF NOT EXISTS rep2_birthplace  TEXT,
  ADD COLUMN IF NOT EXISTS rep2_education   TEXT,
  ADD COLUMN IF NOT EXISTS rep2_experience  TEXT,
  ADD COLUMN IF NOT EXISTS rep2_email       TEXT,
  ADD COLUMN IF NOT EXISTS rep2_tel         TEXT,

  ADD COLUMN IF NOT EXISTS rep3_name        TEXT,
  ADD COLUMN IF NOT EXISTS rep3_gender      TEXT,
  ADD COLUMN IF NOT EXISTS rep3_birthday    TEXT,
  ADD COLUMN IF NOT EXISTS rep3_birthplace  TEXT,
  ADD COLUMN IF NOT EXISTS rep3_education   TEXT,
  ADD COLUMN IF NOT EXISTS rep3_experience  TEXT,
  ADD COLUMN IF NOT EXISTS rep3_email       TEXT,
  ADD COLUMN IF NOT EXISTS rep3_tel         TEXT;
