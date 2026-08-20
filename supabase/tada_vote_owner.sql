-- ============================================================================
-- 電子選票「持有人鎖」(2026-08-20)
-- 需求：列印/螢幕上的選票 QR 若被他人撿到或轉傳，不能投票——
--       必須以「領票本人」的 LINE 帳號開啟 /vote/?t= 才能圈選送出。
--
-- 匿名性不變：tada_v_votes 依舊不記 token、不記身分。
--   本檔只在 tada_v_tokens 加 owner_key = sha256(LINE userId)，
--   能證明「這張票發給誰、用掉沒」，仍無法回溯「誰投給誰」。
--
-- 綁定規則：
--   1) 發票時（vote_checkin）：領票會員在投票名冊有 line_user_id → 直接綁定。
--      受託代理票同樣綁給「受託人」本人（票由受託人領、受託人投）。
--   2) 發票時沒有 LINE 綁定（人工鍵盤補報到）→ owner_key 先空著，
--      第一次在 LINE 中開啟選票時綁定該帳號（票為當面交付，首開即本人）。
--   3) vote_ballot / vote_cast 一律要求 p_user_id；owner_key 不符回 not_owner。
--
-- 執行位置：Supabase SQL Editor → RUN（本檔可重複執行）。
-- 依賴：tada_voting.sql、tada_proxy.sql、tada_group_reps_voting.sql 已部署。
-- ============================================================================

ALTER TABLE tada_v_tokens  ADD COLUMN IF NOT EXISTS owner_key TEXT;
ALTER TABLE tada_v_members ADD COLUMN IF NOT EXISTS line_user_id TEXT;  -- 保險（正常已存在）

-- LINE userId → 持有人指紋（PG11+ 內建 sha256，不需 pgcrypto）
CREATE OR REPLACE FUNCTION tada_owner_key(p_user_id TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS
$$ SELECT encode(sha256(convert_to(p_user_id, 'UTF8')), 'hex') $$;

-- ============================================================================
-- vote_checkin（覆寫 tada_proxy.sql 版）：發票時綁定持有人
--   邏輯與 proxy 版完全相同，僅 INSERT tokens 時多寫 owner_key。
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_checkin(p_election UUID, p_member_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_status TEXT;
  v_member tada_v_members%ROWTYPE;
  v_self_prin tada_v_proxy%ROWTYPE;   -- 我送出的委託（我是委託人）
  v_self_ballot INT := 1;
  v_extra INT := 0;                    -- 我受託且含投票權 → 每筆多一票
  v_attend_rep INT := 0;              -- 我受託且含出席權 → 代表出席人數
  v_total INT;
  v_uuid UUID; v_first UUID := NULL;
  v_uuids UUID[] := '{}';
  v_principals JSON;
  v_owner TEXT;
  i INT;
BEGIN
  SELECT status INTO v_status FROM tada_v_election WHERE id = p_election;
  IF v_status IS NULL THEN RETURN json_build_object('ok',false,'error','election_not_found'); END IF;
  IF v_status NOT IN ('checkin','open') THEN RETURN json_build_object('ok',false,'error','not_open'); END IF;

  -- 悲觀鎖：鎖定該會員列
  SELECT * INTO v_member FROM tada_v_members
   WHERE election_id = p_election AND member_no = p_member_no FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','member_not_found'); END IF;
  IF v_member.is_checked_in THEN
    RETURN json_build_object('ok',false,'error','already_checked_in','name',v_member.name); END IF;

  -- 我是否為委託人（已把權利委託出去）
  SELECT * INTO v_self_prin FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (principal_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND principal_no = v_member.member_no)) LIMIT 1;
  IF v_self_prin.id IS NOT NULL THEN
    IF v_self_prin.proxy_attend THEN
      RETURN json_build_object('ok',false,'error','delegated_away',
        'name',v_member.name,'delegate_name',v_self_prin.delegate_name); END IF;
    v_self_ballot := 0;
  END IF;

  -- 我受託的委託：投票權張數、出席代表數
  SELECT COALESCE(count(*) FILTER (WHERE proxy_vote),0), COALESCE(count(*) FILTER (WHERE proxy_attend),0)
    INTO v_extra, v_attend_rep
    FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (delegate_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND delegate_no = v_member.member_no));

  UPDATE tada_v_members SET is_checked_in = TRUE, check_in_time = NOW(), vote_method = 'online' WHERE id = v_member.id;

  -- 持有人指紋：領票會員已綁 LINE → 發票即綁定；否則留空、首開時綁定
  v_owner := CASE WHEN COALESCE(v_member.line_user_id,'') <> ''
                  THEN tada_owner_key(v_member.line_user_id) END;

  -- 發票：本人票 + 受託投票票（全部綁給領票人本人）
  v_total := v_self_ballot + v_extra;
  i := 0;
  WHILE i < v_total LOOP
    INSERT INTO tada_v_tokens (election_id, status, owner_key)
      VALUES (p_election, 0, v_owner) RETURNING uuid INTO v_uuid;
    v_uuids := array_append(v_uuids, v_uuid);
    IF v_first IS NULL THEN v_first := v_uuid; END IF;
    i := i + 1;
  END LOOP;

  -- 我代表出席的委託人名單（顯示用）
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
    'proxy_principals', COALESCE(v_principals,'[]'::json)
  );
