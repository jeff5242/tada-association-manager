// TADA LIFF 共用設定 —— 所有 LIFF 頁面（rsvp / card / payment / vote / members）共用
// LIFF app（端點 https://tada-ai.org.tw/）ID
window.TADA_LIFF_ID = '2010670397-AcAucbwI';

window.TADA_SB_URL = 'https://ldjugtfxtxnpvkqvjxew.supabase.co';
window.TADA_SB_KEY = 'sb_publishable_08XiE2fH7iY_nlr_K4NQ4w_kJZPkjnj';

window.tadaSbHeaders = function () {
  return {
    apikey: window.TADA_SB_KEY,
    Authorization: 'Bearer ' + window.TADA_SB_KEY,
    'Content-Type': 'application/json',
  };
};

// 初始化 LIFF 並回傳使用者 profile（未登入會自動導向登入）
window.tadaInitLiff = async function () {
  await liff.init({ liffId: window.TADA_LIFF_ID });
  if (!liff.isLoggedIn()) {
    liff.login();
    return null;
  }
  return await liff.getProfile();
};
