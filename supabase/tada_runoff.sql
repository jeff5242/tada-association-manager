-- ============================================================================
-- TADA 第二階段互選（常務理事／理事長／常務監事）計票模組
-- 執行位置：Supabase SQL Editor → RUN（本檔可重複執行）
--
-- 【法源】本會章程
--   第十八條 理事會設置常務理事 3 人，由「理事」互選之；
--            並由「理事」就常務理事中選舉一人為理事長。
--   第二十條 監事會置常務監事 1 人，由「監事」互選之。
--
-- 【三輪的選舉人 / 候選人 對照】
--   輪次              選舉人              候選人              應選
--   executive         當選理事（11）      當選理事（11）      3   常務理事
--   chairman          當選理事（11）      常務理事（3）       1   理事長
--   exec_supervisor   當選監事（3）       當選監事（3）       1   常務監事
--   → 注意 chairman 的選舉人是「全體理事」而非只有常務理事（章程明文）。
--
-- 【與第一階段的關係】
--   候選人一律由 vote_outcome() 的 elected 名單種入，不手key，避免名單與開票結果不一致。
--   得票仍寫進 tada_v_votes（source='runoff'），所以 election-live／vote_outcome
--   等既有查詢不必改寫即可看到常務結果。
--
-- 【匿名性】
--   互選是記名或無記名由會議決定；本模組採「唱票輸入」，
--   tada_v_runoff_ballots 只存「這張票圈了誰」，不存投票人，維持與第一階段相同的匿名層級。
--   ballot_id 僅供「撤銷上一張」使用，不連到任何人。
-- ============================================================================


-- ── 1. 開放 position：補上 exec_supervisor（常務監事）與 chairman（理事長）──
ALTER TABLE tada_v_candidates DROP CONSTRAINT IF EXISTS tada_v_candidates_position_check;
ALTER TABLE tada_v_candidates ADD CONSTRAINT tada_v_candidates_position_check
  CHECK (position IN ('director','supervisor','executive','exec_supervisor','chairman'));

ALTER TABLE tada_v_votes DROP CONSTRAINT IF EXISTS tada_v_votes_position_check;
ALTER TABLE tada_v_votes ADD CONSTRAINT tada_v_votes_position_check
  CHECK (position IN ('director','supervisor','executive','exec_supervisor','chairman'));


-- ── 2. 理事長席次設定（vote_outcome 的 seat 表需要）──────────────────────
ALTER TABLE tada_v_election ADD COLUMN IF NOT EXISTS chairman_seats   INTEGER NOT NULL DEFAULT 1;
ALTER TABLE tada_v_election ADD COLUMN IF NOT EXISTS chairman_reserve INTEGER NOT NULL DEFAULT 0;


-- ── 3. 互選輪次 ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tada_v_runoff (
  election_id UUID    NOT NULL,
  position    TEXT    NOT NULL CHECK (position IN ('executive','chairman','exec_supervisor')),
  status      TEXT    NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','open','closed')),
  electors    INTEGER NOT NULL DEFAULT 0,   -- 應到選舉人數（當選理事／監事人數）
  present     INTEGER NOT NULL DEFAULT 0,   -- 實到人數＝應開票數（主席宣布後輸入）
  note        TEXT,
  opened_at   TIMESTAMPTZ,
  closed_at   TIMESTAMPTZ,
  PRIMARY KEY (election_id, position)
);

-- ── 4. 逐張唱票紀錄（支援撤銷上一張、事後核對）──────────────────────────
CREATE TABLE IF NOT EXISTS tada_v_runoff_ballots (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id UUID    NOT NULL,
  position    TEXT    NOT NULL,
  seq         INTEGER NOT NULL,                       -- 第幾張（1 起算）
  picks       UUID[]  NOT NULL DEFAULT '{}',          -- 圈選的候選人
  invalid     BOOLEAN NOT NULL DEFAULT FALSE,         -- 廢票（超額圈選／未圈／污損）
  reason      TEXT,                                   -- 廢票原因
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (election_id, position, seq)
);
CREATE INDEX IF NOT EXISTS idx_runoff_ballots ON tada_v_runoff_ballots (election_id, position, seq DESC);

