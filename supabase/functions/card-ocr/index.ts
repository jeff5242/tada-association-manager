const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const { imageBase64, mediaType } = await req.json();
  if (!imageBase64) {
    return new Response(JSON.stringify({ error: '缺少圖片資料' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) {
    return new Response(JSON.stringify({ error: 'OCR 服務未設定 API Key' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 1024,
      messages: [{
        role: 'user',
        content: [
          {
            type: 'image',
            source: { type: 'base64', media_type: mediaType ?? 'image/jpeg', data: imageBase64 },
          },
          {
            type: 'text',
            text: `這是一張名片。請識別名片上的文字，提取以下資訊並以 JSON 格式回傳（只回傳 JSON，不要其他說明）：
{
  "name": "姓名",
  "job": "職稱",
  "org_name": "公司／機構名稱",
  "tel_mobile": "手機號碼",
  "tel_office": "公司電話",
  "email": "電子郵件",
  "addr": "地址",
  "expertise": "業務領域或專長"
}
若某欄位名片上沒有，填空字串 ""。手機格式優先取 09 開頭號碼。`,
          },
        ],
      }],
    }),
  });

  const data = await res.json();
  const text: string = data.content?.[0]?.text ?? '{}';

  let parsed: Record<string, string> = {};
  try {
    const match = text.match(/\{[\s\S]*\}/);
    if (match) parsed = JSON.parse(match[0]);
  } catch { /* ignore parse error */ }

  return new Response(JSON.stringify(parsed), {
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
