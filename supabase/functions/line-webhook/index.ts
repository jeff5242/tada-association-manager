// LINE Messaging API Webhook — 「TADA醬」AI 客服
// 會員在 LINE 官方帳號發訊息 → 驗證簽章 → 呼叫 Claude（小秘人設）→ 回覆
//
// 需要的 Supabase secrets：
//   LINE_CHANNEL_SECRET        （驗證 X-Line-Signature 用）
//   LINE_CHANNEL_ACCESS_TOKEN  （呼叫 LINE Reply API 用）
//   ANTHROPIC_API_KEY          （呼叫 Claude 用）

const LINE_REPLY_ENDPOINT = 'https://api.line.me/v2/bot/message/reply';
const ANTHROPIC_ENDPOINT = 'https://api.anthropic.com/v1/messages';
const CLAUDE_MODEL = 'claude-haiku-4-5-20251001';
const MAX_TOKENS = 800;

// 小秘的人設與協會知識
const SYSTEM_PROMPT = `你是「TADA醬」（TADA-chan），台灣科技農企業發展協會（TADA，Taiwan Agri-tech Development Association）的 AI 秘書小助手。

【你的角色】
- 名字叫「TADA醬」，「醬」是日文暱稱 ちゃん 的意思，是協會的 AI 秘書。語氣親切、活潑、專業又簡潔，像一位可靠又好聊的年輕秘書。
- 用繁體中文（台灣用語）回覆。適度使用 emoji（🌾🐝📋），但不浮誇。
- 每次回覆盡量控制在 3～5 句內，太長的資訊用條列。
- 你代表協會對外服務，但你是 AI；若被問到你是誰，就說「我是協會的 AI 小秘書 TADA醬～」。
- 遇到你不確定或需要人工處理的事（繳費核對、個資變更、客訴），請引導對方聯繫秘書處，不要亂編答案。

【協會重點資訊】
- 全名：台灣科技農企業發展協會（TADA）
- 定位：以「AI 賦能」與「二代傳承」為主軸，協助農企業數位轉型。
- 近期活動：2026 年 9 月 4 日（星期五）第六屆會員大會暨會長就職典禮
  - 地點：臻愛婚宴會館 烏日高鐵店（台中市烏日區高鐵路三段 168 號，台中高鐵站步行約 8 分鐘）
  - 內容：會務討論、AI 大師講座、政府補助計畫說明、理事長交接典禮、豐收晚宴
- 新任會長：陳肇浩（米屋智農）
- 入會／續會：可至協會官網填寫申請表；歡迎個人與團體會員加入。
- 官網：https://tada-ai.org.tw

【回答原則】
- 若對方問活動、入會、補助、聯繫方式等，就依上面資訊回答。
- 若資訊不足或超出範圍，誠實說「這部分我幫你轉給秘書處確認」，不要捏造日期、金額、名單。
- 絕對不要提供或臆測任何未在上面列出的個人姓名、電話、財務數字。`;

interface LineEvent {
  type: string;
  replyToken?: string;
  message?: { type: string; text?: string };
}

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Unexpected error';
}

// 驗證 LINE 簽章：HMAC-SHA256(rawBody, channelSecret) 的 base64 應等於 X-Line-Signature
async function verifySignature(secret: string, rawBody: string, signature: string): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return expected === signature;
}

// 呼叫 Claude 產生小秘的回覆
async function askClaude(apiKey: string, userText: string): Promise<string> {
  const res = await fetch(ANTHROPIC_ENDPOINT, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: CLAUDE_MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM_PROMPT,
      messages: [{ role: 'user', content: userText }],
    }),
  });

  if (!res.ok) {
    throw new Error(`Claude API ${res.status}: ${await res.text()}`);
  }

  const data = await res.json();
  return data.content?.[0]?.text?.trim() || '不好意思，我剛剛沒接好訊息，可以再說一次嗎？🐝';
}

// 呼叫 LINE Reply API 回覆訊息
async function replyToLine(token: string, replyToken: string, text: string): Promise<void> {
  const res = await fetch(LINE_REPLY_ENDPOINT, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      replyToken,
      messages: [{ type: 'text', text }],
    }),
  });

  if (!res.ok) {
    throw new Error(`LINE Reply API ${res.status}: ${await res.text()}`);
  }
}

const WELCOME_TEXT = `嗨～我是 TADA醬 🐝
台灣科技農企業發展協會（TADA）的 AI 秘書，很開心認識你！

有任何協會相關問題都可以直接問我：
🌾 活動與大會資訊
📝 入會 / 續會怎麼申請
🤝 政府補助、資源對接
📮 聯繫秘書處

直接打字告訴我就好～`;

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  const channelSecret = Deno.env.get('LINE_CHANNEL_SECRET');
  const accessToken = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');

  if (!channelSecret || !accessToken || !anthropicKey) {
    console.error('Missing required secrets');
    return new Response('Server not configured', { status: 500 });
  }

  const rawBody = await req.text();
  const signature = req.headers.get('x-line-signature') ?? '';

  const valid = await verifySignature(channelSecret, rawBody, signature);
  if (!valid) {
    console.error('Invalid LINE signature');
    return new Response('Invalid signature', { status: 401 });
  }

  let events: LineEvent[] = [];
  try {
    events = JSON.parse(rawBody).events ?? [];
  } catch (error: unknown) {
    console.error('Body parse error:', getErrorMessage(error));
    return new Response('Bad Request', { status: 400 });
  }

  // 逐一處理事件；單一事件失敗不影響其他事件，且仍回 200 給 LINE
  await Promise.all(
    events.map(async (event) => {
      try {
        if (event.type === 'follow' && event.replyToken) {
          await replyToLine(accessToken, event.replyToken, WELCOME_TEXT);
          return;
        }

        if (event.type === 'message' && event.message?.type === 'text' && event.replyToken) {
          const answer = await askClaude(anthropicKey, event.message.text ?? '');
          await replyToLine(accessToken, event.replyToken, answer);
        }
      } catch (error: unknown) {
        console.error('Event handling error:', getErrorMessage(error));
      }
    }),
  );

  return new Response('OK', { status: 200 });
});
