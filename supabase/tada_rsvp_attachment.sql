-- ============================================================================
-- 出席回覆：附件圖檔（客戶傳來的名單／截圖）
--   後台代填時可附上一張圖，存到公開 storage bucket「tada-uploads」，
--   並把公開網址記在 tada_rsvp.attachment_url。
--   執行位置：Supabase SQL Editor → 貼上整段後按 RUN（可重複執行）。
-- ============================================================================

-- 1) 欄位：附件公開網址
ALTER TABLE tada_rsvp ADD COLUMN IF NOT EXISTS attachment_url TEXT;

-- 2) 建立公開 bucket（若已存在則略過）
INSERT INTO storage.buckets (id, name, public)
VALUES ('tada-uploads', 'tada-uploads', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- 3) 允許前端（anon）上傳到此 bucket、任何人可讀（公開名單截圖，非機密）
DROP POLICY IF EXISTS "tada_uploads_insert" ON storage.objects;
CREATE POLICY "tada_uploads_insert"
  ON storage.objects FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'tada-uploads');

DROP POLICY IF EXISTS "tada_uploads_select" ON storage.objects;
CREATE POLICY "tada_uploads_select"
  ON storage.objects FOR SELECT TO anon, authenticated
  USING (bucket_id = 'tada-uploads');

NOTIFY pgrst, 'reload schema';
