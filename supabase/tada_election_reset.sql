-- ============================================================================
-- 選舉重置（測試用）：重設報到旗標 + 清除未使用選票
--   tada_v_tokens 有 RLS 禁止 anon 直接刪除（匿名投票安全設計），
--   故清票必須走 SECURITY DEFINER RPC。
--   安全：只刪 status=0（未使用）的票；status=1（已核銷＝已投出）絕不刪。
-- ============================================================================
CREATE OR REPLACE FUNCTION election_reset_checkins(p_election UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_members INT; v_tokens INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tada_v_election WHERE id = p_election) THEN
    RETURN json_build_object('ok', false, 'error', 'election_not_found');
  END IF;

  UPDATE tada_v_members SET is_checked_in = FALSE, check_in_time = NULL
   WHERE election_id = p_election AND is_checked_in;
  GET DIAGNOSTICS v_members = ROW_COUNT;

  DELETE FROM tada_v_tokens WHERE election_id = p_election AND status = 0;
  GET DIAGNOSTICS v_tokens = ROW_COUNT;

  RETURN json_build_object('ok', true, 'members_reset', v_members, 'tokens_deleted', v_tokens);
END $$;
GRANT EXECUTE ON FUNCTION election_reset_checkins(UUID) TO anon;

NOTIFY pgrst, 'reload schema';
