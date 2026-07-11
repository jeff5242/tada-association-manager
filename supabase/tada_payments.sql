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
  note          TEXT,                     -- 備註
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'confirmed', 'rejected')),
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  confirmed_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_payments_status ON tada_payments (status, created_at DESC);

ALTER TABLE tada_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_insert_payments" ON tada_payments;
CREATE POLICY "anon_insert_payments" ON tada_payments FOR INSERT TO anon WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_payments" ON tada_payments;
CREATE POLICY "anon_select_payments" ON tada_payments FOR SELECT USING (true);

DROP POLICY IF EXISTS "anon_update_payments" ON tada_payments;
CREATE POLICY "anon_update_payments" ON tada_payments FOR UPDATE USING (true);
