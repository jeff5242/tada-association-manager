-- ============================================================================
-- 發送紀錄存完整內容與 LINE 請求編號
--   payload         ← 後台「載入過去發送」，把過去的內容叫回來再發
--   line_request_id ← 後台「查看成效」，向 LINE 查這次廣播的送達／開封／點擊人數
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）
--
-- line-broadcast edge function 會把送出的 LINE 訊息（文字／圖文卡片）原樣存進 payload；
-- 後台「載入過去發送」讀這一欄還原成可編輯的內容。
-- 這兩欄未建立前 edge function 會自動略過，發送與一般紀錄不受影響。
-- ============================================================================

ALTER TABLE tada_mail_log ADD COLUMN IF NOT EXISTS payload JSONB;
ALTER TABLE tada_mail_log ADD COLUMN IF NOT EXISTS line_request_id TEXT;

NOTIFY pgrst, 'reload schema';
