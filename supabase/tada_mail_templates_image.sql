-- ============================================================================
-- 信件範本存圖片：選範本時信件圖片與點擊連結自動帶出，不必每次重新上傳
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）
--
-- image_url  ← 信件最上方的圖片（公開網址，存在 line-assets 空間）
-- image_link ← 點圖片要前往的網址（選填）
-- 欄位未建立前，後台「儲存範本」只會存主旨與內文，並提示先執行本檔。
-- ============================================================================

ALTER TABLE tada_mail_templates ADD COLUMN IF NOT EXISTS image_url  TEXT;
ALTER TABLE tada_mail_templates ADD COLUMN IF NOT EXISTS image_link TEXT;

NOTIFY pgrst, 'reload schema';
