-- 會員旗標 —— 附加在 tada_line_users 上
-- 標記某個 LINE 使用者是否為正式會員，供「會員專屬內容」頁面判斷是否放行。
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）

ALTER TABLE tada_line_users
  ADD COLUMN IF NOT EXISTS is_member BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_line_users_is_member ON tada_line_users (is_member) WHERE is_member = TRUE;
