// ── Resend Webhook 接收器 ────────────────────────────────────────────
// 接收 Resend 寄信事件（delivered/opened/clicked/bounced…），依 email_id
// 更新 tada_mail_log 的狀態，供「發信中心」顯示開信/點擊/退信統計。
//
// 部署：
//   SUPABASE_ACCESS_TOKEN=sbp_... supabase functions deploy resend-webhook \
//     --use-api --no-verify-jwt --project-ref ldjugtfxtxnpvkqvjxew
// Resend 後台 → Webhooks → Add Endpoint：
//   https://ldjugtfxtxnpvkqvjxew.supabase.co/functions/v1/resend-webhook
//   勾選 email.delivered / opened / clicked / bounced / complained
// 若填了 Signing Secret，設 Supabase secret RESEND_WEBHOOK_SECRET=whsec_... 以驗簽。

const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SRK = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WH_SECRET = Deno.env.get('RESEND_WEBHOOK_SECRET') ?? '';

const EVENT_STATUS: Record<string, string> = {
  'email.sent': 'sent',
  'email.delivered': 'delivered',
  'email.opened': 'opened',
  'email.clicked': 'clicked',
  'email.bounced': 'bounced',
  'email.complained': 'bounced',
};
const RANK: Record<string, number> = { sent: 1, delivered: 2, opened: 3, clicked: 4, bounced: 9, failed: 9 };

async function verifySvix(headers: Headers, raw: string): Promise<boolean> {
  if (!WH_SECRET) return true; // 未設 secret → 不驗（可先跑通再補）
  const id = headers.get('svix-id'), ts = headers.get('svix-timestamp'), sig = headers.get('svix-signature');
  if (!id || !ts || !sig) return false;
  try {
    const b64 = WH_SECRET.includes('_') ? WH_SECRET.split('_').slice(1).join('_') : WH_SECRET;
    const key = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const ck = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const mac = await crypto.subtle.sign('HMAC', ck, new TextEncoder().encode(`${id}.${ts}.${raw}`));
    const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
    return sig.split(' ').some((s) => s.split(',')[1] === expected);
  } catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method_not_allowed', { status: 405 });
  const raw = await req.text();
  if (!(await verifySvix(req.headers, raw))) return new Response('bad_signature', { status: 401 });

  let evt: { type?: string; data?: { email_id?: string } };
  try { evt = JSON.parse(raw); } catch { return new Response('bad_json', { status: 400 }); }

  const newStatus = EVENT_STATUS[evt.type ?? ''];
  const emailId = evt.data?.email_id;
  if (!newStatus || !emailId) return new Response('ignored', { status: 200 });

  const h = { apikey: SRK, Authorization: `Bearer ${SRK}`, 'Content-Type': 'application/json' };
  // 取現況，只「升級」狀態（避免 delivered 覆蓋 opened）
  const cur = await fetch(`${SB_URL}/rest/v1/tada_mail_log?resend_id=eq.${emailId}&select=id,status&limit=1`, { headers: h })
    .then((r) => r.json()).catch(() => []);
  if (!Array.isArray(cur) || !cur.length) return new Response('no_row', { status: 200 });

  const curStatus = cur[0].status || 'sent';
  const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
  if ((RANK[newStatus] ?? 0) >= (RANK[curStatus] ?? 0)) patch.status = newStatus;
  if (newStatus === 'opened') patch.opened_at = new Date().toISOString();
  if (newStatus === 'clicked') { patch.clicked_at = new Date().toISOString(); patch.opened_at = patch.opened_at ?? new Date().toISOString(); }

  await fetch(`${SB_URL}/rest/v1/tada_mail_log?id=eq.${cur[0].id}`, {
    method: 'PATCH', headers: { ...h, Prefer: 'return=minimal' }, body: JSON.stringify(patch),
  });
  return new Response('ok', { status: 200 });
});
