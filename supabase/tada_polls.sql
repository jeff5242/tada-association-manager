-- TADA 投票 / 議案表決
-- tada_polls：投票主題與選項（一次一個 active=true 的進行中投票）
-- tada_votes：每位會員的投票（一人一票，UNIQUE 防重複）
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）

CREATE TABLE IF NOT EXISTS tada_polls (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title       TEXT NOT NULL,               -- 投票主題
  description TEXT,                         -- 說明
  options     JSONB NOT NULL,              -- 選項陣列，例如 ["贊成","反對","棄權"]
  active      BOOLEAN NOT NULL DEFAULT FALSE,  -- 是否進行中（同時只開一個）
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tada_votes (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  poll_id      UUID NOT NULL REFERENCES tada_polls(id) ON DELETE CASCADE,
  user_id      TEXT NOT NULL,
  display_name TEXT,
  choice       TEXT NOT NULL,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (poll_id, user_id)              -- 一人一票
);

CREATE INDEX IF NOT EXISTS idx_votes_poll ON tada_votes (poll_id);

-- RLS
ALTER TABLE tada_polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_votes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_select_polls" ON tada_polls;
CREATE POLICY "anon_select_polls" ON tada_polls FOR SELECT USING (true);

DROP POLICY IF EXISTS "anon_insert_votes" ON tada_votes;
CREATE POLICY "anon_insert_votes" ON tada_votes FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "anon_select_votes" ON tada_votes;
CREATE POLICY "anon_select_votes" ON tada_votes FOR SELECT USING (true);

-- 範例投票（預設關閉；要啟用把 active 改成 true，同時其他投票設為 false）
INSERT INTO tada_polls (title, description, options, active)
SELECT '第六屆理事長信任案', '是否同意由陳肇浩擔任第六屆理事長？', '["贊成","反對","棄權"]'::jsonb, false
WHERE NOT EXISTS (SELECT 1 FROM tada_polls);
