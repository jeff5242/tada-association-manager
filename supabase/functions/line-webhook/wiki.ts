// TADA 知識庫（本地 FAQ）— 供「TADA醬」在「不呼叫 AI、零 token」的狀況下回答常見問題
//
// 運作方式：
//   1. matchWiki()   — 精準比對：訊息含關鍵字就回答（零 token）
//   2. suggestWiki() — 模糊比對：答不出來時，用字元重疊度找最相近的幾則，做成 Quick Reply 推薦
//
// 維護方式：直接新增 / 修改下方 WIKI 陣列即可。
//   keywords → 精準比對用（使用者可能打的詞）
//   suggest  → 這則要不要出現在「你是不是想問」按鈕；label 是按鈕文字，text 是按下去送出的字（須含某個 keyword）

import { AGENDA_FLEX, PAYMENT_FLEX, CONTACT_FLEX, FEE_FLEX } from './flex.ts';

export interface WikiEntry {
  id: string;
  question: string; // 代表問題（給維護者看的）
  answer: string; // TADA醬 的回答（純文字備援；有 flex 時改送卡片）
  keywords: string[]; // 精準比對關鍵字
  suggest?: { label: string; text: string }; // Quick Reply 推薦按鈕（省略＝不推薦，如打招呼）
  flex?: unknown; // 有值時，命中改回覆 Flex Message 卡片
}

