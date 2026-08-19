-- ============================================================================
-- 發信記錄：每封協會寄出的信一筆，供「發信中心」依類別檢視送達/開信/點擊
--   status 由 send-email 寫入 'sent'；Resend webhook 之後更新 delivered/opened/clicked/bounced
-- ============================================================================
CREATE TABLE IF NOT EXISTS tada_mail_log (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  category    TEXT,                         -- assembly|approval|payment_confirm|manual|...
  to_email    TEXT NOT NULL,
  name        TEXT,
  member_no   TEXT,
  subject     TEXT,
  resend_id   TEXT,                         -- Resend 訊息 id（對應 webhook）
  status      TEXT NOT NULL DEFAULT 'sent', -- sent|delivered|opened|clicked|bounced|failed
  error       TEXT,
  opened_at   TIMESTAMPTZ,
  clicked_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_mail_log_cat  ON tada_mail_log (category, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mail_log_rid  ON tada_mail_log (resend_id);

ALTER TABLE tada_mail_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mail_log_read ON tada_mail_log;
-- 後台(anon)可讀清單；寫入由 send-email(service role) 與 webhook 處理
CREATE POLICY mail_log_read ON tada_mail_log FOR SELECT USING (true);

NOTIFY pgrst, 'reload schema';
