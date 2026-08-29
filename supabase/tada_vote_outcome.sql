-- ════════════════════════════════════════════════════════════════════
-- 當選判定 vote_outcome(場次)
--
-- 【為什麼要有這支】
-- 目前「誰當選／誰候補」只存在於 election-live/index.html 的 renderChart()
-- 上色邏輯（前 n 名塗金色）。那是畫面呈現，不是權威名單，導致兩個問題：
--   1. 得票 0 也會因為排進前 n 名而被塗成「當選」
--   2. 同票數以號次（c.sort / a.no）自動決勝，未依人民團體選舉慣例抽籤
-- 本函式把判定移到資料庫，成為單一權威來源；開票畫面、願任書、公告、
-- 會議紀錄都引用同一份結果。
--
-- 【判定規則】
--   得票 0                          → not_elected（席次從缺，不遞補）
--   同票組完整落在應選席次內        → elected
--   同票組完整落在候補名額內        → reserve
--   同票組跨越席次／候補分界線      → tiebreak（待抽籤，程式不自動決定）
--   名次超過 應選+候補              → not_elected
-- ════════════════════════════════════════════════════════════════════

-- ── 補齊席次設定欄位（重複執行安全）──────────────────────────────────
ALTER TABLE tada_v_election
  ADD COLUMN IF NOT EXISTS executive_reserve       INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tada_v_election
  ADD COLUMN IF NOT EXISTS exec_supervisor_seats   INTEGER NOT NULL DEFAULT 1;
ALTER TABLE tada_v_election
  ADD COLUMN IF NOT EXISTS exec_supervisor_reserve INTEGER NOT NULL DEFAULT 0;


CREATE OR REPLACE FUNCTION vote_outcome(p_election UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v JSON;
BEGIN
  SELECT json_agg(row_to_json(t)) INTO v FROM (
    WITH seat AS (
      SELECT 'director'::TEXT AS position,
             e.director_seats        AS n_seat,
             e.director_reserve      AS n_reserve        FROM tada_v_election e WHERE e.id = p_election
      UNION ALL
      SELECT 'supervisor',      e.supervisor_seats,      e.supervisor_reserve      FROM tada_v_election e WHERE e.id = p_election
      UNION ALL
      SELECT 'executive',       e.executive_seats,       e.executive_reserve       FROM tada_v_election e WHERE e.id = p_election
      UNION ALL
      SELECT 'exec_supervisor', e.exec_supervisor_seats, e.exec_supervisor_reserve FROM tada_v_election e WHERE e.id = p_election
    ),
    tally AS (
      SELECT c.id, c.position, c.no, c.name, c.company, c.sort,
             COUNT(vt.id)::INT AS votes
        FROM tada_v_candidates c
        LEFT JOIN tada_v_votes vt
               ON vt.candidate_id = c.id AND vt.election_id = c.election_id
       WHERE c.election_id = p_election
       GROUP BY c.id, c.position, c.no, c.name, c.company, c.sort
    ),
    ranked AS (
      -- rank：同票同名次（競賽名次，1,1,3,3…）
      -- tie_size：同一票數共有幾人
      SELECT t.*,
             RANK()  OVER (PARTITION BY t.position ORDER BY t.votes DESC) AS rank,
             COUNT(*) OVER (PARTITION BY t.position, t.votes)             AS tie_size
        FROM tally t
    )
    SELECT r.id, r.position, r.no, r.name, r.company, r.sort,
           r.votes, r.rank, r.tie_size,
           s.n_seat, s.n_reserve,
           CASE
             -- 得票下限：0 票不予當選，寧可席次從缺
             WHEN r.votes <= 0
               THEN 'not_elected'
             -- 整個同票組都在應選席次內 → 全部當選
             WHEN r.rank + r.tie_size - 1 <= s.n_seat
               THEN 'elected'
             -- 名次已超過 應選+候補 → 落選
             WHEN r.rank > s.n_seat + s.n_reserve
               THEN 'not_elected'
             -- 整個同票組都在候補名額內 → 全部候補
             WHEN r.rank > s.n_seat
              AND r.rank + r.tie_size - 1 <= s.n_seat + s.n_reserve
               THEN 'reserve'
             -- 其餘：同票組跨越分界線 → 待抽籤，程式不自動決定
             ELSE 'tiebreak'
           END AS status
      FROM ranked r
      JOIN seat s ON s.position = r.position
     ORDER BY r.position, r.rank, r.sort
  ) t;

  RETURN json_build_object('candidates', COALESCE(v, '[]'::json));
END $$;

GRANT EXECUTE ON FUNCTION vote_outcome(UUID) TO anon, authenticated;


-- ── 票號未判讀時不得自動計入（補 uq_ballot_no_live 的 NULL 缺口）──────
-- uq_ballot_no_live 的條件是 WHERE ballot_no IS NOT NULL，
-- 條碼判讀失敗（ballot_no = NULL）時唯一性不生效，同一張票可被掃兩次
-- 並各自計票。此時要求必須人工複核（review_status='confirmed'）才可計入。
--
-- ⚠️ 這段會覆蓋 tada_ballot_scans.sql 裡的 tada_ballot_commit，
--    套用後請把同樣的檢查補回該檔，避免下次重跑舊檔又蓋掉。
CREATE OR REPLACE FUNCTION tada_ballot_commit(p_scan_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_scan tada_ballot_scans%ROWTYPE;
  v_no   INTEGER;
  v_cid  UUID;
  v_n    INTEGER := 0;
BEGIN
  SELECT * INTO v_scan FROM tada_ballot_scans WHERE id = p_scan_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', '找不到該筆掃描紀錄');
  END IF;

  IF v_scan.counted THEN
    RETURN jsonb_build_object('ok', true, 'already', true, 'votes', 0);
  END IF;
  IF v_scan.is_test THEN
    RETURN jsonb_build_object('ok', false, 'error', '測試票不可計入');
  END IF;
  IF v_scan.verdict IS DISTINCT FROM 'valid' THEN
    RETURN jsonb_build_object('ok', false, 'error', '非有效票，不可計入');
  END IF;
  IF v_scan.review_status NOT IN ('auto','confirmed') THEN
    RETURN jsonb_build_object('ok', false, 'error', '尚未複核完成');
  END IF;

  -- ★ 新增：票號未判讀 → 唯一索引失效 → 強制人工複核
  IF (v_scan.ballot_no IS NULL OR btrim(v_scan.ballot_no) = '')
     AND v_scan.review_status <> 'confirmed' THEN
    RETURN jsonb_build_object('ok', false,
      'error', '票號未判讀，無法自動防止重複計票；請人工複核並補登票號後再計入');
  END IF;

  FOREACH v_no IN ARRAY COALESCE(v_scan.marked_nos, ARRAY[]::INTEGER[])
  LOOP
    SELECT id INTO v_cid
      FROM tada_v_candidates
     WHERE election_id = v_scan.election_id
       AND position    = v_scan.position
       AND no          = v_no
     LIMIT 1;

    IF v_cid IS NULL THEN
      RAISE EXCEPTION '找不到候選人：% 號（%）', v_no, v_scan.position;
    END IF;

    INSERT INTO tada_v_votes (election_id, position, candidate_id)
    VALUES (v_scan.election_id, v_scan.position, v_cid);
    v_n := v_n + 1;
  END LOOP;

  UPDATE tada_ballot_scans
     SET counted = TRUE, counted_at = NOW()
   WHERE id = p_scan_id;

  RETURN jsonb_build_object('ok', true, 'votes', v_n);
END;
$$;

GRANT EXECUTE ON FUNCTION tada_ballot_commit(UUID) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