export const WIKI: WikiEntry[] = [
  {
    id: 'greeting',
    question: '打招呼',
    answer:
      '嗨～我是 TADA醬 🐝 台灣科技農企業發展協會的 AI 小秘書！\n' +
      '活動、入會、會費、交通、聯絡方式都可以問我，直接打字告訴我就好～',
    keywords: ['你好', '妳好', '哈囉', '嗨', 'hi', 'hello', '在嗎', '請問'],
  },
  {
    id: 'about',
    question: '協會是做什麼的',
    answer:
      '台灣科技農企業發展協會（TADA）以「AI 賦能」與「二代傳承」為主軸，' +
      '協助農企業導入科技、數位轉型，並促進世代交流與資源對接 🌾\n' +
      '官網：https://tada-ai.org.tw',
    keywords: ['協會', '宗旨', '做什麼', '是什麼', '介紹', 'tada', '你們是'],
    suggest: { label: '🌱 協會介紹', text: '協會介紹' },
  },
  {
    id: 'event-date',
    question: '活動什麼時候',
    answer:
      '第六屆會員大會暨會長就職典禮 📅\n' +
      '日期：2026 年 9 月 4 日（星期五）\n' +
      '15:00 開放入場、15:30 會務討論、16:10 大師講座、17:30 交接典禮、18:30 豐收晚宴（20:30 賦歸）',
    keywords: ['什麼時候', '哪一天', '日期', '幾點', '時間', '開會時間', '幾月'],
    suggest: { label: '🗓 活動時間', text: '活動時間' },
  },
  {
    id: 'venue',
    question: '活動地點在哪',
    answer:
      '地點：臻愛婚宴會館 烏日高鐵店 📍\n' +
      '地址：台中市烏日區高鐵路三段 168 號\n' +
      '（台中高鐵站步行約 8 分鐘）',
    keywords: ['地點', '地址', '在哪', '哪裡', '場地', '會場', '哪邊'],
    suggest: { label: '📍 活動地點', text: '地點' },
  },
  {
    id: 'transport',
    question: '怎麼去 / 交通',
    answer:
      '交通方式 🚄\n' +
      '搭高鐵：台中高鐵站下車，步行約 8 分鐘即到。\n' +
      '開車：現場停車位逾 400 個。',
    keywords: ['怎麼去', '交通', '高鐵', '捷運', '火車', '搭車', '怎麼到'],
    suggest: { label: '🚄 交通方式', text: '交通' },
  },
  {
    id: 'parking',
    question: '有停車位嗎',
    answer: '有的 🚗 臻愛婚宴會館 烏日高鐵店現場停車位逾 400 個，開車前來很方便。',
    keywords: ['停車', '車位', '開車', '停車場'],
    suggest: { label: '🅿️ 停車資訊', text: '停車' },
  },
  {
    id: 'dresscode',
    question: '要穿什麼',
    answer: '著裝建議：商務正式（Business Attire）👔 是理監事改選與就職典禮的正式場合喔～',
    keywords: ['穿什麼', '服裝', '著裝', '穿著', 'dresscode', '正式', '西裝'],
    suggest: { label: '👔 服裝建議', text: '服裝' },
  },
  {
    id: 'agenda',
    question: '活動議程 / 流程',
    answer:
      '當天議程 📋\n' +
      '15:00 開放入場・報到\n' +
      '15:30 會務討論（第五屆會務報告暨第六屆理監事改選）\n' +
      '16:10 大師講座（AI × 精準農業）\n' +
      '16:50 政府補助計畫說明（中衛發展中心）\n' +
      '17:10 Q&A\n' +
      '17:30 理事長交接典禮\n' +
      '18:30 豐收晚宴（20:30 賦歸）',
    keywords: ['議程', '流程', '行程', '安排', '節目', '幾點做'],
    suggest: { label: '📋 活動議程', text: '活動議程' },
    flex: AGENDA_FLEX,
  },
  {
    id: 'speaker',
    question: '講師是誰',
    answer:
      '大師講座講師：國立臺灣大學生物資源暨農學院 院長 盧虎生（邀請中）🎓\n' +
      '講題方向：數據驅動的精準農業 —— AI 時代的農業永續與二代接班。',
    keywords: ['講師', '演講', '講座', '誰來講', '盧虎生', '大師', '主講'],
    suggest: { label: '🎓 講師介紹', text: '講師' },
  },
  {
    id: 'chairman',
    question: '新任會長是誰',
    answer: '第六屆理事長：陳肇浩（米屋智農）🌾 當天將舉行就職交接典禮。',
    keywords: ['會長', '理事長', '誰是會長', '就職', '接班人'],
    suggest: { label: '🏅 新任會長', text: '會長' },
  },
  {
    id: 'subsidy',
    question: '政府補助 / 中衛',
    answer:
      '當天由「財團法人中衛發展中心」專題說明協會成員如何對接政府補助與計畫資源 🤝\n' +
      '（詳細講題確認中，歡迎當天到場了解。）',
    keywords: ['補助', '中衛', '政府', '計畫', '資源', '對接', '申請補助'],
    suggest: { label: '🤝 政府補助', text: '補助' },
  },
  {
    id: 'join-how',
    question: '怎麼入會 / 加入',
    answer:
      '歡迎加入 TADA！入會方式 📝\n' +
      '請至官網填寫入會申請表：https://tada-ai.org.tw/join/\n' +
      '個人、團體會員都可以申請，填完表單後依指示繳費即完成～',
    keywords: ['入會', '加入', '怎麼申請', '報名', '申請會員', '想加入', '會員資格'],
    suggest: { label: '📝 如何入會', text: '入會' },
  },
  {
    id: 'fee',
    question: '會費多少',
    answer:
      '會費說明 💰（常年會費為三年一次繳清）\n' +
      '個人會員：入會費 NT$1,000 ＋ 常年會費 NT$6,000 ＝ 共 NT$7,000\n' +
      '團體會員：入會費 NT$10,000 ＋ 常年會費 NT$20,000 ＝ 共 NT$30,000',
    keywords: ['會費', '會員費', '多少錢', '費用', '入會費', '常年會費', '年費', '幾錢', '價格'],
    suggest: { label: '💰 會費說明', text: '會費' },
    flex: FEE_FLEX,
  },
  {
    id: 'renew',
    question: '續會 / 續約',
    answer:
      '續約會費（三年一次繳清）🔄\n' +
      '個人會員：NT$6,000\n' +
      '團體會員：NT$20,000\n' +
      '續約一樣可從官網 https://tada-ai.org.tw/join/ 辦理。',
    keywords: ['續會', '續約', '展延', '到期', '延長', '再加入'],
    suggest: { label: '🔄 續會續約', text: '續約' },
  },
  {
    id: 'payment',
    question: '匯款帳號 / 怎麼繳費',
    answer:
      '匯款資訊 🏦\n' +
      '京城銀行 太保分行（銀行代號 0540641）\n' +
      '帳號：064125019127\n' +
      '戶名：台灣科技農企業發展協會\n' +
      '⚠️ 匯款後請來電告知帳號後 5 碼：📞 0988-558246（雅琳、馨元）',
    keywords: ['匯款', '銀行', '帳號', '轉帳', '繳費', '匯錢', '付款', '戶名', '匯費'],
    suggest: { label: '🏦 匯款帳號', text: '匯款' },
    flex: PAYMENT_FLEX,
  },
  {
    id: 'contact',
    question: '聯絡方式 / 秘書處',
    answer:
      '協會秘書處聯絡方式 📮\n' +
      '📞 0988-558246（雅琳、馨元）\n' +
      '📧 tada201107@gmail.com\n' +
      '有任何我回答不了的問題，也歡迎直接聯繫他們～',
    keywords: ['電話', '聯絡', '聯繫', '秘書處', 'email', '信箱', '找誰', '窗口', '客服'],
    suggest: { label: '📞 聯絡方式', text: '聯絡' },
    flex: CONTACT_FLEX,
  },
  {
    id: 'website',
    question: '官網網址',
    answer: '協會官網在這裡 🌐 https://tada-ai.org.tw\n入會申請：https://tada-ai.org.tw/join/',
    keywords: ['官網', '網站', '網址', '連結', '線上', 'website'],
    suggest: { label: '🌐 協會官網', text: '官網' },
  },
  {
    id: 'second-gen',
    question: '可以帶家人 / 二代嗎',
    answer: '非常歡迎 👨‍👩‍👧‍👦 本次特別鼓勵攜帶家族第二代共同出席，一起見證農業邁入 AI 新世代！',
    keywords: ['二代', '帶家人', '攜帶', '帶人', '眷屬', '家人', '小孩', '子女', '一起去'],
    suggest: { label: '👪 攜帶家人', text: '攜帶' },
  },
];

