-- ============================================================================
-- 報到紀錄清除（測試/勘誤用）
--   兩種：checkin_undo 逐筆撤銷、checkin_undo_before 依日期(含當日)以前清除。
--   撤銷報到同時刪除「等量的未使用選票」(status=0)，維持已核發票數一致；
--   已投出的票(status<>0)不受影響。tada_v_tokens 無身分連結（匿名），故僅能刪
--   等量的未使用票，不指定特定張。
-- ============================================================================

-- 逐筆撤銷某會員報到
CREATE OR REPLACE FUNCTION public.checkin_undo(p_election uuid, p_member_no text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE m tada_v_members%ROWTYPE; n INT; del INT;
BEGIN
  SELECT * INTO m FROM tada_v_members WHERE election_id=p_election AND member_no=p_member_no FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_found'); END IF;
  IF NOT COALESCE(m.is_checked_in,false) THEN RETURN json_build_object('ok',true,'noop',true,'name',m.name); END IF;

  -- 本人票(除非出席已委託出去) + 受託投票票數
  n := (CASE WHEN EXISTS (SELECT 1 FROM tada_v_proxy p WHERE p.election_id=p_election AND p.status='active' AND p.proxy_attend
                AND (p.principal_name=m.name OR (COALESCE(m.member_no,'')<>'' AND p.principal_no=m.member_no)))
             THEN 0 ELSE 1 END)
     + COALESCE((SELECT count(*) FROM tada_v_proxy p WHERE p.election_id=p_election AND p.status='active' AND p.proxy_vote
                  AND (p.delegate_name=m.name OR (COALESCE(m.member_no,'')<>'' AND p.delegate_no=m.member_no))),0);

  UPDATE tada_v_members SET is_checked_in=FALSE, check_in_time=NULL, vote_method=NULL WHERE id=m.id;

  WITH d AS (SELECT uuid FROM tada_v_tokens WHERE election_id=p_election AND status=0 LIMIT n)
  DELETE FROM tada_v_tokens t USING d WHERE t.uuid=d.uuid;
  GET DIAGNOSTICS del = ROW_COUNT;

  RETURN json_build_object('ok',true,'name',m.name,'member_no',m.member_no,'tokens_deleted',del);
END $fn$;

-- 依日期清除：撤銷 check_in_time < p_before 的所有報到（前端傳「隔日 00:00」即為「當日(含)以前」）
CREATE OR REPLACE FUNCTION public.checkin_undo_before(p_election uuid, p_before timestamptz)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE v_members INT; v_ballots INT; del INT;
BEGIN
  SELECT count(*) INTO v_members FROM tada_v_members
   WHERE election_id=p_election AND is_checked_in AND check_in_time < p_before;
  IF v_members=0 THEN RETURN json_build_object('ok',true,'members_reset',0,'tokens_deleted',0); END IF;

  -- 這批人核發的總票數（本人票＋受託投票票）
  SELECT COALESCE(count(*) FILTER (WHERE NOT delegated_away),0) + COALESCE(sum(pv),0) INTO v_ballots
  FROM (
    SELECT
      EXISTS (SELECT 1 FROM tada_v_proxy p WHERE p.election_id=p_election AND p.status='active' AND p.proxy_attend
                AND (p.principal_name=m.name OR (COALESCE(m.member_no,'')<>'' AND p.principal_no=m.member_no))) AS delegated_away,
      (SELECT count(*) FROM tada_v_proxy p WHERE p.election_id=p_election AND p.status='active' AND p.proxy_vote
                AND (p.delegate_name=m.name OR (COALESCE(m.member_no,'')<>'' AND p.delegate_no=m.member_no))) AS pv
    FROM tada_v_members m
    WHERE m.election_id=p_election AND m.is_checked_in AND m.check_in_time < p_before
  ) s;

  UPDATE tada_v_members SET is_checked_in=FALSE, check_in_time=NULL, vote_method=NULL
   WHERE election_id=p_election AND is_checked_in AND check_in_time < p_before;

  WITH d AS (SELECT uuid FROM tada_v_tokens WHERE election_id=p_election AND status=0 LIMIT v_ballots)
  DELETE FROM tada_v_tokens t USING d WHERE t.uuid=d.uuid;
  GET DIAGNOSTICS del = ROW_COUNT;

  RETURN json_build_object('ok',true,'members_reset',v_members,'tokens_deleted',del);
END $fn$;

NOTIFY pgrst, 'reload schema';
