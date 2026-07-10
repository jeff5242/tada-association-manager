-- TADA醬 未答問題記錄表
-- 當本地 Wiki 與 AI 都無法回答時，把會員問題記錄下來，供會務人員後台補答。
-- 執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行，不會報錯）

CREATE TABLE IF NOT EXISTS tada_unanswered (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  question      TEXT NOT NULL,           -- 會員原始問題
  line_user_id  TEXT,                    -- 發問的 LINE 使用者 ID（可回覆用）
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'answered', 'ignored')),
  answer        TEXT,                    -- 會務人員補上的答案
  admin_notes   TEXT,                    -- 內部備註
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  answered_at   TIMESTAMPTZ
);

-- 依狀態與時間查詢的索引
CREATE INDEX IF NOT EXISTS idx_unanswered_status ON tada_unanswered (status, created_at DESC);

-- Row Level Security
ALTER TABLE tada_unanswered ENABLE ROW LEVEL SECURITY;

-- 寫入由 Edge Function 以 service role 進行（繞過 RLS），故 anon 不需 insert policy。
-- 後台（已有密碼牆）需要讀取與更新：
DROP POLICY IF EXISTS "anon_select_unanswered" ON tada_unanswered;
CREATE POLICY "anon_select_unanswered"
  ON tada_unanswered FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "anon_update_unanswered" ON tada_unanswered;
CREATE POLICY "anon_update_unanswered"
  ON tada_unanswered FOR UPDATE
  USING (true);