-- 得票列回指唱票單（只為撤銷用；不連到投票人）
ALTER TABLE tada_v_votes ADD COLUMN IF NOT EXISTS ballot_id UUID;

ALTER TABLE tada_v_runoff         ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_v_runoff_ballots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS v_runoff_sel   ON tada_v_runoff;
DROP POLICY IF EXISTS v_rballots_sel ON tada_v_runoff_ballots;
CREATE POLICY v_runoff_sel   ON tada_v_runoff         FOR SELECT USING (true);
CREATE POLICY v_rballots_sel ON tada_v_runoff_ballots FOR SELECT USING (true);
-- 寫入一律透過下方 SECURITY DEFINER RPC


-- ============================================================================
-- 共用：某職位的應選席次 / 圈選上限 / 上一階段來源職位
-- ============================================================================
CREATE OR REPLACE FUNCTION runoff_spec(p_election UUID, p_position TEXT)
RETURNS TABLE (seats INT, pick INT, src TEXT, electorate TEXT, label TEXT)
LANGUAGE sql STABLE AS $$
  SELECT
    CASE p_position WHEN 'executive'       THEN e.executive_seats
                    WHEN 'chairman'        THEN e.chairman_seats
                    WHEN 'exec_supervisor' THEN e.exec_supervisor_seats END,
    -- 圈選上限＝應選席次（連記法）
    CASE p_position WHEN 'executive'       THEN e.executive_seats
                    WHEN 'chairman'        THEN e.chairman_seats
                    WHEN 'exec_supervisor' THEN e.exec_supervisor_seats END,
    -- 候選人來源：常務理事←理事、理事長←常務理事、常務監事←監事
    CASE p_position WHEN 'executive'       THEN 'director'
                    WHEN 'chairman'        THEN 'executive'
                    WHEN 'exec_supervisor' THEN 'supervisor' END,
    -- 選舉人來源：常務理事／理事長皆由「理事」選；常務監事由「監事」選
    CASE p_position WHEN 'executive'       THEN 'director'
                    WHEN 'chairman'        THEN 'director'
                    WHEN 'exec_supervisor' THEN 'supervisor' END,
    CASE p_position WHEN 'executive'       THEN '常務理事互選'
                    WHEN 'chairman'        THEN '理事長選舉'
                    WHEN 'exec_supervisor' THEN '常務監事互選' END
  FROM tada_v_election e WHERE e.id = p_election;
$$;


