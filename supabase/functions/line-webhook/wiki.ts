// TADA 知識庫（本地 FAQ）— 供「TADA醬」在「不呼叫 AI、零 token」的狀況下回答常見問題
//
// 運作方式：把會員訊息正規化後，與每則 FAQ 的 keywords 做字串比對，
// 取命中關鍵字最多的一則回答。全部是本地字串比對，不消耗任何 API token。
//
// 維護方式：直接新增 / 修改下方 WIKI 陣列即可；keywords 請放「使用者可能會打的詞」。

export interface WikiEntry {
  id: string;
  question: string; // 這則對應的代表問題（給人看的，方便維護）
  answer: string; // TADA醬 的回答內容
  keywords: string[]; // 命中用的關鍵字（越具體越不會誤判）
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
  },
  {
    id: 'event-date',
    question: '活動什麼時候',
    answer:
      '第六屆會員大會暨會長就職典禮 📅\n' +
      '日期：2026 年 9 月 4 日（星期五）\n' +
      '15:00 開放入場、15:30 會務討論、16:10 大師講座、17:30 交接典禮、18:30 豐收晚宴（20:30 賦歸）',
    keywords: ['什麼時候', '哪一天', '日期', '幾點', '時間', '開會時間', '幾月'],
  },
  {
    id: 'venue',
    question: '活動地點在哪',
    answer:
      '地點：臻愛婚宴會館 烏日高鐵店 📍\n' +
      '地址：台中市烏日區高鐵路三段 168 號\n' +
      '（台中高鐵站步行約 8 分鐘）',
    keywords: ['地點', '地址', '在哪', '哪裡', '場地', '會場', '哪邊'],
  },
  {
    id: 'transport',
    question: '怎麼去 / 交通',
    answer:
      '交通方式 🚄\n' +
      '搭高鐵：台中高鐵站下車，步行約 8 分鐘即到。\n' +
      '開車：現場停車位逾 400 個。',
    keywords: ['怎麼去', '交通', '高鐵', '捷運', '火車', '搭車', '怎麼到'],
  },
  {
    id: 'parking',
    question: '有停車位嗎',
    answer: '有的 🚗 臻愛婚宴會館 烏日高鐵店現場停車位逾 400 個，開車前來很方便。',
    keywords: ['停車', '車位', '開車', '停車場'],
  },
  {
    id: 'dresscode',
    question: '要穿什麼',
    answer: '著裝建議：商務正式（Business Attire）👔 是理監事改選與就職典禮的正式場合喔～',
    keywords: ['穿什麼', '服裝', '著裝', '穿著', 'dresscode', '正式', '西裝'],
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
  },
  {
    id: 'speaker',
    question: '講師是誰',
    answer:
      '大師講座講師：國立臺灣大學生物資源暨農學院 院長 盧虎生（邀請中）🎓\n' +
      '講題方向：數據驅動的精準農業 —— AI 時代的農業永續與二代接班。',
    keywords: ['講師', '演講', '講座', '誰來講', '盧虎生', '大師', '主講'],
  },
  {
    id: 'chairman',
    question: '新任會長是誰',
    answer: '第六屆理事長：陳肇浩（米屋智農）🌾 當天將舉行就職交接典禮。',
    keywords: ['會長', '理事長', '誰是會長', '就職', '接班人'],
  },
  {
    id: 'subsidy',
    question: '政府補助 / 中衛',
    answer:
      '當天由「財團法人中衛發展中心」專題說明協會成員如何對接政府補助與計畫資源 🤝\n' +
      '（詳細講題確認中，歡迎當天到場了解。）',
    keywords: ['補助', '中衛', '政府', '計畫', '資源', '對接', '申請補助'],
  },
  {
    id: 'join-how',
    question: '怎麼入會 / 加入',
    answer:
      '歡迎加入 TADA！入會方式 📝\n' +
      '請至官網填寫入會申請表：https://tada-ai.org.tw/join/\n' +
      '個人、團體會員都可以申請，填完表單後依指示繳費即完成～',
    keywords: ['入會', '加入', '怎麼申請', '報名', '申請會員', '想加入', '會員資格'],
  },
  {
    id: 'fee',
    question: '會費多少',
    answer:
      '會費說明 💰（常年會費為三年一次繳清）\n' +
      '個人會員：入會費 NT$1,000 ＋ 常年會費 NT$6,000 ＝ 共 NT$7,000\n' +
      '團體會員：入會費 NT$10,000 ＋ 常年會費 NT$20,000 ＝ 共 NT$30,000',
    keywords: ['會費', '多少錢', '費用', '入會費', '常年會費', '幾錢', '價格'],
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
    keywords: ['匯款', '銀行', '帳號', '轉帳', '繳費', '匯錢', '付款', '戶名'],
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
  },
  {
    id: 'website',
    question: '官網網址',
    answer: '協會官網在這裡 🌐 https://tada-ai.org.tw\n入會申請：https://tada-ai.org.tw/join/',
    keywords: ['官網', '網站', '網址', '連結', '線上', 'website'],
  },
  {
    id: 'second-gen',
    question: '可以帶家人 / 二代嗎',
    answer: '非常歡迎 👨‍👩‍👧‍👦 本次特別鼓勵攜帶家族第二代共同出席，一起見證農業邁入 AI 新世代！',
    keywords: ['二代', '帶家人', '攜帶', '帶人', '眷屬', '家人', '小孩', '子女', '一起去'],
  },
];

// 正規化：轉小寫、移除空白與常見標點，方便關鍵字比對
function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[\s，。、！？!?.,~～「」『』（）()【】\-_/\\]/g, '');
}

export interface WikiMatch {
  entry: WikiEntry;
  score: number;
}

// 比對知識庫：回傳命中關鍵字最多的一則；沒有任何命中則回 null（零 token）
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
