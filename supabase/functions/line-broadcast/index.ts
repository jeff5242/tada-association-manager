// LINE 官方帳號廣播（發給所有好友）。
// 保護：需帶 x-broadcast-key 標頭，值須等於 Supabase secret BROADCAST_KEY，
// 避免 anon key 外流（本來就是公開的）被拿來亂發廣播。
//
// 內容擇一：
//   { "text": "純文字內容" }                      ← 單則文字（原有用法，保留相容）
//   { "messages": [ {...}, {...} ] }              ← LINE message 物件陣列（圖片／Flex／文字混搭）
// LINE 單次上限 5 則訊息。
//
// 對象：
//   不帶 to            → 廣播給所有好友
//   "to": "Uxxx"       → 只發給這個人（正式廣播前先試發給自己，強烈建議）
//   "to": ["U1","U2"]  → 指定多人（multicast，上限 500 人）
//
// 部署：supabase functions deploy line-broadcast --use-api --no-verify-jwt --project-ref ldjugtfxtxnpvkqvjxew

const MAX_MESSAGES = 5;
const MAX_TEXT_LEN = 4900;

// 後台是瀏覽器頁面，且帶自訂標頭 x-broadcast-key，
// 瀏覽器會先送 OPTIONS 預檢；少了這段預檢會失敗，前端只看得到 "Failed to fetch"。
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-broadcast-key',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405, headers: CORS });

  const expect = Deno.env.get('BROADCAST_KEY') || '';
  if (!expect || (req.headers.get('x-broadcast-key') || '') !== expect) {
    return json({ ok: false, error: 'forbidden' }, 403);
  }
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN') || '';
  if (!token) return json({ ok: false, error: 'no line token' }, 500);

  let body: { text?: string; messages?: unknown[]; to?: string | string[]; verify?: boolean };
  try { body = await req.json(); } catch { return json({ ok: false, error: 'bad json' }, 400); }

  // 只驗金鑰、不發任何訊息：讓後台在排版前就能確認金鑰正確
  if (body.verify) return json({ ok: true, verified: true });

  let messages: unknown[];
  if (Array.isArray(body.messages)) {
    messages = body.messages;
    if (!messages.length) return json({ ok: false, error: 'messages empty' }, 400);
    if (messages.length > MAX_MESSAGES) {
      return json({ ok: false, error: `too many messages (max ${MAX_MESSAGES})` }, 400);
    }
    if (messages.some((m) => typeof m !== 'object' || m === null || !(m as { type?: string }).type)) {
      return json({ ok: false, error: 'each message needs a type' }, 400);
    }
  } else {
    const text = (body.text || '').trim();
    if (!text || text.length > MAX_TEXT_LEN) {
      return json({ ok: false, error: 'text empty or too long' }, 400);
    }
    messages = [{ type: 'text', text }];
  }

  // 指定對象 → push / multicast；未指定 → broadcast
  const ID_RE = /^U[0-9a-f]{32}$/;
  let endpoint = 'broadcast';
  let payload: Record<string, unknown> = { messages };
  if (body.to !== undefined) {
    const list = (Array.isArray(body.to) ? body.to : [body.to]).map((s) => String(s).trim());
    if (!list.length) return json({ ok: false, error: 'to empty' }, 400);
    if (list.length > 500) return json({ ok: false, error: 'too many recipients (max 500)' }, 400);
    const bad = list.find((u) => !ID_RE.test(u));
    if (bad) return json({ ok: false, error: `bad line user id: ${bad}` }, 400);
    endpoint = list.length === 1 ? 'push' : 'multicast';
    payload = list.length === 1 ? { to: list[0], messages } : { to: list, messages };
  }

  const r = await fetch(`https://api.line.me/v2/bot/message/${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(payload),
  });
  const detail = await r.text();

  // 發送紀錄由伺服器端寫入：tada_mail_log 對 anon 只開放讀取，
  // 前端寫入會靜默失敗（fetch 不會 throw），記錄不到「何時廣播過什麼」。
  await logSend(endpoint, messages, r.ok, detail);

  return json({ ok: r.ok, status: r.status, mode: endpoint, count: messages.length, detail });
});

/** 從訊息內容取一行摘要：文字取首行，Flex 取 altText */
function summarize(messages: unknown[]): string {
  for (const m of messages as Array<{ type?: string; text?: string; altText?: string }>) {
    if (m.type === 'text' && m.text) return m.text.split('\n')[0];
    if (m.type === 'flex' && m.altText) return m.altText;
  }
  return `${messages.length} 則訊息`;
}

async function logSend(mode: string, messages: unknown[], ok: boolean, detail: string) {
  const SB_URL = Deno.env.get('SUPABASE_URL');
  const SRK = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!SB_URL || !SRK) return;                      // 環境不完整就跳過，不影響發送結果
  const label = mode === 'broadcast' ? '廣播' : mode === 'multicast' ? '指定多人' : '指定單人';
  try {
    await fetch(`${SB_URL}/rest/v1/tada_mail_log`, {
      method: 'POST',
      headers: {
        apikey: SRK, Authorization: `Bearer ${SRK}`,
        'Content-Type': 'application/json', Prefer: 'return=minimal',
      },
      body: JSON.stringify({
        category: 'line_broadcast',
        to_email: mode === 'broadcast' ? 'LINE 官方帳號好友' : 'LINE 指定對象',
        name: label,
        subject: `[LINE${label}] ${summarize(messages).slice(0, 120)}`,
        status: ok ? 'sent' : 'failed',
        error: ok ? null : detail.slice(0, 500),
      }),
    });
  } catch (_) { /* 記錄失敗不影響已送出的訊息 */ }
}