END $$;
GRANT EXECUTE ON FUNCTION vote_checkin(UUID, TEXT) TO anon;

-- ============================================================================
-- vote_ballot：加 p_user_id 持有人驗證（舊單參數版本移除，DEFAULT 保持相容）
-- ============================================================================
DROP FUNCTION IF EXISTS vote_ballot(UUID);
CREATE OR REPLACE FUNCTION vote_ballot(p_uuid UUID, p_user_id TEXT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tok   tada_v_tokens%ROWTYPE;
  v_e     tada_v_election%ROWTYPE;
  v_cands JSON;
BEGIN
  -- FOR UPDATE：首開綁定不能被併發搶先
  SELECT * INTO v_tok FROM tada_v_tokens WHERE uuid = p_uuid FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'invalid'); END IF;
  IF v_tok.status <> 0 THEN RETURN json_build_object('ok', false, 'error', 'used'); END IF;

  -- 持有人鎖：一律要求 LINE 身分
  IF COALESCE(p_user_id,'') = '' THEN
    RETURN json_build_object('ok', false, 'error', 'need_line');
  END IF;
  IF v_tok.owner_key IS NOT NULL THEN
    IF tada_owner_key(p_user_id) <> v_tok.owner_key THEN
      RETURN json_build_object('ok', false, 'error', 'not_owner');
    END IF;
  ELSE
    -- 發票時未綁 LINE → 首開即綁定（票為報到時當面交付）
    UPDATE tada_v_tokens SET owner_key = tada_owner_key(p_user_id) WHERE uuid = p_uuid;
  END IF;

  SELECT * INTO v_e FROM tada_v_election WHERE id = v_tok.election_id;
  IF v_e.status <> 'open' THEN RETURN json_build_object('ok', false, 'error', 'not_open'); END IF;

  -- c.*：候選人為公開表，全欄位回傳；線上另加的欄位（如 recommended）自動帶出
  SELECT json_agg(row_to_json(t)) INTO v_cands FROM (
    SELECT c.*
      FROM tada_v_candidates c
     WHERE c.election_id = v_tok.election_id
       AND c.position = ANY (v_e.member_ballot)
     ORDER BY c.position, c.sort, c.no
  ) t;

  RETURN json_build_object(
    'ok', true,
    'election', json_build_object(
      'id', v_e.id, 'title', v_e.title,
      'director_seats', v_e.director_seats, 'director_pick', v_e.director_pick,
      'supervisor_seats', v_e.supervisor_seats, 'supervisor_pick', v_e.supervisor_pick,
      'executive_seats', v_e.executive_seats, 'executive_pick', v_e.executive_pick,
      'member_ballot', v_e.member_ballot
    ),
    'candidates', COALESCE(v_cands, '[]'::json)
  );
END $$;
GRANT EXECUTE ON FUNCTION vote_ballot(UUID, TEXT) TO anon;

-- ============================================================================
-- vote_cast：加 p_user_id 持有人驗證（舊四參數版本移除，DEFAULT 保持相容）
-- ============================================================================
DROP FUNCTION IF EXISTS vote_cast(UUID, UUID[], UUID[], UUID[]);
CREATE OR REPLACE FUNCTION vote_cast(
  p_uuid        UUID,
  p_directors   UUID[] DEFAULT '{}',
  p_supervisors UUID[] DEFAULT '{}',
  p_executives  UUID[] DEFAULT '{}',
  p_user_id     TEXT   DEFAULT NULL
)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tok tada_v_tokens%ROWTYPE;
  v_e   tada_v_election%ROWTYPE;
  d UUID[]; s UUID[]; x UUID[];
  cid UUID;
