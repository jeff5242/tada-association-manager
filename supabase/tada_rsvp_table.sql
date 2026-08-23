-- ============================================================================
-- 出席回覆：桌次安排
--   後台可於出席統計頁用下拉選單直接安排每位出席者的桌次，存於 tada_rsvp.table_no。
--   執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行）。
-- ============================================================================
ALTER TABLE tada_rsvp ADD COLUMN IF NOT EXISTS table_no TEXT;

NOTIFY pgrst, 'reload schema';
