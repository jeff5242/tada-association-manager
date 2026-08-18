-- ============================================================================
-- TADA 委託代理（出席／投票）— 完整版
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）；或走 mgmt API。
--
-- 規則（與 docs/委託代理開發規格.md 一致）：
--   委託資格   委託人與受託人都必須在投票名冊 tada_v_members（有效+榮譽+永久+待續約）
--   一對一     受託人同時只能持有 1 筆有效委託；委託人只能送出 1 筆
--   權利       出席 / 投票，可二選一或複選（完全轉移）
--   直接生效   受託人不需同意即生效（不做 LINE 推播）
--   受託人批退 受託人可退回其所受委託 → 權利回歸委託人，受託人恢復可再受委託
--   已報到鎖定 任一方已報到 → 委託鎖死，不可設定 / 取消 / 批退
--   禁止轉委託 已受他人委託者，不得再把自己的權利委託出去
--   稽核       軟刪：status active|cancelled|rejected + ended_at + ended_by，保留紀錄
--
-- 報到端連動（vote_checkin）：
--   委託人（已把出席委託出去）到場 → 擋下，不得報到
--   委託人（只委託投票、保留出席）到場 → 可報到計入席次，但不發本人選票
--   受託人報到 → 本人 1 票 +（每筆持有且含投票權的委託再 +1 票）
-- ============================================================================

-- ── 軟刪 + 稽核欄位（向後相容；既有列 status 預設 active）──────────────────
ALTER TABLE tada_v_proxy ADD COLUMN IF NOT EXISTS status   TEXT NOT NULL DEFAULT 'active'
  CHECK (status IN ('active','cancelled','rejected'));
ALTER TABLE tada_v_proxy ADD COLUMN IF NOT EXISTS ended_at TIMESTAMPTZ;
ALTER TABLE tada_v_proxy ADD COLUMN IF NOT EXISTS ended_by TEXT;   -- 'principal' | 'delegate'
CREATE INDEX IF NOT EXISTS idx_v_proxy_active ON tada_v_proxy (election_id, status);

