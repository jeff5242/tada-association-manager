-- TADA 繳費回報
-- 會員匯款後從 LIFF 回報「帳號後五碼＋金額」，會務人員在後台核對確認。
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）

CREATE TABLE IF NOT EXISTS tada_payments (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id       TEXT,                     -- LINE userId
  display_name  TEXT,                     -- LINE 顯示名稱
  member_type   TEXT,                     -- personal_new / group_new / personal_renew / group_renew
  amount        INTEGER,                  -- 匯款金額
  last5         TEXT,                     -- 匯款帳號後 5 碼
  applicant_name TEXT,                    -- 會員名稱（個人姓名／團體公司全名），必填
  mobile        TEXT,                     -- 聯絡手機，必填
  paid_date     DATE,                     -- 匯款日期
  note          TEXT,                     -- 備註
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'confirmed', 'rejected')),
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  confirmed_at  TIMESTAMPTZ
);

-- ── 後補欄位（既有資料庫直接跑這段即可）──────────────────────────
-- applicant_name / paid_date：2026-08 已上線
-- mobile：2026-08-30 新增。LINE 暱稱（display_name）常是「Paul~楊定勝-阿堂師」
--         這類，會務人員無從核對匯款，故改為必填「會員名稱＋手機」。
ALTER TABLE tada_payments ADD COLUMN IF NOT EXISTS applicant_name TEXT;
ALTER TABLE tada_payments ADD COLUMN IF NOT EXISTS paid_date      DATE;
ALTER TABLE tada_payments ADD COLUMN IF NOT EXISTS mobile         TEXT;

CREATE INDEX IF NOT EXISTS idx_payments_status ON tada_payments (status, created_at DESC);

ALTER TABLE tada_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_insert_payments" ON tada_payments;
CREATE POLICY "anon_insert_payments" ON tada_payments FOR INSERT TO anon WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_payments" ON tada_payments;
CREATE POLICY "anon_select_payments" ON tada_payments FOR SELECT USING (true);

DROP POLICY IF EXISTS "anon_update_payments" ON tada_payments;
CREATE POLICY "anon_update_payments" ON tada_payments FOR UPDATE USING (true);

NOTIFY pgrst, 'reload schema';
