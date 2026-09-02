-- ============================================================================
-- 報到來源（checkin_source）
--   目的：報到記錄要能分辨這個人是「怎麼報到的」，供事後稽核與流程檢討。
--   四種來源：
--     'card'   會員自己出示 LINE 電子會員證（QR 前綴 M:）
--     'slip'   會前預先列印的會員小白單（QR 前綴 P:）
--     'staff'  服務人員用手機 /assist/ 查出並產生的報到碼（QR 前綴 S:）
--     'manual' 服務人員在報到機上直接輸入會員編號／手機末碼
--   由前端在報到成功後寫入（anon 對 tada_v_members 本就有讀寫權），
--   RPC vote_checkin / vote_checkin_paper 的簽章維持不變，避免動到既有流程。
-- ============================================================================

ALTER TABLE tada_v_members
  ADD COLUMN IF NOT EXISTS checkin_source TEXT;

COMMENT ON COLUMN tada_v_members.checkin_source IS
  '報到來源：card=LINE電子會員證 / slip=預先列印小白單 / staff=服務人員手機產生 / manual=報到機手動輸入';

-- 既有已報到但沒來源的資料補成 unknown，統計時才不會與「尚未報到」混在一起
UPDATE tada_v_members
   SET checkin_source = 'unknown'
 WHERE is_checked_in = TRUE
   AND checkin_source IS NULL;

-- 取消報到時一併清掉來源（與 vote_method 同樣處理）
CREATE OR REPLACE FUNCTION election_clear_checkin_source(p_election UUID, p_member_no TEXT)
RETURNS VOID LANGUAGE sql SECURITY DEFINER AS $$
  UPDATE tada_v_members
     SET checkin_source = NULL
   WHERE election_id = p_election AND member_no = p_member_no;
$$;
GRANT EXECUTE ON FUNCTION election_clear_checkin_source(UUID, TEXT) TO anon;
