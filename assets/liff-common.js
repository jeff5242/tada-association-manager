// TADA LIFF 共用設定
// 每個功能各自一個 LIFF app，且該 app 的「端點 URL」直接指向該功能頁，
// 這樣點按鈕開 https://liff.line.me/{id} 就會直接落在該頁，不需傳任何參數
// （避免參數在 LINE 登入 OAuth 轉導過程被去掉）。
window.TADA_LIFF_IDS = {
  rsvp:    '2010670397-AcAucbwI',   // 端點需設為 https://tada-ai.org.tw/rsvp/
  card:    '2010670397-e09JL6ri',   // 端點需設為 https://tada-ai.org.tw/card/
  payment: '2010670397-aJlbduya',   // 端點需設為 https://tada-ai.org.tw/payment/
  vote:    '2010670397-w3ylS0Bp',   // 端點需設為 https://tada-ai.org.tw/vote/
  consent: '2010670397-w3ylS0Bp',   // 復用 vote 的 LIFF app（同 channel，僅取身分驗證有效會員）
  members: '2010670397-PiHxP3es',   // 端點需設為 https://tada-ai.org.tw/members/
  bind:    ''                       // ← 待建立：新增一個 LIFF app，端點設 https://tada-ai.org.tw/bind/，把 LIFF ID 貼這裡
};

window.TADA_SB_URL = 'https://ldjugtfxtxnpvkqvjxew.supabase.co';
window.TADA_SB_KEY = 'sb_publishable_08XiE2fH7iY_nlr_K4NQ4w_kJZPkjnj';

window.tadaSbHeaders = function () {
  return {
    apikey: window.TADA_SB_KEY,
    Authorization: 'Bearer ' + window.TADA_SB_KEY,
    'Content-Type': 'application/json',
  };
};

// 功能開關（後台於 tada_config 可即時關閉）。feature = 'vote' | 'live' | 'consent'
// 讀不到 / 沒設定 → 視為開啟（true），不會誤擋。
window.tadaFeatureOn = async function (feature) {
  try {
    var r = await fetch(window.TADA_SB_URL + '/rest/v1/tada_config?key=eq.feature_' + feature + '&select=value', { headers: window.tadaSbHeaders() });
    if (!r.ok) return true;
    var rows = await r.json();
    if (!rows.length) return true;
    return String(rows[0].value) !== 'off';
  } catch (e) { return true; }
};

// 蓋整頁的「功能未開放」提示（綠金風格，自帶樣式，不依賴頁面 CSS）
window.tadaGateNotice = function (opts) {
  opts = opts || {};
  var title = opts.title || '暫未開放';
  var msg = opts.msg || '此功能目前尚未開放，敬請稍候。';
  var el = document.createElement('div');
  el.setAttribute('style', 'position:fixed;inset:0;z-index:99999;display:flex;align-items:center;justify-content:center;padding:28px;background:radial-gradient(120% 70% at 50% -10%,#24402b 0%,#0c160f 60%);font-family:"Noto Sans TC","PingFang TC",system-ui,sans-serif;');
  el.innerHTML = '<div style="max-width:420px;text-align:center;color:#f5ecd4;">'
    + '<div style="font-size:60px;line-height:1;">🌾</div>'
    + '<div style="font-family:\'Noto Serif TC\',serif;font-size:26px;font-weight:900;color:#e0b458;margin-top:16px;">' + title + '</div>'
    + '<div style="font-size:15px;line-height:1.9;color:#d9e6d0;margin-top:14px;">' + msg + '</div>'
    + '<a href="https://liff.line.me/2010670397-e09JL6ri" style="display:inline-block;margin-top:22px;color:#e0b458;font-weight:700;text-decoration:none;">← 返回電子會員證</a>'
    + '</div>';
  document.body.appendChild(el);
};

// 初始化 LIFF 並回傳 profile。key = 'rsvp' | 'card' | 'payment' | 'vote' | 'members'
// 不強制登入版：LINE 內開啟會自動帶身分；一般瀏覽器直接回 null 讓頁面用表單，
// 絕不觸發 liff.login() 跳轉（繳費回報這類公開表單用，避免會員被登入頁卡住）。
window.tadaInitLiffOptional = async function (key) {
  var id = (window.TADA_LIFF_IDS || {})[key];
  try {
    await liff.init({ liffId: id });
    if (liff.isLoggedIn()) return await liff.getProfile();
  } catch (e) {}
  return null;
};

window.tadaInitLiff = async function (key) {
  var id = (window.TADA_LIFF_IDS || {})[key];
  await liff.init({ liffId: id });
  if (!liff.isLoggedIn()) {
    liff.login();
    return null;
  }
  return await liff.getProfile();
};

// 回官網連結：LIFF／表單頁填完就是死路，補一個出口。
// 自帶樣式（各頁背景不同，深色頁傳 dark:true），不依賴頁面 CSS。
// 現場報到機（/guest/、/kiosk/、/checkin/）與投票頁刻意不加，避免誤觸離開。
window.tadaBackLink = function (opts) {
  opts = opts || {};
  var dark = !!opts.dark;
  var el = document.createElement('div');
  el.setAttribute('style', 'text-align:center;padding:26px 20px 34px;font-family:"Noto Sans TC","PingFang TC",sans-serif;');
  el.innerHTML = '<a href="https://tada-ai.org.tw/" target="_blank" rel="noopener" '
    + 'style="display:inline-flex;align-items:center;gap:7px;text-decoration:none;font-size:13px;font-weight:700;'
    + 'letter-spacing:.04em;padding:10px 20px;border-radius:99px;'
    + (dark
        ? 'color:#d4a853;border:1px solid rgba(212,168,83,.45);'
        : 'color:#1e3320;border:1px solid #e5ddc8;background:#fff;')
    + '">🌾 回 TADA 官網 ↗</a>';
  document.body.appendChild(el);
};
