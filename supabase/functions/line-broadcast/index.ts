// LINE 官方帳號廣播（發給所有好友）。
// 保護：需帶 x-broadcast-key 標頭，值須等於 Supabase secret BROADCAST_KEY，
// 避免 anon key 外流（本來就是公開的）被拿來亂發廣播。
Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const key = req.headers.get('x-broadcast-key') || '';
  const expect = Deno.env.get('BROADCAST_KEY') || '';
  if (!expect || key !== expect) return new Response(JSON.stringify({ ok: false, error: 'forbidden' }), { status: 403 });
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN') || '';
  if (!token) return new Response(JSON.stringify({ ok: false, error: 'no line token' }), { status: 500 });
  let body: { text?: string };
  try { body = await req.json(); } catch { return new Response(JSON.stringify({ ok: false, error: 'bad json' }), { status: 400 }); }
  const text = (body.text || '').trim();
  if (!text || text.length > 4900) return new Response(JSON.stringify({ ok: false, error: 'text empty or too long' }), { status: 400 });
  const r = await fetch('https://api.line.me/v2/bot/message/broadcast', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ messages: [{ type: 'text', text }] }),
  });
  const detail = await r.text();
  return new Response(JSON.stringify({ ok: r.ok, status: r.status, detail }), {
    headers: { 'Content-Type': 'application/json' },
  });
});