// 正規化：轉小寫、移除空白與常見標點，方便比對
function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[\s，。、！？!?.,~～「」『』（）()【】\-_/\\]/g, '');
}

export interface WikiMatch {
  entry: WikiEntry;
  score: number;
}

// 精準比對：回傳命中關鍵字最多的一則；沒有任何命中則回 null（零 token）
export function matchWiki(userText: string): WikiMatch | null {
  const text = normalize(userText);
  if (!text) return null;

  let best: WikiMatch | null = null;

  for (const entry of WIKI) {
    let score = 0;
    for (const keyword of entry.keywords) {
      if (text.includes(normalize(keyword))) score += 1;
    }
    if (score > 0 && (best === null || score > best.score)) {
      best = { entry, score };
    }
  }

  return best;
}

// 過於通用、無鑑別度的字元，模糊比對時忽略以降低雜訊
const STOP_CHARS = new Set([...'的是我你請問嗎呢了要想如何這那現今在有個麼么呀啊喔誒欸請多少']);

// 模糊比對：答不出來時，用「內容字元重疊度」找最相近的幾則，供 Quick Reply 推薦。
// 完全沒有交集時，回傳預設熱門題目，確保一定給使用者選項。
export function suggestWiki(userText: string, limit = 4): WikiEntry[] {
  const chars = new Set([...normalize(userText)].filter((c) => !STOP_CHARS.has(c)));

  const scored = WIKI.filter((e) => e.suggest)
    .map((entry) => {
      const hay = normalize(entry.keywords.join('') + entry.question);
      let score = 0;
      for (const c of chars) {
        if (hay.includes(c)) score += 1;
      }
      return { entry, score };
    })
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score);

  if (scored.length) {
    return scored.slice(0, limit).map((x) => x.entry);
  }

  // 毫無交集 → 給預設熱門題目
  const defaults = ['event-date', 'fee', 'join-how', 'contact'];
  return WIKI.filter((e) => defaults.includes(e.id));
}
