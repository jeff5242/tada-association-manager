-- ============================================================================
-- 並行投票（線上＋紙本），維持匿名（方案 A）
--   報到台二選一：領電子票（線上投票）或領紙本票。is_checked_in 擋重複。
--   紙本票不發 tada_v_tokens；紙本得票由監票人清點後於後台輸入併入結果。
-- ============================================================================

-- 記錄投票方式（線上 / 紙本）——只記「用哪種」，不影響匿名（不連到投給誰）
ALTER TABLE tada_v_members ADD COLUMN IF NOT EXISTS vote_method TEXT;   -- NULL | 'online' | 'paper'
-- 得票來源（數位／紙本），供開票分別統計與紙本可重覆輸入
ALTER TABLE tada_v_votes   ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'digital';

-- ============================================================================
-- 紙本報到領票：標記已報到＋vote_method='paper'，不發電子票；回傳應印張數與代理資訊
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_checkin_paper(p_election UUID, p_member_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_status TEXT; v_member tada_v_members%ROWTYPE; v_self_prin tada_v_proxy%ROWTYPE;
  v_self_ballot INT := 1; v_extra INT := 0; v_attend_rep INT := 0; v_principals JSON;
BEGIN
  SELECT status INTO v_status FROM tada_v_election WHERE id = p_election;
  IF v_status IS NULL THEN RETURN json_build_object('ok',false,'error','election_not_found'); END IF;
  IF v_status NOT IN ('checkin','open') THEN RETURN json_build_object('ok',false,'error','not_open'); END IF;

  SELECT * INTO v_member FROM tada_v_members
   WHERE election_id = p_election AND member_no = p_member_no FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','member_not_found'); END IF;
  IF v_member.is_checked_in THEN
    RETURN json_build_object('ok',false,'error','already_checked_in','name',v_member.name); END IF;

  -- 委託人（已把出席委託出去）不得報到
  SELECT * INTO v_self_prin FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (principal_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND principal_no = v_member.member_no)) LIMIT 1;
  IF v_self_prin.id IS NOT NULL AND v_self_prin.proxy_attend THEN
    RETURN json_build_object('ok',false,'error','delegated_away','name',v_member.name,'delegate_name',v_self_prin.delegate_name); END IF;
  IF v_self_prin.id IS NOT NULL AND v_self_prin.proxy_vote THEN v_self_ballot := 0; END IF;

  -- 受託投票／出席
  SELECT COALESCE(count(*) FILTER (WHERE proxy_vote),0), COALESCE(count(*) FILTER (WHERE proxy_attend),0)
    INTO v_extra, v_attend_rep
    FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (delegate_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND delegate_no = v_member.member_no));

  UPDATE tada_v_members SET is_checked_in = TRUE, check_in_time = NOW(), vote_method = 'paper' WHERE id = v_member.id;
  -- 紙本不發 tada_v_tokens

  SELECT json_agg(principal_name) INTO v_principals FROM tada_v_proxy
   WHERE election_id = p_election AND status='active' AND proxy_attend
     AND (delegate_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND delegate_no = v_member.member_no));

  RETURN json_build_object(
    'ok', true, 'method','paper',
    'name', v_member.name, 'member_no', v_member.member_no,
    'member_type', v_member.member_type, 'rep', v_member.rep,
    'self_ballot', v_self_ballot, 'proxy_vote_count', v_extra, 'attend_rep', v_attend_rep,
    'ballots', v_self_ballot + v_extra,
    'proxy_principals', COALESCE(v_principals,'[]'::json)
  );
END $$;
GRANT EXECUTE ON FUNCTION vote_checkin_paper(UUID, TEXT) TO anon;

-- ============================================================================
-- 紙本開票：輸入各候選人紙本得票數（可重覆輸入；先清舊紙本票再寫入）
--   p_tallies = [{"candidate_id":"...","count":N}, ...]
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_tally_paper(p_election UUID, p_tallies JSONB)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE t JSONB; cid UUID; cnt INT; pos TEXT; i INT; total INT := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tada_v_election WHERE id = p_election) THEN
    RETURN json_build_object('ok',false,'error','election_not_found'); END IF;

  DELETE FROM tada_v_votes WHERE election_id = p_election AND source = 'paper';

  FOR t IN SELECT * FROM jsonb_array_elements(p_tallies) LOOP
    cid := (t->>'candidate_id')::uuid;
    cnt := COALESCE((t->>'count')::int, 0);
    SELECT position INTO pos FROM tada_v_candidates WHERE id = cid AND election_id = p_election;
    IF pos IS NULL OR cnt <= 0 THEN CONTINUE; END IF;
    i := 0;
    WHILE i < cnt LOOP
      INSERT INTO tada_v_votes (election_id, position, candidate_id, source) VALUES (p_election, pos, cid, 'paper');
      i := i + 1; total := total + 1;
    END LOOP;
  END LOOP;

  RETURN json_build_object('ok', true, 'inserted', total);
END $$;
GRANT EXECUTE ON FUNCTION vote_tally_paper(UUID, JSONB) TO anon;

NOTIFY pgrst, 'reload schema';
