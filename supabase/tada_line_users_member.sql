-- LINE 使用者 ↔ 會員 對應（後台「🔗 比對會員」按鈕寫入）
-- 目的：暱稱會變，比對出是哪位會員時把本名與編號固定記下來
-- 執行位置：Supabase SQL Editor 貼上執行一次（可重複執行）
ALTER TABLE tada_line_users ADD COLUMN IF NOT EXISTS member_no   TEXT;
ALTER TABLE tada_line_users ADD COLUMN IF NOT EXISTS member_name TEXT;
COMMENT ON COLUMN tada_line_users.member_no   IS '對應會員編號（綁定或姓名比對後由後台記錄）';
COMMENT ON COLUMN tada_line_users.member_name IS '對應會員本名（暱稱改了仍認得出是誰）';
