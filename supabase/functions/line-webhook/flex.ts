// LINE Flex Message 版型 —— 讓 TADA醬 的「議程」「匯款資訊」以精緻卡片呈現
// 色系沿用協會綠金風格

const C = {
  green: '#1E3320',
  gold: '#B8913A',
  goldLt: '#D4A853',
  cream: '#F8F4EA',
  pale: '#F5ECD4',
  ink: '#1A1A14',
  gray: '#5A8A60',
  line: '#E5DDC8',
};

// 議程單列（時間 + 項目）
function agendaRow(time: string, title: string) {
  return {
    type: 'box',
    layout: 'baseline',
    spacing: 'md',
    contents: [
      { type: 'text', text: time, color: C.gold, size: 'sm', weight: 'bold', flex: 2 },
      { type: 'text', text: title, color: C.ink, size: 'sm', flex: 6, wrap: true },
    ],
  };
}

// 資訊單列（標籤 + 值）
function infoRow(label: string, value: string) {
  return {
    type: 'box',
    layout: 'baseline',
    spacing: 'md',
    contents: [
      { type: 'text', text: label, color: C.gray, size: 'xs', flex: 2 },
      { type: 'text', text: value, color: C.ink, size: 'sm', flex: 6, wrap: true, weight: 'bold' },
    ],
  };
}

const AGENDA_ITEMS: [string, string][] = [
  ['15:00', '開放入場・報到'],
  ['15:30', '會務討論・理監事改選'],
  ['16:30', '政府補助說明（中衛）'],
  ['17:00', '大師講座｜李紅曦 代理院長'],
  ['17:40', '理事長交接典禮'],
];

// 活動議程卡片
export const AGENDA_FLEX = {
  type: 'bubble',
  header: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.green,
    paddingAll: '18px',
    contents: [
      { type: 'text', text: '活動議程 PROGRAM', color: C.goldLt, size: 'sm', weight: 'bold' },
      { type: 'text', text: '智耕傳承 農業新世代', color: '#FFFFFF', size: 'lg', weight: 'bold', margin: 'sm' },
      { type: 'text', text: '2026 / 09 / 04（五）｜臻愛婚宴會館', color: C.pale, size: 'xs', margin: 'sm' },
    ],
  },
  body: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.cream,
    paddingAll: '18px',
    spacing: 'md',
    contents: [
      ...AGENDA_ITEMS.map((i) => agendaRow(i[0], i[1])),
      { type: 'separator', margin: 'md', color: C.line },
      {
        type: 'box',
        layout: 'baseline',
        spacing: 'md',
        margin: 'md',
        contents: [
          { type: 'text', text: '18:00', color: C.goldLt, size: 'sm', weight: 'bold', flex: 2 },
          { type: 'text', text: '豐收晚宴　20:30 賦歸', color: C.green, size: 'sm', weight: 'bold', flex: 6, wrap: true },
        ],
      },
    ],
  },
};

// 匯款資訊卡片（含「我已完成匯款・回報」按鈕開啟繳費 LIFF）
export const PAYMENT_FLEX = {
  type: 'bubble',
  header: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.green,
    paddingAll: '18px',
    contents: [
      { type: 'text', text: '匯款資訊', color: C.goldLt, size: 'sm', weight: 'bold' },
      { type: 'text', text: '會費請匯至下列帳戶', color: C.pale, size: 'xs', margin: 'sm' },
    ],
  },
  body: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.cream,
    paddingAll: '18px',
    spacing: 'md',
    contents: [
      infoRow('銀行', '京城銀行 太保分行'),
      infoRow('代號', '0540641'),
      {
        type: 'box',
        layout: 'vertical',
        spacing: 'none',
        contents: [
          { type: 'text', text: '帳號', color: C.gray, size: 'xs' },
          { type: 'text', text: '064125019127', color: C.gold, size: 'xl', weight: 'bold' },
        ],
      },
      infoRow('戶名', '台灣科技農企業發展協會'),
      { type: 'separator', margin: 'md', color: C.line },
      { type: 'text', text: '⚠️ 匯款後請按下方回報帳號後 5 碼', color: C.gray, size: 'xs', wrap: true, margin: 'md' },
    ],
  },
  footer: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.cream,
    paddingAll: '12px',
    contents: [
      {
        type: 'button',
        style: 'primary',
        color: C.green,
        action: { type: 'uri', label: '📝 我已完成匯款・回報', uri: 'https://liff.line.me/2010670397-aJlbduya' },
      },
    ],
  },
};

