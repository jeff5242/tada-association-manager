-- ============================================================================
-- 後台管理權限：會員可被「開通」為後台管理員，之後以手機＋OTP 登入後台。
--   於「會員名冊」每列的「🔑 開通後台」按鈕切換此欄位。
--   執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行）。
-- ============================================================================
ALTER TABLE tada_members ADD COLUMN IF NOT EXISTS admin_enabled BOOLEAN NOT NULL DEFAULT false;

-- 加速用手機查詢已開通會員
CREATE INDEX IF NOT EXISTS idx_members_admin_mobile
  ON tada_members (mobile) WHERE admin_enabled = true;

NOTIFY pgrst, 'reload schema';
