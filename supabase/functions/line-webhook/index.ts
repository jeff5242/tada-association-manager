// LINE Messaging API Webhook — 「TADA醬」AI 客服（三層回覆漏斗）
//
// 收到會員訊息後，依序嘗試：
//   ① 本地 Wiki FAQ 比對         → 命中就回答，零 AI token（wiki.ts）
//   ② Claude API 回答            → 預設關閉，設 ENABLE_CLAUDE_FALLBACK=true 才啟用（消耗 token）
//   ③ 都不會 → 固定回覆「還不會」 → 記錄到 tada_unanswered 資料表 → 通知會務人員
//
// 需要的 Supabase secrets：
//   LINE_CHANNEL_SECRET         （必填，驗證 X-Line-Signature）
//   LINE_CHANNEL_ACCESS_TOKEN   （必填，呼叫 LINE Reply / Push API）
//   SUPABASE_URL                （記錄未答問題用，專案預設已存在）
//   SUPABASE_SERVICE_ROLE_KEY   （寫入 tada_unanswered，專案預設已存在）
//   ANTHROPIC_API_KEY           （選填，僅 ENABLE_CLAUDE_FALLBACK=true 時需要）
//   ENABLE_CLAUDE_FALLBACK      （選填，'true' 才啟用第②層 Claude）
//   ADMIN_LINE_USER_ID          （選填，設定後未答問題會 push 通知這個 LINE 使用者/群組）

import { matchWiki } from './wiki.ts';

const LINE_REPLY_ENDPOINT = 'https://api.line.me/v2/bot/message/reply';
const LINE_PUSH_ENDPOINT = 'https://api.line.me/v2/bot/message/push';
const ANTHROPIC_ENDPOINT = 'https://api.anthropic.com/v1/messages';
const CLAUDE_MODEL = 'claude-haiku-4-5-20251001';
const MAX_TOKENS = 800;

// TADA醬 的人設與協會知識（僅第②層 Claude 啟用時使用）
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

// 第③層：都不會回答時的固定訊息
const FALLBACK_TEXT = `這個問題我現在還不太會回答 🙇
我已經幫你記下來，會轉給協會的會務人員，請他們盡快協助回覆你～

若是急件，也可以直接聯繫秘書處：
📞 0988-558246（雅琳、馨元）
📧 tada201107@gmail.com`;

const WELCOME_TEXT = `嗨～我是 TADA醬 🐝
台灣科技農企業發展協會（TADA）的 AI 秘書，很開心認識你！

有任何協會相關問題都可以直接問我：
🌾 活動與大會資訊
📝 入會 / 續會怎麼申請
🤝 政府補助、資源對接
📮 聯繫秘書處

直接打字告訴我就好～`;

interface LineEvent {
  type: string;
  replyToken?: string;
  source?: { userId?: string };
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

// 第②層：呼叫 Claude 產生 TADA醬 的回覆
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
    body: JSON.stringify({ replyToken, messages: [{ type: 'text', text }] }),
  });

  if (!res.ok) {
    throw new Error(`LINE Reply API ${res.status}: ${await res.text()}`);
  }
}

// 主動推播（通知會務人員用）
async function pushToLine(token: string, to: string, text: string): Promise<void> {
  const res = await fetch(LINE_PUSH_ENDPOINT, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ to, messages: [{ type: 'text', text }] }),
  });

  if (!res.ok) {
    throw new Error(`LINE Push API ${res.status}: ${await res.text()}`);
  }
}

// 第③層：把未答問題寫入 tada_unanswered 資料表（用 service role，繞過 RLS）
async function logUnanswered(question: string, lineUserId: string | undefined): Promise<void> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    console.error('Cannot log unanswered question: missing Supabase env');
    return;
  }

  const res = await fetch(`${supabaseUrl}/rest/v1/tada_unanswered`, {
    method: 'POST',
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ question, line_user_id: lineUserId ?? null }),
  });

  if (!res.ok) {
    throw new Error(`Log unanswered ${res.status}: ${await res.text()}`);
  }
}