// 聯絡我們卡片（含撥號 / 寄信按鈕）
export const CONTACT_FLEX = {
  type: 'bubble',
  header: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.green,
    paddingAll: '18px',
    contents: [
      { type: 'text', text: '聯絡我們 CONTACT', color: C.goldLt, size: 'sm', weight: 'bold' },
      { type: 'text', text: '協會秘書處', color: '#FFFFFF', size: 'lg', weight: 'bold', margin: 'sm' },
    ],
  },
  body: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.cream,
    paddingAll: '18px',
    spacing: 'md',
    contents: [
      {
        type: 'box',
        layout: 'vertical',
        spacing: 'xs',
        contents: [
          { type: 'text', text: '電話', color: C.gray, size: 'xs' },
          { type: 'text', text: '0988-558246（雅琳、馨元）', color: C.ink, size: 'md', weight: 'bold' },
        ],
      },
      {
        type: 'box',
        layout: 'vertical',
        spacing: 'xs',
        contents: [
          { type: 'text', text: 'Email', color: C.gray, size: 'xs' },
          { type: 'text', text: 'tada201107@gmail.com', color: C.ink, size: 'sm', weight: 'bold' },
        ],
      },
    ],
  },
  footer: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.cream,
    paddingAll: '12px',
    spacing: 'sm',
    contents: [
      {
        type: 'button',
        style: 'primary',
        height: 'sm',
        color: C.green,
        action: { type: 'uri', label: '📞 撥打電話', uri: 'tel:0988558246' },
      },
      {
        type: 'button',
        style: 'secondary',
        height: 'sm',
        action: { type: 'uri', label: '📧 寄送 Email', uri: 'mailto:tada201107@gmail.com' },
      },
    ],
  },
};

// 會費明細單列
function feeLine(label: string, val: string) {
  return {
    type: 'box',
    layout: 'baseline',
    contents: [
      { type: 'text', text: label, color: C.gray, size: 'sm', flex: 5 },
      { type: 'text', text: val, color: C.ink, size: 'sm', align: 'end', flex: 4 },
    ],
  };
}

// 會費方案區塊
function feePlan(title: string, join: string, annual: string, total: string) {
  return {
    type: 'box',
    layout: 'vertical',
    backgroundColor: '#FFFFFF',
    cornerRadius: '8px',
    paddingAll: '14px',
    spacing: 'sm',
    borderColor: C.line,
    borderWidth: '1px',
    contents: [
      { type: 'text', text: title, color: C.green, size: 'md', weight: 'bold' },
      feeLine('入會費', join),
      feeLine('常年會費・三年', annual),
      { type: 'separator', color: C.line },
      {
        type: 'box',
        layout: 'baseline',
        contents: [
          { type: 'text', text: '合計', color: C.green, size: 'sm', weight: 'bold', flex: 3 },
          { type: 'text', text: total, color: C.gold, size: 'lg', weight: 'bold', align: 'end', flex: 5 },
        ],
      },
    ],
  };
}

// 會費說明卡片
export const FEE_FLEX = {
  type: 'bubble',
  header: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.green,
    paddingAll: '18px',
    contents: [
      { type: 'text', text: '會費說明 FEES', color: C.goldLt, size: 'sm', weight: 'bold' },
      { type: 'text', text: '常年會費・三年一次繳清', color: C.pale, size: 'xs', margin: 'sm' },
    ],
  },
  body: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.cream,
    paddingAll: '16px',
    spacing: 'md',
    contents: [
      feePlan('個人會員', 'NT$1,000', 'NT$6,000', 'NT$7,000'),
      feePlan('團體會員', 'NT$10,000', 'NT$20,000', 'NT$30,000'),
    ],
  },
  footer: {
    type: 'box',
    layout: 'vertical',
    backgroundColor: C.cream,
    paddingAll: '12px',
    contents: [
      {
        type: 'button',
        style: 'primary',
        color: C.green,
        action: { type: 'uri', label: '🌱 我要入會', uri: 'https://tada-ai.org.tw/join/' },
      },
    ],
  },
};
