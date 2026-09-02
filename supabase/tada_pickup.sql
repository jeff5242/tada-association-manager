-- 服務台領取記錄：/assist/ 頁 QR 下方的領取清單（名片/會員禮/選票/委託票）打勾後存這裡
-- 執行方式：Supabase Dashboard → SQL Editor 貼上執行一次
ALTER TABLE tada_v_members ADD COLUMN IF NOT EXISTS pickup JSONB DEFAULT '{}'::jsonb;
COMMENT ON COLUMN tada_v_members.pickup IS
  '領取記錄 {card:名片, gift:會員禮, ballot:選票, proxy:委託票}，值＝領取時間 HH:MM；由 /assist/ 服務台頁寫入';
