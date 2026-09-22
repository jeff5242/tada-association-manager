-- ============================================================================
-- LINE 廣播圖片儲存空間
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）
--
-- 後台「LINE 廣播 → 圖文卡片」上傳的海報存在這裡。
-- LINE 的 image / Flex hero 只吃「公開可讀的 https 網址」，故 bucket 必須 public。
-- 上傳走 anon key（後台本身已有密碼牆），刪除保留給管理者在 Dashboard 操作。
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('line-assets', 'line-assets', TRUE, 10485760,
        ARRAY['image/jpeg','image/png'])
ON CONFLICT (id) DO UPDATE
  SET public = TRUE,
      file_size_limit = 10485760,
      allowed_mime_types = ARRAY['image/jpeg','image/png'];

-- 任何人可讀（LINE 伺服器要抓圖，且無法帶授權標頭）
DROP POLICY IF EXISTS "line_assets_read" ON storage.objects;
CREATE POLICY "line_assets_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'line-assets');

-- 後台上傳（anon）；檔名由前端以時間戳＋亂數產生，避免覆蓋他人檔案
DROP POLICY IF EXISTS "line_assets_insert" ON storage.objects;
CREATE POLICY "line_assets_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'line-assets');

-- 允許覆寫同名檔（重新上傳同一張時不必先刪）
DROP POLICY IF EXISTS "line_assets_update" ON storage.objects;
CREATE POLICY "line_assets_update" ON storage.objects
  FOR UPDATE USING (bucket_id = 'line-assets') WITH CHECK (bucket_id = 'line-assets');
