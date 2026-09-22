// LINE 官方帳號廣播（發給所有好友）。
// 保護：需帶 x-broadcast-key 標頭，值須等於 Supabase secret BROADCAST_KEY，
// 避免 anon key 外流（本來就是公開的）被拿來亂發廣播。
//
// 用法擇一：
//   { "text": "純文字內容" }                      ← 單則文字（原有用法，保留相容）
//   { "messages": [ {...}, {...} ] }              ← LINE message 物件陣列（圖片／Flex／文字混搭）
// LINE 單次廣播上限 5 則訊息。
//
// 部署：supabase functions deploy line-broadcast --use-api --no-verify-jwt --project-ref ldjugtfxtxnpvkqvjxew

const MAX_MESSAGES = 5;
const MAX_TEXT_LEN = 4900;

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });

  const expect = Deno.env.get('BROADCAST_KEY') || '';
  if (!expect || (req.headers.get('x-broadcast-key') || '') !== expect) {
    return json({ ok: false, error: 'forbidden' }, 403);
  }
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN') || '';
  if (!token) return json({ ok: false, error: 'no line token' }, 500);

  let body: { text?: string; messages?: unknown[] };
  try { body = await req.json(); } catch { return json({ ok: false, error: 'bad json' }, 400); }

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

  const r = await fetch('https://api.line.me/v2/bot/message/broadcast', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ messages }),
  });
  return json({ ok: r.ok, status: r.status, count: messages.length, detail: await r.text() });
});
