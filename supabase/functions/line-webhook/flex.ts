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
  ['16:10', '大師講座：AI × 精準農業'],
  ['16:50', '政府補助說明（中衛）'],
  ['17:10', 'Q&A 綜合討論'],
  ['17:30', '理事長交接典禮'],
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
          { type: 'text', text: '18:30', color: C.goldLt, size: 'sm', weight: 'bold', flex: 2 },
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
