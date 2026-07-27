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
  "tax_id": "公司統一編號（8 碼數字，名片上常標示為「統一編號」「統編」「Tax ID」，若有才填）",
  "expertise": "業務領域或專長（若名片有標示）"
}

【重要規則】
1. 只填「值」本身，務必去掉欄位標籤前綴。例如 email 只放「edwind@cht.com.tw」，不要出現「E-mail:」「Mail:」「電話:」「TEL」「手機」「地址:」等字樣。
2. 電話分兩欄：09 開頭或 +886-9 的行動電話放 tel_mobile；市話（含區碼，如 03-、04-、02-）放 tel_office。保留原始數字與分隔符。
3. 地址：填完整台灣地址。特別注意常見地名用字，避免誤判：「台↔臺」「台↔日」「鎮/鄉/區」「縣/市」，例如「台中縣」不要辨識成「日中縣」。
4. 【非常重要】name、org_name、addr、job 這些中文欄位，只能包含「繁體中文字、阿拉伯數字、以及路/街/段/巷/弄/號/樓/室/區/鄉/鎮/市/縣」等正常字元。
   - 絕對禁止輸出俄文（如 ед）、希臘文，或無意義的拉丁字母拼湊（如 och、edoch）。
   - 台灣地址的街道名一定是中文字（例如「信義路」「中山路」「復興路」）。若某個字看不清楚，請用最合理的「中文字」推測；真的無法判讀時，用「〇」代替該字，切勿改用其他語言字元填補。
5. 【地址現代化】地址請一律換成「現行」行政區名稱，不要沿用已廢除的舊制：
   - 桃園縣 → 桃園市（原縣轄「桃園市」改為「桃園區」，故「桃園縣桃園市」應輸出為「桃園市桃園區」）。
   - 台北縣 → 新北市（原鄉鎮市改為區，如板橋市→板橋區）。
   - 台中縣、台中市 → 台中市（原台中縣鄉鎮市改為區）。
   - 台南縣、台南市 → 台南市。
   - 高雄縣、高雄市 → 高雄市（原鄉鎮市改為區）。
   其餘無改制者維持原樣。若名片印的是舊制，請自動更新為上述現行名稱。
6. 姓名以中文為主；若名片只有英文名才填英文。
7. 名片上沒有的欄位一律填空字串 ""，不要臆測或編造。`;

interface Ocr {
  name?: string; job?: string; org_name?: string; tel_mobile?: string;
  tel_office?: string; email?: string; addr?: string; tax_id?: string; expertise?: string;
}

// 統一編號：只保留 8 碼數字
function cleanTaxId(v: unknown): string {
  const m = clean(v).match(/\d{8}/);
  return m ? m[0] : '';
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
    tax_id: cleanTaxId(raw.tax_id),
    expertise: clean(raw.expertise),
  };

  return new Response(JSON.stringify(parsed), {
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
