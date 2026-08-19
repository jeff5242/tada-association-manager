-- ============================================================================
-- 信件公版（可於後台編輯）
--   key: 'approval'（審核通過信）｜'payment_confirm'（繳費確認信）
--   body 內可用變數：{姓名} {繳費連結} {金額} {證明連結}
-- ============================================================================
CREATE TABLE IF NOT EXISTS tada_mail_templates (
  key        TEXT PRIMARY KEY,
  subject    TEXT,
  body       TEXT,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE tada_mail_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mt_rw ON tada_mail_templates;
CREATE POLICY mt_rw ON tada_mail_templates FOR ALL USING (true) WITH CHECK (true);

INSERT INTO tada_mail_templates (key, subject, body) VALUES
('approval',
 'TADA 入會審核通過 — 會費繳納與回報',
 '【TADA 臺灣科技農企業發展協會】
{姓名} 您好：

您的入會申請已審核通過 ✅
請於完成會費匯款後，至下方連結回報繳費資訊（繳費日期＋匯款帳號後 5 碼）：
{繳費連結}

匯款資訊：
・京城銀行 太保分行（代號 0540641）
・帳號 064125019127
・戶名 台灣科技農企業發展協會

收到回報後，會務人員將為您核對確認。感謝您的支持 🌾'),
('payment_confirm',
 'TADA 繳費確認通知',
 '【TADA 臺灣科技農企業發展協會】
{姓名} 您好：

本會已收到並確認您的會費繳納 {金額}，特此確認。感謝您的支持與參與 🌾

您可於此查看／下載繳費確認證明：
{證明連結}

如有任何問題，歡迎直接回覆本信與秘書處聯繫。

臺灣科技農企業發展協會　敬啟')
ON CONFLICT (key) DO NOTHING;

NOTIFY pgrst, 'reload schema';