-- ============================================================================
-- proxy_submit：送出委託
--   加入：委託人資格閘門、雙方已報到鎖定、禁止轉委託、一對一（僅計 active）
-- ============================================================================
CREATE OR REPLACE FUNCTION proxy_submit(
  p_election UUID, p_principal_name TEXT, p_principal_no TEXT,
  p_delegate_name TEXT, p_delegate_no TEXT,
  p_attend BOOLEAN DEFAULT TRUE, p_vote BOOLEAN DEFAULT FALSE, p_user_id TEXT DEFAULT NULL
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_meeting TEXT; cnt INT;
  v_prin  tada_v_members%ROWTYPE;
  v_deleg tada_v_members%ROWTYPE;
BEGIN
  SELECT title INTO v_meeting FROM tada_v_election WHERE id = p_election;
  IF v_meeting IS NULL THEN RETURN json_build_object('ok',false,'error','election_not_found'); END IF;

  IF COALESCE(TRIM(p_principal_name),'')='' OR COALESCE(TRIM(p_delegate_name),'')='' THEN
    RETURN json_build_object('ok',false,'error','missing_name'); END IF;
  IF NOT COALESCE(p_attend,false) AND NOT COALESCE(p_vote,false) THEN
    RETURN json_build_object('ok',false,'error','no_scope'); END IF;

  -- 委託人資格閘門：必須在投票名冊
  SELECT * INTO v_prin FROM tada_v_members WHERE election_id = p_election
    AND (replace(name,' ','') = replace(p_principal_name,' ','')
         OR (COALESCE(p_principal_no,'')<>'' AND member_no = p_principal_no)) LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','principal_not_member'); END IF;

  -- 受託人資格閘門：必須在投票名冊
  SELECT * INTO v_deleg FROM tada_v_members WHERE election_id = p_election
    AND (replace(name,' ','') = replace(p_delegate_name,' ','')
         OR (COALESCE(p_delegate_no,'')<>'' AND member_no = p_delegate_no)) LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','delegate_not_member'); END IF;

  IF v_prin.member_no = v_deleg.member_no THEN
    RETURN json_build_object('ok',false,'error','self'); END IF;

  -- 已報到鎖定：任一方已報到即不可設定
  IF v_prin.is_checked_in OR v_deleg.is_checked_in THEN
    RETURN json_build_object('ok',false,'error','checked_in'); END IF;

  -- 委託人只能送出一筆有效委託
  SELECT count(*) INTO cnt FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (principal_name = v_prin.name OR (COALESCE(v_prin.member_no,'')<>'' AND principal_no = v_prin.member_no));
  IF cnt>0 THEN RETURN json_build_object('ok',false,'error','already_delegated'); END IF;

  -- 禁止轉委託：委託人本身若已受他人委託，不得再委託出去
  SELECT count(*) INTO cnt FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (delegate_name = v_prin.name OR (COALESCE(v_prin.member_no,'')<>'' AND delegate_no = v_prin.member_no));
  IF cnt>0 THEN RETURN json_build_object('ok',false,'error','is_delegate'); END IF;

  -- 受託人同時只能持有一筆有效委託
  SELECT count(*) INTO cnt FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (delegate_name = v_deleg.name OR (COALESCE(v_deleg.member_no,'')<>'' AND delegate_no = v_deleg.member_no));
  IF cnt>0 THEN RETURN json_build_object('ok',false,'error','delegate_taken'); END IF;

  INSERT INTO tada_v_proxy (election_id, principal_name, principal_no, delegate_name, delegate_no,
                            meeting, proxy_attend, proxy_vote, principal_user_id, status)
    VALUES (p_election, v_prin.name, v_prin.member_no, v_deleg.name, v_deleg.member_no,
            v_meeting, COALESCE(p_attend,false), COALESCE(p_vote,false), p_user_id, 'active');

  RETURN json_build_object('ok',true,'meeting',v_meeting,
    'delegate_name',v_deleg.name,'delegate_no',v_deleg.member_no,
    'proxy_attend',COALESCE(p_attend,false),'proxy_vote',COALESCE(p_vote,false));
END $$;
GRANT EXECUTE ON FUNCTION proxy_submit(UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,TEXT) TO anon;

-- ============================================================================
-- proxy_mine：查我的委託狀態（我送出的 + 我受託的），僅回傳 active
-- ============================================================================
CREATE OR REPLACE FUNCTION proxy_mine(p_election UUID, p_user_id TEXT, p_name TEXT, p_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  mine    tada_v_proxy%ROWTYPE;
  asdeleg tada_v_proxy%ROWTYPE;
  v_me    tada_v_members%ROWTYPE;
  v_prin_checked BOOLEAN := FALSE;
  v_deleg_checked BOOLEAN := FALSE;
BEGIN
  -- 我在名冊上的報到狀態
  SELECT * INTO v_me FROM tada_v_members WHERE election_id = p_election
    AND (line_user_id = p_user_id OR replace(name,' ','') = replace(p_name,' ','')
         OR (COALESCE(p_no,'')<>'' AND member_no = p_no)) LIMIT 1;

  SELECT * INTO mine FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (principal_user_id = p_user_id OR principal_name = p_name
         OR (COALESCE(p_no,'')<>'' AND principal_no = p_no)) LIMIT 1;

  SELECT * INTO asdeleg FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (delegate_name = p_name OR (COALESCE(p_no,'')<>'' AND delegate_no = p_no)) LIMIT 1;

  -- 委託鎖定判斷：任一方已報到
  IF mine.id IS NOT NULL THEN
    SELECT is_checked_in INTO v_deleg_checked FROM tada_v_members
      WHERE election_id = p_election AND member_no = mine.delegate_no LIMIT 1;
  END IF;
  IF asdeleg.id IS NOT NULL THEN
    SELECT is_checked_in INTO v_prin_checked FROM tada_v_members
      WHERE election_id = p_election AND member_no = asdeleg.principal_no LIMIT 1;
  END IF;

  RETURN json_build_object(
    'eligible',        v_me.id IS NOT NULL,   -- 是否在投票名冊（有委託資格）
    'delegated',       mine.id IS NOT NULL,
    'delegate_name',   mine.delegate_name, 'delegate_no', mine.delegate_no,
    'proxy_attend',    mine.proxy_attend,  'proxy_vote',  mine.proxy_vote,
    'mine_locked',     COALESCE(v_me.is_checked_in,false) OR COALESCE(v_deleg_checked,false),
    'is_delegate_for', asdeleg.principal_name,
    'delegate_attend', asdeleg.proxy_attend, 'delegate_vote', asdeleg.proxy_vote,
    'recv_locked',     COALESCE(v_me.is_checked_in,false) OR COALESCE(v_prin_checked,false),
    'me_checked_in',   COALESCE(v_me.is_checked_in,false)
  );
END $$;
GRANT EXECUTE ON FUNCTION proxy_mine(UUID,TEXT,TEXT,TEXT) TO anon;

-- ============================================================================
-- proxy_cancel：委託人取消自己送出的委託（軟刪；已報到即鎖定）
-- ============================================================================
CREATE OR REPLACE FUNCTION proxy_cancel(p_election UUID, p_user_id TEXT, p_name TEXT, p_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE p tada_v_proxy%ROWTYPE; v_prin_ci BOOLEAN; v_deleg_ci BOOLEAN;
BEGIN
  SELECT * INTO p FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (principal_user_id = p_user_id OR principal_name = p_name
         OR (COALESCE(p_no,'')<>'' AND principal_no = p_no)) LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_found'); END IF;

  SELECT is_checked_in INTO v_prin_ci  FROM tada_v_members WHERE election_id=p_election AND member_no=p.principal_no LIMIT 1;
  SELECT is_checked_in INTO v_deleg_ci FROM tada_v_members WHERE election_id=p_election AND member_no=p.delegate_no  LIMIT 1;
  IF COALESCE(v_prin_ci,false) OR COALESCE(v_deleg_ci,false) THEN
    RETURN json_build_object('ok',false,'error','checked_in'); END IF;

  UPDATE tada_v_proxy SET status='cancelled', ended_at=NOW(), ended_by='principal' WHERE id = p.id;
  RETURN json_build_object('ok',true);
END $$;
GRANT EXECUTE ON FUNCTION proxy_cancel(UUID,TEXT,TEXT,TEXT) TO anon;

-- ============================================================================
-- proxy_reject：受託人批退其所受委託（軟刪；權利回歸委託人）
-- ============================================================================
CREATE OR REPLACE FUNCTION proxy_reject(p_election UUID, p_user_id TEXT, p_name TEXT, p_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE p tada_v_proxy%ROWTYPE; v_prin_ci BOOLEAN; v_deleg_ci BOOLEAN;
BEGIN
  SELECT * INTO p FROM tada_v_proxy WHERE election_id = p_election AND status='active'
    AND (delegate_name = p_name OR (COALESCE(p_no,'')<>'' AND delegate_no = p_no)) LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_found'); END IF;

  SELECT is_checked_in INTO v_prin_ci  FROM tada_v_members WHERE election_id=p_election AND member_no=p.principal_no LIMIT 1;
  SELECT is_checked_in INTO v_deleg_ci FROM tada_v_members WHERE election_id=p_election AND member_no=p.delegate_no  LIMIT 1;
  IF COALESCE(v_prin_ci,false) OR COALESCE(v_deleg_ci,false) THEN
    RETURN json_build_object('ok',false,'error','checked_in'); END IF;

  UPDATE tada_v_proxy SET status='rejected', ended_at=NOW(), ended_by='delegate' WHERE id = p.id;
  RETURN json_build_object('ok',true,'principal_name',p.principal_name);
END $$;
GRANT EXECUTE ON FUNCTION proxy_reject(UUID,TEXT,TEXT,TEXT) TO anon;

-- ============================================================================
-- proxy_list：後台委託清單（現場查核 / CSV 匯出）
-- ============================================================================
CREATE OR REPLACE FUNCTION proxy_list(p_election UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v JSON;
BEGIN
  SELECT json_agg(row_to_json(t)) INTO v FROM (
    SELECT pr.id, pr.principal_name, pr.principal_no, pr.delegate_name, pr.delegate_no,
           pr.proxy_attend, pr.proxy_vote, pr.status, pr.created_at, pr.ended_at, pr.ended_by,
           COALESCE(mp.is_checked_in,false) AS principal_checked_in,
           COALESCE(md.is_checked_in,false) AS delegate_checked_in
      FROM tada_v_proxy pr
      LEFT JOIN tada_v_members mp ON mp.election_id=pr.election_id AND mp.member_no=pr.principal_no
      LEFT JOIN tada_v_members md ON md.election_id=pr.election_id AND md.member_no=pr.delegate_no
     WHERE pr.election_id = p_election
     ORDER BY pr.status, pr.created_at
  ) t;
  RETURN json_build_object('proxies', COALESCE(v,'[]'::json));
END $$;
GRANT EXECUTE ON FUNCTION proxy_list(UUID) TO anon;

-- ============================================================================
-- vote_checkin（覆寫）：報到領票 + 委託連動
--   回傳向後相容：仍含單一 'uuid'（第一張票）；新增 'uuids' 陣列與委託資訊。
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
      -- 出席已委託出去 → 本人不得報到
      RETURN json_build_object('ok',false,'error','delegated_away',
        'name',v_member.name,'delegate_name',v_self_prin.delegate_name); END IF;
    -- 只委託投票、保留出席 → 可報到，但本人不發選票
    v_self_ballot := 0;
  END IF;

  -- 我受託的委託：投票權張數、出席代表數
  SELECT COALESCE(count(*) FILTER (WHERE proxy_vote),0), COALESCE(count(*) FILTER (WHERE proxy_attend),0)
    INTO v_extra, v_attend_rep
    FROM tada_v_proxy WHERE election_id = p_election AND status='active'
     AND (delegate_name = v_member.name OR (COALESCE(v_member.member_no,'')<>'' AND delegate_no = v_member.member_no));

  UPDATE tada_v_members SET is_checked_in = TRUE, check_in_time = NOW(), vote_method = 'online' WHERE id = v_member.id;

  -- 發票：本人票 + 受託投票票
  v_total := v_self_ballot + v_extra;
  i := 0;
  WHILE i < v_total LOOP
    INSERT INTO tada_v_tokens (election_id, status) VALUES (p_election, 0) RETURNING uuid INTO v_uuid;
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
    'uuid', v_first,                       -- 向後相容：舊 kiosk 讀這個
    'uuids', to_json(v_uuids),             -- 新：全部選票
    'name', v_member.name, 'member_no', v_member.member_no,
    'member_type', v_member.member_type, 'rep', v_member.rep,
    'self_ballot', v_self_ballot,          -- 0＝本人票已委託出去
    'proxy_vote_count', v_extra,           -- 受託投票票數
    'attend_rep', v_attend_rep,            -- 代表出席人數
    'ballots', v_total,                    -- 本人實得選票總數
    'proxy_principals', COALESCE(v_principals,'[]'::json)
  );
END $$;
GRANT EXECUTE ON FUNCTION vote_checkin(UUID, TEXT) TO anon;

NOTIFY pgrst, 'reload schema';
