-- ============================================================================
-- 發送紀錄存完整內容：LINE 廣播可從過去的發送「叫回來」再發
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）
--
-- line-broadcast edge function 會把送出的 LINE 訊息（文字／圖文卡片）原樣存進 payload；
-- 後台「載入過去發送」讀這一欄還原成可編輯的內容。
-- 本欄未建立前 edge function 會自動略過，發送與一般紀錄不受影響。
-- ============================================================================

ALTER TABLE tada_mail_log ADD COLUMN IF NOT EXISTS payload JSONB;

NOTIFY pgrst, 'reload schema';
