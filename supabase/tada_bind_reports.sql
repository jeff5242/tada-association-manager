-- ============================================================================
-- 電子會員證：綁定失敗回報
--   會員在「綁定會員身分」比對不到自己時，可一鍵把填寫的資料回報秘書處，
--   由後台人工協助（補名冊、更正姓名／統編等）。
--   執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行）。
-- ============================================================================
CREATE TABLE IF NOT EXISTS tada_bind_reports (
  id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name              TEXT,                    -- 會員填的姓名
  company           TEXT,                    -- 會員填的公司／單位
  tax_id            TEXT,                    -- 會員填的統編
  error_code        TEXT,                    -- not_found / multiple / taken / not_in_roster …
  line_user_id      TEXT,                    -- 回報者 LINE userId（可回覆／協助綁定用）
  line_display_name TEXT,                    -- 回報者 LINE 暱稱
  note              TEXT,                    -- 會員補充說明（選填）
  status            TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','resolved','ignored')),
  admin_notes       TEXT,                    -- 內部備註
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  resolved_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_bind_reports_status
  ON tada_bind_reports (status, created_at DESC);

ALTER TABLE tada_bind_reports ENABLE ROW LEVEL SECURITY;

-- 會員端（anon）可送出回報（只能新增，不能讀別人的）
DROP POLICY IF EXISTS "anon_insert_bind_reports" ON tada_bind_reports;
CREATE POLICY "anon_insert_bind_reports"
  ON tada_bind_reports FOR INSERT
  WITH CHECK (true);

-- 後台（已有密碼牆）可讀取與更新處理狀態
DROP POLICY IF EXISTS "anon_select_bind_reports" ON tada_bind_reports;
CREATE POLICY "anon_select_bind_reports"
  ON tada_bind_reports FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "anon_update_bind_reports" ON tada_bind_reports;
CREATE POLICY "anon_update_bind_reports"
  ON tada_bind_reports FOR UPDATE
  USING (true);

NOTIFY pgrst, 'reload schema';
