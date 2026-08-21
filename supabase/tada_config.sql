-- ============================================================================
-- 全站功能開關（後台可即時開/關，前台頁面載入時讀取）
--   key: 'feature_vote'（線上投票）｜'feature_live'（開票直播）｜'feature_consent'（候選人願任書）
--   value: 'on' | 'off'（缺此列＝視為 on，不會擋）
-- 執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行）
-- ============================================================================
CREATE TABLE IF NOT EXISTS tada_config (
  key        TEXT PRIMARY KEY,
  value      TEXT,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE tada_config ENABLE ROW LEVEL SECURITY;

-- 前台 anon 讀取開關；後台 anon 寫入（與專案既有姿態一致，後台以密碼保護 UI）
DROP POLICY IF EXISTS cfg_rw ON tada_config;
CREATE POLICY cfg_rw ON tada_config FOR ALL USING (true) WITH CHECK (true);

INSERT INTO tada_config (key, value) VALUES
  ('feature_vote','on'),
  ('feature_live','on'),
  ('feature_consent','off')
ON CONFLICT (key) DO NOTHING;

NOTIFY pgrst, 'reload schema';
