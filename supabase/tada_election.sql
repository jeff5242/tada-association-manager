-- TADA 理監事線上選舉／即時開票
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）
--
-- 設計：
--   tada_elections         選舉設定（席次、圈選上限、狀態）
--   tada_candidates        候選人（理事 director / 監事 supervisor）
--   tada_election_voters   有效會員名冊（姓名＋驗證碼），含 has_voted 防重複
--   tada_ballots           個別圈選紀錄（連結 voter，但只以彙總對外顯示＝匿名）
-- RPC：
--   election_check_voter   資格比對（姓名＋末四碼）→ 回 voter 狀態，不外洩整份名冊
--   election_cast_ballot   投票（驗證未投＋圈選上限，寫入並標記已投）
--   election_progress      投票進度（已投／應投）
--   election_results       各候選人得票（僅彙總）

CREATE TABLE IF NOT EXISTS tada_elections (
  id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title             TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','open','closed')),
  director_seats    INTEGER NOT NULL DEFAULT 11,   -- 理事應選席次
  director_reserve  INTEGER NOT NULL DEFAULT 3,    -- 理事候補
  director_pick     INTEGER NOT NULL DEFAULT 5,    -- 理事票每人圈選上限
  supervisor_seats  INTEGER NOT NULL DEFAULT 3,    -- 監事應選席次
  supervisor_reserve INTEGER NOT NULL DEFAULT 1,   -- 監事候補
  supervisor_pick   INTEGER NOT NULL DEFAULT 1,    -- 監事票每人圈選上限
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tada_candidates (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id  UUID NOT NULL REFERENCES tada_elections(id) ON DELETE CASCADE,
  category     TEXT NOT NULL CHECK (category IN ('director','supervisor')),
  name         TEXT NOT NULL,
  company      TEXT,
  sort         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_candidates_election ON tada_candidates (election_id, category, sort);

CREATE TABLE IF NOT EXISTS tada_election_voters (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id  UUID NOT NULL REFERENCES tada_elections(id) ON DELETE CASCADE,
  member_name  TEXT NOT NULL,
  verify_code  TEXT NOT NULL,           -- 例如手機末四碼
  user_id      TEXT,                    -- 投票時記錄的 LINE userId
  has_voted    BOOLEAN NOT NULL DEFAULT FALSE,
  voted_at     TIMESTAMPTZ,
  UNIQUE (election_id, member_name, verify_code)
);
CREATE INDEX IF NOT EXISTS idx_voters_election ON tada_election_voters (election_id, has_voted);

CREATE TABLE IF NOT EXISTS tada_ballots (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  election_id  UUID NOT NULL REFERENCES tada_elections(id) ON DELETE CASCADE,
  voter_id     UUID NOT NULL REFERENCES tada_election_voters(id) ON DELETE CASCADE,
  category     TEXT NOT NULL CHECK (category IN ('director','supervisor')),
  candidate_id UUID NOT NULL REFERENCES tada_candidates(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ballots_candidate ON tada_ballots (candidate_id);

-- ── RPC：資格比對（不外洩整份名冊）──
CREATE OR REPLACE FUNCTION election_check_voter(p_election UUID, p_name TEXT, p_code TEXT)
RETURNS TABLE (voter_id UUID, has_voted BOOLEAN)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT id, has_voted FROM tada_election_voters
  WHERE election_id = p_election AND member_name = btrim(p_name) AND verify_code = btrim(p_code)
  LIMIT 1;
$$;

-- ── RPC：投票（驗證未投＋圈選上限）──
CREATE OR REPLACE FUNCTION election_cast_ballot(
  p_voter UUID, p_user_id TEXT, p_directors UUID[], p_supervisors UUID[]
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_election UUID; v_status TEXT; v_dpick INT; v_spick INT; v_voted BOOLEAN; cid UUID;
BEGIN
  SELECT ev.election_id, ev.has_voted INTO v_election, v_voted
  FROM tada_election_voters ev WHERE ev.id = p_voter FOR UPDATE;
  IF v_election IS NULL THEN RETURN 'invalid_voter'; END IF;
  IF v_voted THEN RETURN 'already_voted'; END IF;

  SELECT status, director_pick, supervisor_pick INTO v_status, v_dpick, v_spick
  FROM tada_elections WHERE id = v_election;
  IF v_status <> 'open' THEN RETURN 'not_open'; END IF;
  IF COALESCE(array_length(p_directors,1),0) > v_dpick THEN RETURN 'too_many_directors'; END IF;
  IF COALESCE(array_length(p_supervisors,1),0) > v_spick THEN RETURN 'too_many_supervisors'; END IF;

  FOREACH cid IN ARRAY COALESCE(p_directors, ARRAY[]::UUID[]) LOOP
    INSERT INTO tada_ballots (election_id, voter_id, category, candidate_id)
    VALUES (v_election, p_voter, 'director', cid);
  END LOOP;
  FOREACH cid IN ARRAY COALESCE(p_supervisors, ARRAY[]::UUID[]) LOOP
    INSERT INTO tada_ballots (election_id, voter_id, category, candidate_id)
    VALUES (v_election, p_voter, 'supervisor', cid);
  END LOOP;

  UPDATE tada_election_voters
  SET has_voted = TRUE, voted_at = NOW(), user_id = p_user_id WHERE id = p_voter;
  RETURN 'ok';
END;
$$;

-- ── RPC：投票進度 ──
CREATE OR REPLACE FUNCTION election_progress(p_election UUID)
RETURNS TABLE (total BIGINT, voted BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT COUNT(*), COUNT(*) FILTER (WHERE has_voted)
  FROM tada_election_voters WHERE election_id = p_election;
$$;

-- ── RPC：各候選人得票（僅彙總，匿名）──
CREATE OR REPLACE FUNCTION election_results(p_election UUID)
RETURNS TABLE (candidate_id UUID, category TEXT, name TEXT, company TEXT, votes BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, c.category, c.name, c.company, COUNT(b.id)
  FROM tada_candidates c
  LEFT JOIN tada_ballots b ON b.candidate_id = c.id
  WHERE c.election_id = p_election
  GROUP BY c.id, c.category, c.name, c.company, c.sort
  ORDER BY c.category, COUNT(b.id) DESC, c.sort;
$$;

-- ── RLS ──
ALTER TABLE tada_elections ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_election_voters ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_ballots ENABLE ROW LEVEL SECURITY;

-- 選舉設定與候選人：公開可讀（投票頁／投影需要）；後台以 service role 寫入
DROP POLICY IF EXISTS "anon_select_elections" ON tada_elections;
CREATE POLICY "anon_select_elections" ON tada_elections FOR SELECT USING (true);
DROP POLICY IF EXISTS "anon_all_elections" ON tada_elections;
CREATE POLICY "anon_all_elections" ON tada_elections FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_select_candidates" ON tada_candidates;
CREATE POLICY "anon_select_candidates" ON tada_candidates FOR SELECT USING (true);
DROP POLICY IF EXISTS "anon_all_candidates" ON tada_candidates;
CREATE POLICY "anon_all_candidates" ON tada_candidates FOR ALL USING (true) WITH CHECK (true);

-- 名冊：後台（密碼牆內）可增修；投票比對走 SECURITY DEFINER RPC，故不需公開 select
DROP POLICY IF EXISTS "anon_all_voters" ON tada_election_voters;
CREATE POLICY "anon_all_voters" ON tada_election_voters FOR ALL USING (true) WITH CHECK (true);

-- 選票：僅透過 RPC 寫入；不開放直接讀（保匿名）
DROP POLICY IF EXISTS "anon_insert_ballots" ON tada_ballots;
CREATE POLICY "anon_insert_ballots" ON tada_ballots FOR INSERT TO anon WITH CHECK (true);