interface LineProfile {
  displayName?: string;
  pictureUrl?: string;
}

// 取得 LINE 使用者的公開個人資料（顯示名稱、頭像）
async function getLineProfile(token: string, userId: string): Promise<LineProfile> {
  const res = await fetch(`https://api.line.me/v2/bot/profile/${userId}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`LINE Profile API ${res.status}`);
  return await res.json();
}

// 記錄／更新互動過的 LINE 使用者（顯示名稱 + userId + 互動次數），用 RPC 原子遞增
async function recordLineUser(token: string, userId: string): Promise<void> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) return;

  let profile: LineProfile = {};
  try {
    profile = await getLineProfile(token, userId);
  } catch (error: unknown) {
    console.error('getLineProfile error:', getErrorMessage(error)); // 抓不到名稱仍記錄 userId
  }

  const res = await fetch(`${supabaseUrl}/rest/v1/rpc/upsert_line_user`, {
    method: 'POST',
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({
      p_user_id: userId,
      p_display_name: profile.displayName ?? null,
      p_picture_url: profile.pictureUrl ?? null,
    }),
  });

  if (!res.ok) {
    throw new Error(`Record line user ${res.status}: ${await res.text()}`);
  }
}

// 通知會務人員（若有設定 ADMIN_LINE_USER_ID 才會 push）
async function notifyAdmin(token: string, question: string): Promise<void> {
  const adminId = Deno.env.get('ADMIN_LINE_USER_ID');
  if (!adminId) return; // 未設定就只記錄、不推播

  const text = `🔔 有一則會員問題 TADA醬 還不會回答，已記錄待處理：\n\n「${question}」\n\n請至後台查看並補充答案。`;
  await pushToLine(token, adminId, text);
}

// 處理一則文字訊息（三層漏斗）
async function handleTextMessage(
  accessToken: string,
  replyToken: string,
  userText: string,
  userId: string | undefined,
): Promise<void> {
  // ① 本地 Wiki（零 token）
  const hit = matchWiki(userText);
  if (hit) {
    await replyToLine(accessToken, replyToken, hit.entry.answer);
    return;
  }

  // ② Claude（預設關閉）
  const claudeEnabled = Deno.env.get('ENABLE_CLAUDE_FALLBACK') === 'true';
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (claudeEnabled && anthropicKey) {
    const answer = await askClaude(anthropicKey, userText);
    await replyToLine(accessToken, replyToken, answer);
    return;
  }

  // ③ 都不會：固定回覆 + 記錄 + 通知（記錄/通知失敗不影響已回覆使用者）
  await replyToLine(accessToken, replyToken, FALLBACK_TEXT);
  try {
    await logUnanswered(userText, userId);
    await notifyAdmin(accessToken, userText);
  } catch (error: unknown) {
    console.error('Unanswered log/notify error:', getErrorMessage(error));
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  const channelSecret = Deno.env.get('LINE_CHANNEL_SECRET');
  const accessToken = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');

  if (!channelSecret || !accessToken) {
    console.error('Missing required LINE secrets');
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

  // 逐一處理事件；單一事件失敗不影響其他事件，且一律回 200 給 LINE
  await Promise.all(
    events.map(async (event) => {
      try {
        // 記錄互動過的使用者（名稱 + userId），失敗不影響回覆
        const userId = event.source?.userId;
        if (userId) {
          recordLineUser(accessToken, userId).catch((error: unknown) =>
            console.error('recordLineUser error:', getErrorMessage(error)),
          );
        }

        if (event.type === 'follow' && event.replyToken) {
          await replyToLine(accessToken, event.replyToken, WELCOME_TEXT);
          return;
        }

        if (event.type === 'message' && event.message?.type === 'text' && event.replyToken) {
          await handleTextMessage(
            accessToken,
            event.replyToken,
            event.message.text ?? '',
            userId,
          );
        }
      } catch (error: unknown) {
        console.error('Event handling error:', getErrorMessage(error));
      }
    }),
  );

  return new Response('OK', { status: 200 });
});
