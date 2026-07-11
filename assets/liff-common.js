// TADA LIFF 共用設定
// 每個功能各自一個 LIFF app，且該 app 的「端點 URL」直接指向該功能頁，
// 這樣點按鈕開 https://liff.line.me/{id} 就會直接落在該頁，不需傳任何參數
// （避免參數在 LINE 登入 OAuth 轉導過程被去掉）。
window.TADA_LIFF_IDS = {
  rsvp:    '2010670397-AcAucbwI',   // 端點需設為 https://tada-ai.org.tw/rsvp/
  card:    '2010670397-e09JL6ri',   // 端點需設為 https://tada-ai.org.tw/card/
  payment: '2010670397-aJlbduya',   // 端點需設為 https://tada-ai.org.tw/payment/
  vote:    '2010670397-w3ylS0Bp',   // 端點需設為 https://tada-ai.org.tw/vote/
  members: '2010670397-PiHxP3es'    // 端點需設為 https://tada-ai.org.tw/members/
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

// 初始化 LIFF 並回傳 profile。key = 'rsvp' | 'card' | 'payment' | 'vote' | 'members'
window.tadaInitLiff = async function (key) {
  var id = (window.TADA_LIFF_IDS || {})[key];
  await liff.init({ liffId: id });
  if (!liff.isLoggedIn()) {
    liff.login();
    return null;
  }
  return await liff.getProfile();
};
