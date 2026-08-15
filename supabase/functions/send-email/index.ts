// ── 協會統一寄信 ─────────────────────────────────────────────
// 以「台灣科技農企業發展協會 TADA <service@tada-ai.org.tw>」名義寄出 Email。
// 走 Resend（https://resend.com）——需先在 Resend 驗證網域 tada-ai.org.tw。
//
// 需要的環境變數（Supabase → Edge Functions → Secrets）：
//   RESEND_API_KEY   ← 由你的 Resend 帳號取得（機密，不進 repo）
//   MAIL_FROM        ← 選填，預設「台灣科技農企業發展協會 TADA <service@tada-ai.org.tw>」
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY ← 專案預設已存在
//
// 部署：
//   SUPABASE_ACCESS_TOKEN=sbp_... supabase functions deploy send-email \
//     --use-api --no-verify-jwt --project-ref ldjugtfxtxnpvkqvjxew
//
// 防濫用：本函式為公開端點，故限制「收件人必須是名冊/申請書中已存在的 Email」，
// 避免被拿來群發任意信箱。內容由後臺（密碼保護）產生。

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const RESEND_KEY = Deno.env.get('RESEND_API_KEY');
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SRK = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const FROM = Deno.env.get('MAIL_FROM') ?? '台灣科技農企業發展協會 TADA <service@tada-ai.org.tw>';

function json(o: unknown, status = 200) {
  return new Response(JSON.stringify(o), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

// 收件人是否為已知會員／申請人（防止群發任意信箱）
async function recipientKnown(email: string): Promise<boolean> {
  const h = { apikey: SRK, Authorization: `Bearer ${SRK}` };
  const enc = encodeURIComponent(email);
  const probes: Array<[string, string]> = [
    ['tada_applications', `or=(email.ilike.${enc},contact_email.ilike.${enc})`],
    ['tada_members', `or=(email.ilike.${enc},contact_email.ilike.${enc})`],
  ];
  for (const [table, filter] of probes) {
    try {
      const res = await fetch(`${SB_URL}/rest/v1/${table}?${filter}&select=id&limit=1`, { headers: h });
      if (res.ok) { const rows = await res.json(); if (Array.isArray(rows) && rows.length) return true; }
    } catch (_) { /* 忽略單一表錯誤，續查下一張 */ }
  }
  return false;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);
  if (!RESEND_KEY) return json({ ok: false, error: 'not_configured' }, 503);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'bad_json' }, 400); }

  const to = String(body.to ?? '').trim().toLowerCase();
  const subject = String(body.subject ?? '').trim();
  const html = String(body.html ?? '').trim();
  const text = String(body.text ?? '').trim();

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return json({ ok: false, error: 'bad_recipient' }, 400);
  if (!subject || (!html && !text)) return json({ ok: false, error: 'missing_content' }, 400);

  if (!(await recipientKnown(to))) return json({ ok: false, error: 'recipient_not_member' }, 403);

  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to: [to], subject, html: html || undefined, text: text || undefined }),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) return json({ ok: false, error: 'send_failed', detail: data }, 502);
  return json({ ok: true, id: (data as { id?: string }).id ?? null });
});