-- ============================================================================
-- RPC：建立／重建輪次  runoff_setup(場次, 職位)
--   從 vote_outcome 的 elected 名單種入候選人；已有票時拒絕重建。
-- ============================================================================
CREATE OR REPLACE FUNCTION runoff_setup(p_election UUID, p_position TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  sp RECORD; v_cast INT; v_n INT := 0; v_electors INT;
BEGIN
  SELECT * INTO sp FROM runoff_spec(p_election, p_position);
  IF sp.seats IS NULL THEN RETURN json_build_object('ok', false, 'error', 'bad_position'); END IF;

  SELECT count(*) INTO v_cast FROM tada_v_runoff_ballots
   WHERE election_id = p_election AND position = p_position;
  IF v_cast > 0 THEN
    RETURN json_build_object('ok', false, 'error', 'already_counted', 'ballots', v_cast);
  END IF;

  -- 候選人＝來源職位的當選人（依 vote_outcome 權威判定）
  -- 重建前先清乾淨：舊候選人與任何殘留得票（例如測試時寫進去、未經唱票單的票），
  -- 否則舊票會掛在被刪掉的候選人上，或污染新一輪的票數。
  DELETE FROM tada_v_votes      WHERE election_id = p_election AND position = p_position;
  DELETE FROM tada_v_candidates WHERE election_id = p_election AND position = p_position;

  WITH src AS (
    SELECT (c->>'name') AS name, (c->>'company') AS company,
           (c->>'votes')::int AS votes, (c->>'sort')::int AS sort
      FROM json_array_elements((vote_outcome(p_election))->'candidates') c
     WHERE c->>'position' = sp.src AND c->>'status' = 'elected'
  ), ins AS (
    INSERT INTO tada_v_candidates (election_id, position, no, name, company, sort)
    SELECT p_election, p_position,
           row_number() OVER (ORDER BY votes DESC, sort),
           name, company,
           row_number() OVER (ORDER BY votes DESC, sort)
      FROM src
    RETURNING 1
  )
  SELECT count(*) INTO v_n FROM ins;

  IF v_n = 0 THEN
    RETURN json_build_object('ok', false, 'error', 'no_elected_source', 'source', sp.src);
  END IF;

  -- 選舉人數＝選舉人來源職位的當選人數
  SELECT count(*) INTO v_electors
    FROM json_array_elements((vote_outcome(p_election))->'candidates') c
   WHERE c->>'position' = sp.electorate AND c->>'status' = 'elected';

  INSERT INTO tada_v_runoff (election_id, position, status, electors, present)
    VALUES (p_election, p_position, 'draft', v_electors, v_electors)
  ON CONFLICT (election_id, position)
    DO UPDATE SET status = 'draft', electors = v_electors, present = v_electors,
                  opened_at = NULL, closed_at = NULL;

  RETURN json_build_object('ok', true, 'candidates', v_n, 'electors', v_electors,
                           'seats', sp.seats, 'label', sp.label);
END $$;


-- ============================================================================
-- RPC：開始／結束計票  runoff_open / runoff_close
-- ============================================================================
CREATE OR REPLACE FUNCTION runoff_open(p_election UUID, p_position TEXT, p_present INT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE tada_v_runoff
     SET status = 'open', present = GREATEST(COALESCE(p_present, present), 0), opened_at = NOW(), closed_at = NULL
   WHERE election_id = p_election AND position = p_position;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'round_not_found'); END IF;
  RETURN json_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION runoff_close(p_election UUID, p_position TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE tada_v_runoff SET status = 'closed', closed_at = NOW()
   WHERE election_id = p_election AND position = p_position;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'round_not_found'); END IF;
  RETURN json_build_object('ok', true);
END $$;


-- ============================================================================
-- RPC：唱票輸入一張  runoff_cast(場次, 職位, 圈選[], 是否廢票, 廢票原因)
--   悲觀鎖住輪次列，序號連號不跳號；超額圈選一律拒絕（由計票人改登廢票）。
-- ============================================================================
CREATE OR REPLACE FUNCTION runoff_cast(
  p_election UUID, p_position TEXT,
  p_picks UUID[] DEFAULT '{}', p_invalid BOOLEAN DEFAULT FALSE, p_reason TEXT DEFAULT NULL
)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  r tada_v_runoff%ROWTYPE; sp RECORD; d UUID[]; cid UUID; v_seq INT; v_bid UUID;
BEGIN
  SELECT * INTO r FROM tada_v_runoff
   WHERE election_id = p_election AND position = p_position FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'round_not_found'); END IF;
  IF r.status <> 'open' THEN RETURN json_build_object('ok', false, 'error', 'not_open'); END IF;

  SELECT * INTO sp FROM runoff_spec(p_election, p_position);

  SELECT COALESCE(array_agg(DISTINCT e), '{}') INTO d FROM unnest(COALESCE(p_picks, '{}')) AS e;

  IF NOT p_invalid THEN
    IF COALESCE(array_length(d, 1), 0) = 0 THEN
      RETURN json_build_object('ok', false, 'error', 'empty_pick');
    END IF;
    IF array_length(d, 1) > sp.pick THEN
      RETURN json_build_object('ok', false, 'error', 'too_many', 'limit', sp.pick);
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(d) e WHERE NOT EXISTS (
                 SELECT 1 FROM tada_v_candidates c
                  WHERE c.id = e AND c.election_id = p_election AND c.position = p_position)) THEN
      RETURN json_build_object('ok', false, 'error', 'invalid_candidate');
    END IF;
  ELSE
    d := '{}';
  END IF;

  SELECT COALESCE(MAX(seq), 0) + 1 INTO v_seq FROM tada_v_runoff_ballots
   WHERE election_id = p_election AND position = p_position;

  INSERT INTO tada_v_runoff_ballots (election_id, position, seq, picks, invalid, reason)
    VALUES (p_election, p_position, v_seq, d, p_invalid, NULLIF(p_reason, ''))
  RETURNING id INTO v_bid;

  FOREACH cid IN ARRAY d LOOP
    INSERT INTO tada_v_votes (election_id, position, candidate_id, source, ballot_id)
      VALUES (p_election, p_position, cid, 'runoff', v_bid);
  END LOOP;

  RETURN json_build_object('ok', true, 'seq', v_seq, 'ballot_id', v_bid);
