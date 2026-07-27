// 名片 OCR — 用 Claude Vision 辨識名片並回傳結構化 JSON
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const MODEL = 'claude-sonnet-5'; // 用 Sonnet 提升中文 OCR 準確度（地名、姓名不易誤判）

const PROMPT = `你是專業的名片 OCR 助手。請仔細辨識這張名片，輸出「乾淨」的 JSON（只輸出 JSON，不要任何說明文字或 markdown 標記）。

【格式】
{
  "name": "姓名",
  "job": "職稱",
  "org_name": "公司／機構名稱",
  "tel_mobile": "手機號碼",
  "tel_office": "公司市話",
  "email": "電子郵件",
  "addr": "地址",
  "expertise": "業務領域或專長（若名片有標示）"
}

【重要規則】
1. 只填「值」本身，務必去掉欄位標籤前綴。例如 email 只放「edwind@cht.com.tw」，不要出現「E-mail:」「Mail:」「電話:」「TEL」「手機」「地址:」等字樣。
2. 電話分兩欄：09 開頭或 +886-9 的行動電話放 tel_mobile；市話（含區碼，如 03-、04-、02-）放 tel_office。保留原始數字與分隔符。
3. 地址：填完整地址。特別注意台灣常見地名用字，避免誤判：「台↔臺」「台↔日」「鎮/鄉/區」「縣/市」，例如「台中縣」不要辨識成「日中縣」。
4. 姓名以中文為主；若只有英文名則填英文。
5. 名片上沒有的欄位一律填空字串 ""，不要臆測或編造。`;

interface Ocr {
  name?: string; job?: string; org_name?: string; tel_mobile?: string;
  tel_office?: string; email?: string; addr?: string; expertise?: string;
}

// 後處理：去掉可能殘留的欄位標籤前綴
function clean(v: unknown): string {
  if (typeof v !== 'string') return '';
  return v
    .replace(/^\s*(e-?mail|mail|email|電子郵件|電子信箱|信箱|電話|傳真|fax|tel|phone|手機|行動電話|mobile|地址|address|addr|職稱|title|姓名|name|公司|company)\s*[:：]?\s*/i, '')
    .trim();
}

// email 特別處理：直接抽出 xxx@xxx 樣式
function cleanEmail(v: unknown): string {
  const s = clean(v);
  const m = s.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/);
  return m ? m[0] : s;
}

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
      model: MODEL,
      max_tokens: 1024,
      messages: [{
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: mediaType ?? 'image/jpeg', data: imageBase64 } },
          { type: 'text', text: PROMPT },
        ],
      }],
    }),
  });

  const data = await res.json();

  // 讓 Claude API 的錯誤能被前端看到（方便除錯）
  if (data.error) {
    return new Response(JSON.stringify({ error: 'AI 服務錯誤：' + (data.error.message ?? 'unknown') }), {
      status: 502, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const text: string = data.content?.[0]?.text ?? '{}';
  let raw: Ocr = {};
  try {
    const match = text.match(/\{[\s\S]*\}/);
    if (match) raw = JSON.parse(match[0]);
  } catch { /* ignore parse error */ }

  const parsed = {
    name: clean(raw.name),
    job: clean(raw.job),
    org_name: clean(raw.org_name),
    tel_mobile: clean(raw.tel_mobile),
    tel_office: clean(raw.tel_office),
    email: cleanEmail(raw.email),
    addr: clean(raw.addr),
    expertise: clean(raw.expertise),
  };

  return new Response(JSON.stringify(parsed), {
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
