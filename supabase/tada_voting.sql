-- ============================================================================
-- TADA 理監事線上選舉／即時開票系統  (O2O 實體 QR 領票憑證版)
-- 執行位置：Supabase SQL Editor → RUN（本檔可重複執行）
--
-- ── 匿名核心（規格書核心原則二）──────────────────────────────────────────
--   Members / Tokens / Votes 三張表之間「刻意不建立任何外鍵」，
--   於資料庫物理層面把「報到會員身分」與「核發選票 / 投票內容」徹底斷開。
--   → 即使 anon key 外流、即使能讀完三張表，也無法把「誰」對應到「投給誰」。
--
--   tada_v_election    選舉場次設定（席次、圈選上限、狀態）
--   tada_v_members     報到領票檔（可對應身分＝敏感；與 tokens/votes 無關聯）
--   tada_v_tokens      選票憑證檔（印在紙本 QR 的 uuid；無會員關聯欄位）
--   tada_v_votes       得票紀錄檔（只存職位＋候選人；無 token / 無會員關聯）
--   tada_v_candidates  候選人（非匿名關鍵表，可公開）
--
-- ── 防重複計票（規格書核心原則三）────────────────────────────────────────
--   vote_cast 以 Transaction + SELECT … FOR UPDATE（悲觀鎖）鎖定 token 列，
--   狀態非 0 即拒絕，杜絕 Race Condition 造成的重複核銷 / 重複計票。
--
-- ⚠️ 本檔僅含「綱要與邏輯」，不含任何會員 / 候選人姓名（PII）。
--    種子資料（含姓名）請執行未進版控的 tada_voting_seed.sql。
-- ============================================================================