BEGIN
  -- 悲觀鎖：先鎖定 token 列（併發下其它交易需等待）
  SELECT * INTO v_tok FROM tada_v_tokens WHERE uuid = p_uuid FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'invalid_token'); END IF;
  IF v_tok.status <> 0 THEN RETURN json_build_object('ok', false, 'error', 'already_voted'); END IF;

  -- 持有人鎖（與 vote_ballot 同規則；未綁定票在此仍可首綁，防繞過 ballot 直呼 cast）
  IF COALESCE(p_user_id,'') = '' THEN
    RETURN json_build_object('ok', false, 'error', 'need_line');
  END IF;
  IF v_tok.owner_key IS NOT NULL THEN
    IF tada_owner_key(p_user_id) <> v_tok.owner_key THEN
      RETURN json_build_object('ok', false, 'error', 'not_owner');
    END IF;
  ELSE
    UPDATE tada_v_tokens SET owner_key = tada_owner_key(p_user_id) WHERE uuid = p_uuid;
  END IF;

  SELECT * INTO v_e FROM tada_v_election WHERE id = v_tok.election_id;
  IF v_e.status <> 'open' THEN RETURN json_build_object('ok', false, 'error', 'not_open'); END IF;

  -- 去除重複圈選
  SELECT COALESCE(array_agg(DISTINCT e), '{}') INTO d FROM unnest(p_directors)   AS e;
  SELECT COALESCE(array_agg(DISTINCT e), '{}') INTO s FROM unnest(p_supervisors) AS e;
  SELECT COALESCE(array_agg(DISTINCT e), '{}') INTO x FROM unnest(p_executives)  AS e;

  -- 圈選上限驗證（連記法：超過上限＝無效）
  IF COALESCE(array_length(d,1),0) > v_e.director_pick   THEN RETURN json_build_object('ok', false, 'error', 'too_many_directors');   END IF;
  IF COALESCE(array_length(s,1),0) > v_e.supervisor_pick THEN RETURN json_build_object('ok', false, 'error', 'too_many_supervisors'); END IF;
  IF COALESCE(array_length(x,1),0) > v_e.executive_pick  THEN RETURN json_build_object('ok', false, 'error', 'too_many_executives');  END IF;

  -- 候選人必須屬於本場次且職位相符
  IF EXISTS (SELECT 1 FROM unnest(d) e WHERE NOT EXISTS (
        SELECT 1 FROM tada_v_candidates c WHERE c.id=e AND c.election_id=v_tok.election_id AND c.position='director'))
     OR EXISTS (SELECT 1 FROM unnest(s) e WHERE NOT EXISTS (
        SELECT 1 FROM tada_v_candidates c WHERE c.id=e AND c.election_id=v_tok.election_id AND c.position='supervisor'))
     OR EXISTS (SELECT 1 FROM unnest(x) e WHERE NOT EXISTS (
        SELECT 1 FROM tada_v_candidates c WHERE c.id=e AND c.election_id=v_tok.election_id AND c.position='executive'))
  THEN
    RETURN json_build_object('ok', false, 'error', 'invalid_candidate');
  END IF;

  -- 核銷選票（狀態 0 → 1）
  UPDATE tada_v_tokens SET status = 1, used_at = NOW() WHERE uuid = p_uuid;

  -- 逐筆寫入得票（不記錄來自哪張 token）
  FOREACH cid IN ARRAY d LOOP
    INSERT INTO tada_v_votes (election_id, position, candidate_id) VALUES (v_tok.election_id, 'director', cid);
  END LOOP;
  FOREACH cid IN ARRAY s LOOP
    INSERT INTO tada_v_votes (election_id, position, candidate_id) VALUES (v_tok.election_id, 'supervisor', cid);
  END LOOP;
  FOREACH cid IN ARRAY x LOOP
    INSERT INTO tada_v_votes (election_id, position, candidate_id) VALUES (v_tok.election_id, 'executive', cid);
  END LOOP;

  RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION vote_cast(UUID, UUID[], UUID[], UUID[], TEXT) TO anon;

NOTIFY pgrst, 'reload schema';
