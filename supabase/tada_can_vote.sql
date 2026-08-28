-- ============================================================================
-- 可否投票欄位 can_vote（2026-08-28）
-- 需求：本屆投票資格以第五屆會員為主；新入會會員可出席、領名片/禮物，
--       但不發選票。名冊由秘書長在後台逐列勾選「可投票」。
--
-- 行為：can_vote=false 的會員報到「照常成功」（計出席、記報到時間），
--       但本人票與受託票一律不發（self_ballot=0、proxy 票數=0），
--       報到機依回傳的 can_vote=false 印「新會員本屆無投票權」備註、
--       不印選票勾選項與條碼。
--
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）。
-- 依賴：tada_vote_owner.sql（vote_checkin 持有人鎖版）、tada_voting_paper.sql。
-- ============================================================================

ALTER TABLE tada_v_members ADD COLUMN IF NOT EXISTS can_vote BOOLEAN NOT NULL DEFAULT true;

-- ============================================================================
-- vote_checkin（覆寫 tada_vote_owner.sql 版）：加 can_vote 閘門
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_checkin(p_election UUID, p_member_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_status TEXT;
  v_member tada_v_members%ROWTYPE;
  v_self_prin tada_v_proxy%ROWTYPE;
  v_self_ballot INT := 1;
  v_extra INT := 0;
  v_attend_rep INT := 0;
  v_total INT;
  v_uuid UUID; v_first UUID := NULL;
  v_uuids UUID[] := '{}';
  v_principals JSON;
  v_owner TEXT;
  v_can BOOLEAN;
  i INT;
BEGIN
  SELECT status INTO v_status FROM tada_v_election WHERE id = p_election;
  IF v_status IS NULL THEN RETURN json_build_object('ok',false,'error','election_not_found'); END IF;
  IF v_status NOT IN ('checkin','open') THEN RETURN json_build_object('ok',false,'error','not_open'); END IF;

  SELECT * INTO v_member FROM tada_v_members
   WHERE election_id = p_election AND member_no = p_member_no FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','member_not_found'); END IF;
  IF v_member.is_checked_in THEN
    RETURN json_build_object('ok',false,'error','already_checked_in','name',v_member.name); END IF;

  v_can := COALESCE(v_member.can_vote, TRUE);

  SELECT * INTO v_self_prin FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (principal_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND principal_no = v_member.member_no)) LIMIT 1;
  IF v_self_prin.id IS NOT NULL THEN
    IF v_self_prin.proxy_attend THEN
      RETURN json_build_object('ok',false,'error','delegated_away',
        'name',v_member.name,'delegate_name',v_self_prin.delegate_name); END IF;
    v_self_ballot := 0;
  END IF;

  SELECT COALESCE(count(*) FILTER (WHERE proxy_vote),0), COALESCE(count(*) FILTER (WHERE proxy_attend),0)
    INTO v_extra, v_attend_rep
    FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (delegate_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND delegate_no = v_member.member_no));

  -- 無投票權：出席照常，但本人票與受託票一律不發
  IF NOT v_can THEN
    v_self_ballot := 0;
    v_extra := 0;
  END IF;

  UPDATE tada_v_members SET is_checked_in = TRUE, check_in_time = NOW(), vote_method = 'online' WHERE id = v_member.id;

  v_owner := CASE WHEN COALESCE(v_member.line_user_id,'') <> ''
                  THEN tada_owner_key(v_member.line_user_id) END;

  v_total := v_self_ballot + v_extra;
  i := 0;
  WHILE i < v_total LOOP
    INSERT INTO tada_v_tokens (election_id, status, owner_key)
      VALUES (p_election, 0, v_owner) RETURNING uuid INTO v_uuid;
    v_uuids := array_append(v_uuids, v_uuid);
    IF v_first IS NULL THEN v_first := v_uuid; END IF;
    i := i + 1;
  END LOOP;

  SELECT json_agg(principal_name) INTO v_principals FROM tada_v_proxy
   WHERE election_id = p_election AND status='active' AND proxy_attend
     AND (delegate_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND delegate_no = v_member.member_no));

  RETURN json_build_object(
    'ok', true,
    'uuid', v_first,
    'uuids', to_json(v_uuids),
    'name', v_member.name, 'member_no', v_member.member_no,
    'member_type', v_member.member_type, 'rep', v_member.rep,
    'self_ballot', v_self_ballot,
    'proxy_vote_count', v_extra,
    'attend_rep', v_attend_rep,
    'ballots', v_total,
    'can_vote', v_can,
    'proxy_principals', COALESCE(v_principals,'[]'::json)
  );
END $$;
GRANT EXECUTE ON FUNCTION vote_checkin(UUID, TEXT) TO anon;

-- ============================================================================
-- vote_checkin_paper（覆寫 tada_voting_paper.sql 版）：加 can_vote 閘門
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_checkin_paper(p_election UUID, p_member_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_status TEXT; v_member tada_v_members%ROWTYPE; v_self_prin tada_v_proxy%ROWTYPE;
  v_self_ballot INT := 1; v_extra INT := 0; v_attend_rep INT := 0; v_principals JSON;
  v_can BOOLEAN;
BEGIN
  SELECT status INTO v_status FROM tada_v_election WHERE id = p_election;
  IF v_status IS NULL THEN RETURN json_build_object('ok',false,'error','election_not_found'); END IF;
  IF v_status NOT IN ('checkin','open') THEN RETURN json_build_object('ok',false,'error','not_open'); END IF;

  SELECT * INTO v_member FROM tada_v_members
   WHERE election_id = p_election AND member_no = p_member_no FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','member_not_found'); END IF;
  IF v_member.is_checked_in THEN
    RETURN json_build_object('ok',false,'error','already_checked_in','name',v_member.name); END IF;

  v_can := COALESCE(v_member.can_vote, TRUE);

  SELECT * INTO v_self_prin FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (principal_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND principal_no = v_member.member_no)) LIMIT 1;
  IF v_self_prin.id IS NOT NULL AND v_self_prin.proxy_attend THEN
    RETURN json_build_object('ok',false,'error','delegated_away','name',v_member.name,'delegate_name',v_self_prin.delegate_name); END IF;
  IF v_self_prin.id IS NOT NULL AND v_self_prin.proxy_vote THEN v_self_ballot := 0; END IF;

  SELECT COALESCE(count(*) FILTER (WHERE proxy_vote),0), COALESCE(count(*) FILTER (WHERE proxy_attend),0)
    INTO v_extra, v_attend_rep
    FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (delegate_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND delegate_no = v_member.member_no));

  -- 無投票權：出席照常，但本人票與受託票一律不發
  IF NOT v_can THEN
    v_self_ballot := 0;
    v_extra := 0;
  END IF;

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
    'can_vote', v_can,
    'proxy_principals', COALESCE(v_principals,'[]'::json)
  );
END $$;
GRANT EXECUTE ON FUNCTION vote_checkin_paper(UUID, TEXT) TO anon;

NOTIFY pgrst, 'reload schema';
