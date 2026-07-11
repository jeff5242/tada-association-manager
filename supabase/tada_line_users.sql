-- TADA LINE 使用者名單
-- 每當有人和 TADA醬 互動（加好友或傳訊息），webhook 會自動記錄其 LINE 顯示名稱與 userId。
-- 供後台查看「誰在使用」，並勾選哪些人是管理人員（is_admin）。
-- 執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行，不會報錯）

CREATE TABLE IF NOT EXISTS tada_line_users (
  user_id       TEXT PRIMARY KEY,        -- LINE userId（唯一）
  display_name  TEXT,                    -- LINE 顯示名稱
  picture_url   TEXT,                    -- 頭像
  is_admin      BOOLEAN NOT NULL DEFAULT FALSE,  -- 是否為管理人員（後台勾選）
  message_count INTEGER NOT NULL DEFAULT 0,      -- 累計互動次數
  first_seen    TIMESTAMPTZ DEFAULT NOW(),       -- 首次互動
  last_seen     TIMESTAMPTZ DEFAULT NOW()        -- 最近互動
);

CREATE INDEX IF NOT EXISTS idx_line_users_last_seen ON tada_line_users (last_seen DESC);
CREATE INDEX IF NOT EXISTS idx_line_users_is_admin ON tada_line_users (is_admin) WHERE is_admin = TRUE;

-- 累計互動次數用的原子遞增函式（webhook upsert 時呼叫，避免競態）
CREATE OR REPLACE FUNCTION upsert_line_user(
  p_user_id      TEXT,
  p_display_name TEXT,
  p_picture_url  TEXT
) RETURNS VOID AS $$
BEGIN
  INSERT INTO tada_line_users (user_id, display_name, picture_url, message_count, last_seen)
  VALUES (p_user_id, p_display_name, p_picture_url, 1, NOW())
  ON CONFLICT (user_id) DO UPDATE SET
    display_name  = COALESCE(EXCLUDED.display_name, tada_line_users.display_name),
    picture_url   = COALESCE(EXCLUDED.picture_url, tada_line_users.picture_url),
    message_count = tada_line_users.message_count + 1,
    last_seen     = NOW();
END;
$$ LANGUAGE plpgsql;

-- Row Level Security
ALTER TABLE tada_line_users ENABLE ROW LEVEL SECURITY;

-- 寫入由 Edge Function 以 service role 進行（繞過 RLS）。
-- 後台（已有密碼牆）需要讀取與更新 is_admin：
DROP POLICY IF EXISTS "anon_select_line_users" ON tada_line_users;
CREATE POLICY "anon_select_line_users"
  ON tada_line_users FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "anon_update_line_users" ON tada_line_users;
CREATE POLICY "anon_update_line_users"
  ON tada_line_users FOR UPDATE
  USING (true);
