-- ============================================================================
-- 選舉人名冊作業（2026-08-29）
-- 1) tada_v_members.is_staff：標記「現場工作人員」（供預先批次報到列印）
-- 2) tada_print_queue：遠端列印佇列——後台塞工作、樹莓派 print-agent 輪詢出紙
-- 3) tada_v_proxy.proof_url：紙本委託書證明（照片上傳後記 URL）
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）
-- ============================================================================

ALTER TABLE tada_v_members ADD COLUMN IF NOT EXISTS is_staff BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE tada_v_proxy  ADD COLUMN IF NOT EXISTS proof_url TEXT;

-- 遠端列印佇列
CREATE TABLE IF NOT EXISTS tada_print_queue (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  payload    JSONB NOT NULL,                -- print-agent /print 的參數（name/member_no/table_no/checklist/…）
  status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','error')),
  error      TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  printed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_print_queue_status ON tada_print_queue (status, created_at);

ALTER TABLE tada_print_queue ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS print_queue_rw ON tada_print_queue;
CREATE POLICY print_queue_rw ON tada_print_queue FOR ALL USING (true) WITH CHECK (true);

-- 委託單表：後台需能補記 proof_url（與專案既有 anon 姿態一致）
ALTER TABLE tada_v_proxy ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS v_proxy_rw ON tada_v_proxy;
CREATE POLICY v_proxy_rw ON tada_v_proxy FOR ALL USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
