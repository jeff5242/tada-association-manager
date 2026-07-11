-- TADA 活動出席回覆（RSVP）
-- 會員從 LINE 的 LIFF 頁面回覆出席，資料寫入這張表；後台即時統計出席人數。
-- 執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行，不會報錯）

CREATE TABLE IF NOT EXISTS tada_rsvp (
  user_id       TEXT PRIMARY KEY,         -- LINE userId（一人一列）
  display_name  TEXT,                     -- LINE 顯示名稱
  attending     BOOLEAN NOT NULL DEFAULT TRUE,  -- 是否出席
  headcount     INTEGER NOT NULL DEFAULT 1,     -- 出席總人數（含本人與眷屬）
  vegetarian    INTEGER NOT NULL DEFAULT 0,     -- 素食份數
  companions    TEXT,                     -- 同行眷屬／二代姓名（選填）
  note          TEXT,                     -- 備註（選填）
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rsvp_attending ON tada_rsvp (attending);

-- Row Level Security
ALTER TABLE tada_rsvp ENABLE ROW LEVEL SECURITY;

-- LIFF 頁面用 anon 金鑰新增／更新自己的回覆；後台讀取統計
DROP POLICY IF EXISTS "anon_insert_rsvp" ON tada_rsvp;
CREATE POLICY "anon_insert_rsvp" ON tada_rsvp FOR INSERT TO anon WITH CHECK (true);

DROP POLICY IF EXISTS "anon_update_rsvp" ON tada_rsvp;
CREATE POLICY "anon_update_rsvp" ON tada_rsvp FOR UPDATE USING (true);

DROP POLICY IF EXISTS "anon_select_rsvp" ON tada_rsvp;
CREATE POLICY "anon_select_rsvp" ON tada_rsvp FOR SELECT USING (true);