END $$;


-- ============================================================================
-- RPC：撤銷最後一張  runoff_undo(場次, 職位)
-- ============================================================================
CREATE OR REPLACE FUNCTION runoff_undo(p_election UUID, p_position TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE b tada_v_runoff_ballots%ROWTYPE;
BEGIN
  PERFORM 1 FROM tada_v_runoff
   WHERE election_id = p_election AND position = p_position FOR UPDATE;

  SELECT * INTO b FROM tada_v_runoff_ballots
   WHERE election_id = p_election AND position = p_position
   ORDER BY seq DESC LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'nothing_to_undo'); END IF;

  DELETE FROM tada_v_votes          WHERE ballot_id = b.id;
  DELETE FROM tada_v_runoff_ballots WHERE id = b.id;
  RETURN json_build_object('ok', true, 'undone_seq', b.seq);
END $$;


-- ============================================================================
-- RPC：清空本輪重來  runoff_reset(場次, 職位)
-- ============================================================================
CREATE OR REPLACE FUNCTION runoff_reset(p_election UUID, p_position TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_n INT;
BEGIN
  DELETE FROM tada_v_votes
   WHERE election_id = p_election AND position = p_position AND source = 'runoff';
  WITH del AS (
    DELETE FROM tada_v_runoff_ballots
     WHERE election_id = p_election AND position = p_position RETURNING 1
  ) SELECT count(*) INTO v_n FROM del;
  UPDATE tada_v_runoff SET status = 'draft', opened_at = NULL, closed_at = NULL
   WHERE election_id = p_election AND position = p_position;
  RETURN json_build_object('ok', true, 'deleted', v_n);
END $$;


-- ============================================================================
-- RPC：本輪即時狀態  runoff_state(場次, 職位)
--   回傳輪次設定、候選人得票、已開票數、廢票數，以及與 vote_outcome 同規則的
--   當選判定（0 票不當選、同票跨界線＝待抽籤）。
-- ============================================================================
CREATE OR REPLACE FUNCTION runoff_state(p_election UUID, p_position TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  sp RECORD; r tada_v_runoff%ROWTYPE; v_cands JSON; v_counted INT; v_invalid INT;
BEGIN
  SELECT * INTO sp FROM runoff_spec(p_election, p_position);
  IF sp.seats IS NULL THEN RETURN json_build_object('ok', false, 'error', 'bad_position'); END IF;
  SELECT * INTO r FROM tada_v_runoff WHERE election_id = p_election AND position = p_position;

  SELECT count(*), COALESCE(count(*) FILTER (WHERE invalid), 0)
    INTO v_counted, v_invalid
    FROM tada_v_runoff_ballots WHERE election_id = p_election AND position = p_position;

  SELECT json_agg(row_to_json(t)) INTO v_cands FROM (
    WITH tally AS (
      SELECT c.id, c.no, c.name, c.company, c.sort,
             COUNT(vt.id)::INT AS votes
        FROM tada_v_candidates c
        LEFT JOIN tada_v_votes vt
               ON vt.candidate_id = c.id AND vt.election_id = c.election_id
              AND vt.position = c.position
       WHERE c.election_id = p_election AND c.position = p_position
       GROUP BY c.id, c.no, c.name, c.company, c.sort
    ), ranked AS (
      SELECT t.*,
             RANK()   OVER (ORDER BY t.votes DESC)      AS rank,
             COUNT(*) OVER (PARTITION BY t.votes)       AS tie_size
        FROM tally t
    )
    SELECT id, no, name, company, sort, votes, rank, tie_size,
           CASE
             WHEN votes <= 0                          THEN 'not_elected'
             WHEN rank + tie_size - 1 <= sp.seats     THEN 'elected'
             WHEN rank > sp.seats                     THEN 'not_elected'
             ELSE 'tiebreak'
           END AS status
      FROM ranked
     ORDER BY rank, sort
  ) t;

  RETURN json_build_object(
    'ok', true,
    'position', p_position, 'label', sp.label,
    'seats', sp.seats, 'pick', sp.pick,
    'source', sp.src, 'electorate', sp.electorate,
    'round', CASE WHEN r.election_id IS NULL THEN NULL ELSE json_build_object(
      'status', r.status, 'electors', r.electors, 'present', r.present,
      'opened_at', r.opened_at, 'closed_at', r.closed_at) END,
    'counted', v_counted, 'invalid', v_invalid,
    'candidates', COALESCE(v_cands, '[]'::json)
  );
END $$;


-- ============================================================================
-- vote_outcome：補上 chairman 的席次列，讓理事長也能用同一支權威判定
--   （其餘邏輯與 tada_vote_outcome.sql 完全相同）
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_outcome(p_election UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v JSON;
BEGIN
  SELECT json_agg(row_to_json(t)) INTO v FROM (
    WITH seat AS (
      SELECT 'director'::TEXT AS position, e.director_seats   AS n_seat, e.director_reserve   AS n_reserve FROM tada_v_election e WHERE e.id = p_election
      UNION ALL SELECT 'supervisor',       e.supervisor_seats,      e.supervisor_reserve      FROM tada_v_election e WHERE e.id = p_election
      UNION ALL SELECT 'executive',        e.executive_seats,       e.executive_reserve       FROM tada_v_election e WHERE e.id = p_election
      UNION ALL SELECT 'exec_supervisor',  e.exec_supervisor_seats, e.exec_supervisor_reserve FROM tada_v_election e WHERE e.id = p_election
      UNION ALL SELECT 'chairman',         e.chairman_seats,        e.chairman_reserve        FROM tada_v_election e WHERE e.id = p_election
    ),
    tally AS (
      SELECT c.id, c.position, c.no, c.name, c.company, c.sort, COUNT(vt.id)::INT AS votes
        FROM tada_v_candidates c
        LEFT JOIN tada_v_votes vt
               ON vt.candidate_id = c.id AND vt.election_id = c.election_id
              AND vt.position = c.position
       WHERE c.election_id = p_election
       GROUP BY c.id, c.position, c.no, c.name, c.company, c.sort
    ),
    ranked AS (
      SELECT t.*,
             RANK()   OVER (PARTITION BY t.position ORDER BY t.votes DESC) AS rank,
             COUNT(*) OVER (PARTITION BY t.position, t.votes)              AS tie_size
        FROM tally t
    )
    SELECT r.id, r.position, r.no, r.name, r.company, r.sort,
           r.votes, r.rank, r.tie_size, s.n_seat, s.n_reserve,
           CASE
             WHEN r.votes <= 0                                     THEN 'not_elected'
             WHEN r.rank + r.tie_size - 1 <= s.n_seat              THEN 'elected'
             WHEN r.rank > s.n_seat + s.n_reserve                  THEN 'not_elected'
             WHEN r.rank > s.n_seat
              AND r.rank + r.tie_size - 1 <= s.n_seat + s.n_reserve THEN 'reserve'
             ELSE 'tiebreak'
           END AS status
      FROM ranked r
      JOIN seat s ON s.position = r.position
     ORDER BY r.position, r.rank, r.sort
  ) t;
  RETURN json_build_object('candidates', COALESCE(v, '[]'::json));
END $$;


GRANT EXECUTE ON FUNCTION runoff_spec(UUID, TEXT)                         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION runoff_setup(UUID, TEXT)                        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION runoff_open(UUID, TEXT, INT)                    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION runoff_close(UUID, TEXT)                        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION runoff_cast(UUID, TEXT, UUID[], BOOLEAN, TEXT)  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION runoff_undo(UUID, TEXT)                         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION runoff_reset(UUID, TEXT)                        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION runoff_state(UUID, TEXT)                        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION vote_outcome(UUID)                              TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