-- ── 場次設定 ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tada_v_election (
  id                   UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title                TEXT NOT NULL,
  status               TEXT NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft','checkin','open','closed')),
  -- 理事
  director_seats       INTEGER NOT NULL DEFAULT 11,   -- 應選席次
  director_reserve     INTEGER NOT NULL DEFAULT 3,    -- 候補名額
  director_pick        INTEGER NOT NULL DEFAULT 11,   -- 每票圈選上限
  -- 監事
  supervisor_seats     INTEGER NOT NULL DEFAULT 3,
  supervisor_reserve   INTEGER NOT NULL DEFAULT 1,
  supervisor_pick      INTEGER NOT NULL DEFAULT 3,
  -- 常務理事（預設為「第二階段理事互選」，不在會員票上）
  executive_seats      INTEGER NOT NULL DEFAULT 3,
  executive_pick       INTEGER NOT NULL DEFAULT 3,
  -- 會員票包含哪些職位（常務預設不含；若要會員直接圈常務，加入 'executive' 即可）
  member_ballot        TEXT[] NOT NULL DEFAULT ARRAY['director','supervisor'],
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ── 報到領票檔（敏感；與 tokens/votes 無任何關聯欄位）─────────────────────
CREATE TABLE IF NOT EXISTS tada_v_members (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id   UUID NOT NULL,
  member_no     TEXT NOT NULL,
  name          TEXT NOT NULL,
  member_type   TEXT NOT NULL DEFAULT 'personal'
                CHECK (member_type IN ('personal','group')),
  rep           TEXT,                                 -- 團體會員代表（顯示用）
  is_checked_in BOOLEAN NOT NULL DEFAULT FALSE,
  check_in_time TIMESTAMPTZ,
  UNIQUE (election_id, member_no)
);
CREATE INDEX IF NOT EXISTS idx_v_members_election ON tada_v_members (election_id, is_checked_in);

-- ── 選票憑證檔（無會員關聯：這正是匿名的關鍵）────────────────────────────
CREATE TABLE IF NOT EXISTS tada_v_tokens (
  uuid         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id  UUID NOT NULL,
  status       INTEGER NOT NULL DEFAULT 0,            -- 0 未使用, 1 已核銷
  generated_at TIMESTAMPTZ DEFAULT NOW(),
  used_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_v_tokens_election ON tada_v_tokens (election_id, status);

-- ── 得票紀錄檔（無 token、無會員關聯：個別票不可回溯）────────────────────
CREATE TABLE IF NOT EXISTS tada_v_votes (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  election_id  UUID NOT NULL,
  position     TEXT NOT NULL CHECK (position IN ('director','supervisor','executive')),
  candidate_id UUID NOT NULL,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_v_votes_tally ON tada_v_votes (election_id, candidate_id);

-- ── 候選人（可公開，非匿名關鍵表）────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tada_v_candidates (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id  UUID NOT NULL,
  position     TEXT NOT NULL CHECK (position IN ('director','supervisor','executive')),
  no           INTEGER,                               -- 選票編號
  name         TEXT NOT NULL,
  company      TEXT,
  sort         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_v_candidates_election ON tada_v_candidates (election_id, position, sort);

-- ============================================================================
-- RLS：投票者頁面一律走 SECURITY DEFINER RPC，不直接讀寫敏感表。
--   election / candidates → anon 可讀（公開選務資訊），後臺 anon 可寫（管理）
--   members               → anon 可讀寫（後臺名冊管理；與 tokens/votes 無關聯，不影響匿名）
--   tokens                → anon 完全無權（uuid 即選票祕密，禁止列舉）→ 僅 RPC 存取
--   votes                 → anon 只可讀彙總用（個別列不含身分）；寫入僅 RPC
-- ============================================================================
ALTER TABLE tada_v_election   ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_v_members    ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_v_tokens     ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_v_votes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_v_candidates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS v_election_rw   ON tada_v_election;
DROP POLICY IF EXISTS v_members_rw    ON tada_v_members;
DROP POLICY IF EXISTS v_candidates_rw ON tada_v_candidates;
DROP POLICY IF EXISTS v_votes_read    ON tada_v_votes;

CREATE POLICY v_election_rw   ON tada_v_election   FOR ALL    USING (true) WITH CHECK (true);
CREATE POLICY v_members_rw    ON tada_v_members    FOR ALL    USING (true) WITH CHECK (true);
CREATE POLICY v_candidates_rw ON tada_v_candidates FOR ALL    USING (true) WITH CHECK (true);
CREATE POLICY v_votes_read    ON tada_v_votes      FOR SELECT USING (true);
-- tada_v_tokens：不建立任何 policy → anon 無法讀寫（RLS 預設拒絕），僅下方 RPC 可存取。

-- ============================================================================
-- RPC 1：報到領票  vote_checkin(場次, 會員編號) → 產生一張全新選票 uuid
--   悲觀鎖住該會員列，防止同一會員被重複報到 / 重複領票。
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_checkin(p_election UUID, p_member_no TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_status TEXT;
  v_member tada_v_members%ROWTYPE;
  v_uuid   UUID;
BEGIN
  SELECT status INTO v_status FROM tada_v_election WHERE id = p_election;
  IF v_status IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'election_not_found');
  END IF;
  IF v_status NOT IN ('checkin','open') THEN
    RETURN json_build_object('ok', false, 'error', 'not_open');
  END IF;

  -- 悲觀鎖：鎖定該會員列
  SELECT * INTO v_member FROM tada_v_members
   WHERE election_id = p_election AND member_no = p_member_no
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'member_not_found');
  END IF;
  IF v_member.is_checked_in THEN
    RETURN json_build_object('ok', false, 'error', 'already_checked_in',
                             'name', v_member.name);
  END IF;

  UPDATE tada_v_members
     SET is_checked_in = TRUE, check_in_time = NOW()
   WHERE id = v_member.id;

  -- 產生一張全新的匿名選票憑證（不記錄是誰的）
  INSERT INTO tada_v_tokens (election_id, status) VALUES (p_election, 0)
  RETURNING uuid INTO v_uuid;

  RETURN json_build_object(
    'ok', true,
    'uuid', v_uuid,
    'name', v_member.name,
    'member_no', v_member.member_no,
    'member_type', v_member.member_type,
    'rep', v_member.rep
  );
END $$;

-- ============================================================================
-- RPC 2：取得選票 + 候選人  vote_ballot(uuid)
--   掃 QR 進投票頁時呼叫：驗證 token 合法且未使用，回傳選舉設定與候選人。
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_ballot(p_uuid UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tok   tada_v_tokens%ROWTYPE;
  v_e     tada_v_election%ROWTYPE;
  v_cands JSON;
BEGIN
  SELECT * INTO v_tok FROM tada_v_tokens WHERE uuid = p_uuid;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'invalid'); END IF;
  IF v_tok.status <> 0 THEN RETURN json_build_object('ok', false, 'error', 'used'); END IF;

  SELECT * INTO v_e FROM tada_v_election WHERE id = v_tok.election_id;
  IF v_e.status <> 'open' THEN RETURN json_build_object('ok', false, 'error', 'not_open'); END IF;

  SELECT json_agg(row_to_json(t)) INTO v_cands FROM (
    SELECT id, position, no, name, company, sort
      FROM tada_v_candidates
     WHERE election_id = v_tok.election_id
       AND position = ANY (v_e.member_ballot)
     ORDER BY position, sort, no
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

-- ============================================================================
-- RPC 3：提交選票（核心防弊）  vote_cast(uuid, 理事[], 監事[], 常務[])
--   Transaction + FOR UPDATE 鎖定 token；狀態非 0 即回 already_voted。
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_cast(
  p_uuid        UUID,
  p_directors   UUID[] DEFAULT '{}',
  p_supervisors UUID[] DEFAULT '{}',
  p_executives  UUID[] DEFAULT '{}'
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

-- ============================================================================
-- RPC 4：投票進度  vote_progress(場次)
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_progress(p_election UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_total INT; v_checked INT; v_issued INT; v_cast INT;
BEGIN
  SELECT count(*) INTO v_total   FROM tada_v_members WHERE election_id = p_election;
  SELECT count(*) INTO v_checked FROM tada_v_members WHERE election_id = p_election AND is_checked_in;
  SELECT count(*) INTO v_issued  FROM tada_v_tokens  WHERE election_id = p_election;
  SELECT count(*) INTO v_cast    FROM tada_v_tokens  WHERE election_id = p_election AND status = 1;
  RETURN json_build_object(
    'total_members', v_total, 'checked_in', v_checked,
    'tokens_issued', v_issued, 'ballots_cast', v_cast
  );
END $$;

-- ============================================================================
-- RPC 5：開票結果  vote_results(場次) — 僅回傳彙總，維持匿名
-- ============================================================================
CREATE OR REPLACE FUNCTION vote_results(p_election UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v JSON;
BEGIN
  SELECT json_agg(row_to_json(t)) INTO v FROM (
    SELECT c.id, c.position, c.no, c.name, c.company, c.sort,
           count(vt.id) AS votes
      FROM tada_v_candidates c
      LEFT JOIN tada_v_votes vt
             ON vt.candidate_id = c.id AND vt.election_id = c.election_id
     WHERE c.election_id = p_election
     GROUP BY c.id, c.position, c.no, c.name, c.company, c.sort
     ORDER BY c.position, count(vt.id) DESC, c.sort
  ) t;
  RETURN json_build_object('candidates', COALESCE(v, '[]'::json));
END $$;

-- ── 授權：投票者頁面以 anon 呼叫 RPC ─────────────────────────────────────
GRANT EXECUTE ON FUNCTION vote_checkin(UUID, TEXT)                TO anon;
GRANT EXECUTE ON FUNCTION vote_ballot(UUID)                      TO anon;
GRANT EXECUTE ON FUNCTION vote_cast(UUID, UUID[], UUID[], UUID[]) TO anon;
GRANT EXECUTE ON FUNCTION vote_progress(UUID)                    TO anon;
GRANT EXECUTE ON FUNCTION vote_results(UUID)                     TO anon;

-- ── 即時開票：讓 Dashboard 可訂閱 votes 變更（個別列不含身分）───────────
--   若下方報錯 publication 不存在，於 Supabase Dashboard → Database → Replication 開啟即可。
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='tada_v_votes'
    ) THEN
      EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE tada_v_votes';
    END IF;
  END IF;
END $$;

-- ============================================================================
-- 願任書（當選理監事事後線上簽署同意就任）
-- ============================================================================
CREATE TABLE IF NOT EXISTS tada_v_consent (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id  UUID NOT NULL,
  position     TEXT NOT NULL CHECK (position IN ('director','supervisor','executive')),
  name         TEXT NOT NULL,
  member_no    TEXT,
  company      TEXT,
  agreed       BOOLEAN NOT NULL DEFAULT TRUE,
  note         TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE tada_v_consent ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS v_consent_ins ON tada_v_consent;
DROP POLICY IF EXISTS v_consent_sel ON tada_v_consent;
CREATE POLICY v_consent_ins ON tada_v_consent FOR INSERT WITH CHECK (true);
CREATE POLICY v_consent_sel ON tada_v_consent FOR SELECT USING (true);
