-- ════════════════════════════════════════════════════════════════════
-- 紙本選票掃描判讀
--
-- ⚠️ 匿名性：本表只記票號（列印流水號），不記投票人。
--    與 tada_v_members / tada_v_tokens 之間刻意不建立任何關聯。
--    票號的用途僅為「防止同一張票被重複計入」，不可用於回推身分。
-- ════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS tada_ballot_scans (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id   UUID NOT NULL,
  position      TEXT NOT NULL CHECK (position IN ('director','supervisor')),

  ballot_no     TEXT,                       -- 票面票號，如 20260904001；判讀不到則為 NULL
  image_path    TEXT,                       -- Storage 路徑

  read1         JSONB,                      -- 第一次判讀原始結果
  read2         JSONB,                      -- 第二次判讀原始結果
  agree         BOOLEAN,                    -- 兩次判讀是否完全一致

  marked_count  INTEGER,                    -- 圈選數（以 read1 為準，兩次一致時才有意義）
  marked_nos    INTEGER[],                  -- 被圈選的候選人編號
  image_quality TEXT,                       -- good / blurry / skewed / partial

  -- 程式端規則判定的結果（不是 AI 判的）
  verdict       TEXT CHECK (verdict IN ('valid','invalid_blank','invalid_over','manual')),

  review_status TEXT NOT NULL DEFAULT 'pending'
                CHECK (review_status IN ('auto','pending','confirmed','void')),
  reviewed_by   TEXT,
  reviewed_at   TIMESTAMPTZ,
  review_note   TEXT,

  counted       BOOLEAN NOT NULL DEFAULT FALSE,   -- 是否已寫入 tada_v_votes
  counted_at    TIMESTAMPTZ,

  is_test       BOOLEAN NOT NULL DEFAULT FALSE,   -- 彩排測試票，不計入正式票數
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- 同一場次、同一票號只能有一張正式票（防止重複掃描／重複計票）
CREATE UNIQUE INDEX IF NOT EXISTS uq_ballot_no_live
  ON tada_ballot_scans (election_id, ballot_no)
  WHERE ballot_no IS NOT NULL AND is_test = FALSE;

CREATE INDEX IF NOT EXISTS idx_ballot_scans_review
  ON tada_ballot_scans (election_id, review_status, is_test);

ALTER TABLE tada_ballot_scans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_ballot_scans_read ON tada_ballot_scans;
CREATE POLICY p_ballot_scans_read ON tada_ballot_scans FOR SELECT USING (true);

DROP POLICY IF EXISTS p_ballot_scans_write ON tada_ballot_scans;
CREATE POLICY p_ballot_scans_write ON tada_ballot_scans FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS p_ballot_scans_update ON tada_ballot_scans;
CREATE POLICY p_ballot_scans_update ON tada_ballot_scans FOR UPDATE USING (true) WITH CHECK (true);


-- ── 計票：把一張已確認有效的選票寫入 tada_v_votes ──────────────────────
-- 冪等：counted 已為 true 就直接返回，重複呼叫不會重複計票。
CREATE OR REPLACE FUNCTION tada_ballot_commit(p_scan_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_scan   tada_ballot_scans%ROWTYPE;
  v_no     INTEGER;
  v_cid    UUID;
  v_n      INTEGER := 0;
BEGIN
  -- 悲觀鎖，避免兩個人同時按「計入」造成重複票
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


-- ── 統計看板 ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION tada_ballot_stats(p_election_id UUID, p_test BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'total',        COUNT(*),
    'director',     COUNT(*) FILTER (WHERE position='director'),
    'supervisor',   COUNT(*) FILTER (WHERE position='supervisor'),
    'valid',        COUNT(*) FILTER (WHERE verdict='valid'),
    'invalid',      COUNT(*) FILTER (WHERE verdict IN ('invalid_blank','invalid_over')),
    'pending',      COUNT(*) FILTER (WHERE review_status='pending'),
    'counted',      COUNT(*) FILTER (WHERE counted),
    'disagree',     COUNT(*) FILTER (WHERE agree IS FALSE),
    'bad_image',    COUNT(*) FILTER (WHERE image_quality IS NOT NULL AND image_quality <> 'good')
  )
  FROM tada_ballot_scans
  WHERE election_id = p_election_id AND is_test = p_test;
$$;

GRANT EXECUTE ON FUNCTION tada_ballot_stats(UUID, BOOLEAN) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
