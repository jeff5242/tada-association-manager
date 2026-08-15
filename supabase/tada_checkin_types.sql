-- ============================================================================
-- 報到機擴充：身分別設定、貴賓報到、現場補登
-- 執行位置：Supabase SQL Editor → RUN（本檔可重複執行）
--
-- 規格見 docs/報到機擴充_身分選單與貴賓報到.md
--
-- ⚠️ 刻意不動 tada_v_members / tada_v_tokens / tada_v_votes 三張表。
--    那三張表之間「刻意不建立外鍵」是選舉匿名性的物理保證（見 tada_voting.sql），
--    本檔一律不往裡面加欄位、不建立任何指向它們的關聯。
--    統編查會員改走主名冊 tada_members → 取得 member_no → 再用既有路徑報到，
--    選舉表因此完全不必碰。
-- ============================================================================


-- ── 身分別（會員／貴賓／媒體／工作人員／眷屬…）────────────────────────────
-- 報到機的按鈕由這張表驅動：新增一列，取號機就多一顆按鈕，不必改程式。
CREATE TABLE IF NOT EXISTS tada_checkin_types (
  code           TEXT PRIMARY KEY,                    -- member / guest / media …
  label          TEXT NOT NULL,                       -- 按鈕上的字，如「我是會員」
  sort           INTEGER NOT NULL DEFAULT 0,
  -- 要查哪一份名冊。none = 不比對名冊，一律現場輸入姓名
  roster         TEXT NOT NULL DEFAULT 'guests'
                 CHECK (roster IN ('members', 'guests', 'none')),
  -- 報到後是否核發選票。只有會員有投票權，其餘身分一律 FALSE。
  -- 這個旗標是選務防線：貴賓拿到帶投票 token 的票會直接造成爭議。
  issues_ballot  BOOLEAN NOT NULL DEFAULT FALSE,
  -- 允許用哪些欄位查名冊，如 {member_no, tax_id} / {tax_id, name}
  match_fields   TEXT[]  NOT NULL DEFAULT ARRAY['name'],
  -- 查無資料時可否現場輸入姓名先完成報到
  allow_manual   BOOLEAN NOT NULL DEFAULT TRUE,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO tada_checkin_types (code, label, sort, roster, issues_ballot, match_fields, allow_manual)
VALUES
  ('member', '我是會員', 1, 'members', TRUE,  ARRAY['member_no','tax_id'], TRUE),
  ('guest',  '我是貴賓', 2, 'guests',  FALSE, ARRAY['tax_id','name'],      TRUE)
ON CONFLICT (code) DO NOTHING;   -- 已存在就不覆蓋現場調過的設定


-- ── 貴賓名冊補三個欄位 ────────────────────────────────────────────────────
-- 實查（2026-08-15）tada_guests 目前只有 id, name, org, train, meal, note,
-- status, sort —— **沒有任何報到欄位**，status 全部是 RSVP 的 'pending'，
-- 不是報到狀態。貴賓報到需要自己的欄位，不能沿用 status。
-- tax_id 供「輸入統編報到」使用；貴賓名冊原本也沒有統編。
ALTER TABLE tada_guests
  ADD COLUMN IF NOT EXISTS checked_in    BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS checked_in_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS tax_id        TEXT;

CREATE INDEX IF NOT EXISTS idx_guests_tax_id ON tada_guests (tax_id) WHERE tax_id IS NOT NULL;


-- ── 現場補登 ──────────────────────────────────────────────────────────────
-- 查無資料時不擋人：輸入姓名先完成報到，事後由秘書處決定怎麼處理。
-- 刻意獨立一張表，不寫進 tada_members / tada_guests：
-- 現場打錯字的姓名直接變成正式名冊，在選舉場合是災難。
CREATE TABLE IF NOT EXISTS tada_checkin_pending (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  type_code     TEXT NOT NULL REFERENCES tada_checkin_types(code),
  entered_name  TEXT NOT NULL,                        -- 現場輸入的姓名
  raw_input     TEXT,                                 -- 先前查詢時實際輸入的字串
  org           TEXT,
  note          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- 秘書處處理後填入：補進名冊／併到既有的人／標記無效
  resolved_at   TIMESTAMPTZ,
  resolution    TEXT CHECK (resolution IN ('added', 'merged', 'void'))
);
CREATE INDEX IF NOT EXISTS idx_checkin_pending_open
  ON tada_checkin_pending (created_at) WHERE resolved_at IS NULL;


-- ============================================================================
-- RPC：貴賓報到
-- 悲觀鎖住該貴賓列，防止手機與現場螢幕同時報到造成重複。
-- 不核發選票——貴賓沒有投票權。
-- ============================================================================
CREATE OR REPLACE FUNCTION guest_checkin(p_guest_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_guest tada_guests%ROWTYPE;
BEGIN
  SELECT * INTO v_guest FROM tada_guests WHERE id = p_guest_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'guest_not_found');
  END IF;

  -- 已報到不是錯誤，回傳原本的資料讓畫面顯示「您已完成報到」
  IF v_guest.checked_in THEN
    RETURN json_build_object('ok', false, 'error', 'already_checked_in',
                             'name', v_guest.name, 'org', v_guest.org,
                             'checked_in_at', v_guest.checked_in_at);
  END IF;

  UPDATE tada_guests
     SET checked_in = TRUE, checked_in_at = NOW()
   WHERE id = v_guest.id;

  RETURN json_build_object('ok', true, 'name', v_guest.name, 'org', v_guest.org);
END;
$$;


-- ============================================================================
-- RPC：報到進度（會員與貴賓一次回傳）
-- 取代只算會員的 vote_progress。分母讓秘書處看得到還有多少人沒到。
-- ============================================================================
CREATE OR REPLACE FUNCTION checkin_progress(p_election UUID)
RETURNS JSON LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT json_build_object(
    'members_checked', (SELECT COUNT(*) FROM tada_v_members
                         WHERE election_id = p_election AND is_checked_in),
    'members_total',   (SELECT COUNT(*) FROM tada_v_members
                         WHERE election_id = p_election),
    'guests_checked',  (SELECT COUNT(*) FROM tada_guests WHERE checked_in),
    'guests_total',    (SELECT COUNT(*) FROM tada_guests),
    'pending',         (SELECT COUNT(*) FROM tada_checkin_pending
                         WHERE resolved_at IS NULL)
  );
$$;


-- ============================================================================
-- RPC：現場補登
-- 只寫 tada_checkin_pending，不動任何名冊。
-- ============================================================================
CREATE OR REPLACE FUNCTION checkin_manual(
  p_type TEXT, p_name TEXT, p_raw TEXT DEFAULT NULL, p_org TEXT DEFAULT NULL
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_type tada_checkin_types%ROWTYPE;
  v_id   UUID;
BEGIN
  SELECT * INTO v_type FROM tada_checkin_types WHERE code = p_type AND is_active;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'type_not_found');
  END IF;
  IF NOT v_type.allow_manual THEN
    RETURN json_build_object('ok', false, 'error', 'manual_not_allowed');
  END IF;
  IF COALESCE(TRIM(p_name), '') = '' THEN
    RETURN json_build_object('ok', false, 'error', 'name_required');
  END IF;

  INSERT INTO tada_checkin_pending (type_code, entered_name, raw_input, org)
  VALUES (p_type, TRIM(p_name), p_raw, p_org)
  RETURNING id INTO v_id;

  RETURN json_build_object('ok', true, 'id', v_id, 'name', TRIM(p_name));
END;
$$;


-- ── 權限 ──────────────────────────────────────────────────────────────────
-- 報到機用 anon key，與既有的 vote_* 一致。
ALTER TABLE tada_checkin_types   ENABLE ROW LEVEL SECURITY;
ALTER TABLE tada_checkin_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_checkin_types_read ON tada_checkin_types;
CREATE POLICY p_checkin_types_read ON tada_checkin_types
  FOR SELECT TO anon USING (is_active);

GRANT SELECT  ON tada_checkin_types TO anon;
GRANT EXECUTE ON FUNCTION guest_checkin(UUID)                      TO anon;
GRANT EXECUTE ON FUNCTION checkin_progress(UUID)                   TO anon;
GRANT EXECUTE ON FUNCTION checkin_manual(TEXT, TEXT, TEXT, TEXT)   TO anon;

-- tada_checkin_pending 不開 anon 讀取：補登名單只有後臺看得到。
-- 寫入一律經過 checkin_manual（SECURITY DEFINER），不直接開 INSERT。


-- ============================================================================
-- RPC：以「統編 + 手機」驗證會員身分
--
-- 為什麼一定要兩個欄位：
--   統一編號是公開資訊（財政部營業登記資料可查），單憑統編就能領票等於
--   任何人都能冒領。手機號碼才是只有本人知道的那一項。
--
-- 為什麼不先用統編列出該公司的會員讓他選：
--   那會變成「輸入任一公司統編 → 得到該公司所有會員姓名」的名冊外洩管道。
--   改成兩個欄位一起送、只回傳唯一一筆，查不到就是查不到。
--
-- 團體會員：reps 是最多 3 位代表的 JSON 陣列，各自有 tel；
--           比對到第 N 位時回傳的會員編號為「會員編號-N」，與後臺的編號規則一致。
-- ============================================================================
CREATE OR REPLACE FUNCTION member_lookup(p_tax_id TEXT, p_mobile TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE
  v_tax    TEXT := regexp_replace(COALESCE(p_tax_id, ''), '\D', '', 'g');
  v_phone  TEXT := regexp_replace(COALESCE(p_mobile, ''), '\D', '', 'g');
  v_no     TEXT;
  v_name   TEXT;
BEGIN
  -- 資料庫裡手機存成 09XX-XXX-XXX，比對前兩邊都只留數字
  IF length(v_tax) <> 8 OR length(v_phone) < 9 THEN
    RETURN json_build_object('ok', false, 'error', 'input_incomplete');
  END IF;

  -- 個人會員：比對會員本人的電話欄位
  SELECT m.member_no, m.name INTO v_no, v_name
    FROM tada_members m
   WHERE regexp_replace(COALESCE(m.tax_id, ''), '\D', '', 'g') = v_tax
     AND v_phone IN (
           regexp_replace(COALESCE(m.mobile, ''),        '\D', '', 'g'),
           regexp_replace(COALESCE(m.phone_office, ''),  '\D', '', 'g'),
           regexp_replace(COALESCE(m.contact_phone, ''), '\D', '', 'g')
         )
   LIMIT 1;

  IF v_no IS NOT NULL THEN
    RETURN json_build_object('ok', true, 'member_no', v_no, 'name', v_name);
  END IF;

  -- 團體會員代表：比對 reps[N].tel
  SELECT m.member_no || '-' || r.idx, r.rep_name INTO v_no, v_name
    FROM tada_members m
    CROSS JOIN LATERAL (
      SELECT ordinality AS idx,
             elem->>'name' AS rep_name,
             elem->>'tel'  AS tel
        FROM jsonb_array_elements(COALESCE(m.reps, '[]'::jsonb))
             WITH ORDINALITY AS t(elem, ordinality)
    ) r
   WHERE regexp_replace(COALESCE(m.tax_id, ''), '\D', '', 'g') = v_tax
     AND regexp_replace(COALESCE(r.tel, ''), '\D', '', 'g') = v_phone
   LIMIT 1;

  IF v_no IS NOT NULL THEN
    RETURN json_build_object('ok', true, 'member_no', v_no, 'name', v_name);
  END IF;

  -- 統編對、手機錯，與統編本身不存在，回傳同一個錯誤：
  -- 分開回報等於送給對方一支「這個統編是不是會員」的查詢工具。
  RETURN json_build_object('ok', false, 'error', 'no_match');
END;
$$;

GRANT EXECUTE ON FUNCTION member_lookup(TEXT, TEXT) TO anon;

-- ⚠️ 這支 RPC 只有在「anon 不能直接讀 tada_members」時才有意義。
--    目前 supabase/tada_members.sql 裡的 RLS 是 for select using (true)，
--    而 anon key 就寫在公開的 assets/liff-common.js 裡——等於整份名冊
--    （姓名、手機、Email、統編、地址）任何人都拿得到，這支驗證形同虛設。
--    修正方式見 docs/報到機擴充_身分選單與貴賓報到.md 第十節。


-- ============================================================================
-- 報到機的三種查詢方式：會員編號 / 統一編號 / 手機號碼
--
-- 會員編號走既有路徑（會員證 QR 就是編號），這裡補另外兩種。
--
-- 統編為什麼還要多一道：
--   統一編號是公開資訊，只憑統編就能領票等於任何人都能冒領。團體會員又有
--   多位代表，所以流程是「統編 → 選代表（姓名遮蔽）→ 手機末 3 碼」。
--   姓名遮蔽讓本人認得出自己、旁人看不出是誰；末 3 碼則讓「隨便選一個」失效。
-- ============================================================================

/** 王小明 → 王○明；只留頭尾，本人認得、旁人猜不到 */
CREATE OR REPLACE FUNCTION tada_mask_name(p_name TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN COALESCE(p_name,'') = '' THEN ''
    WHEN char_length(p_name) <= 1 THEN p_name
    WHEN char_length(p_name) = 2 THEN left(p_name,1) || '○'
    ELSE left(p_name,1) || repeat('○', char_length(p_name)-2) || right(p_name,1)
  END;
$$;

-- 統編 → 可選的人（本人 + 各代表），姓名遮蔽、不回傳會員編號
CREATE OR REPLACE FUNCTION member_candidates_by_tax(p_tax_id TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE
  v_tax  TEXT := regexp_replace(COALESCE(p_tax_id,''), '\D', '', 'g');
  v_list JSON;
BEGIN
  IF length(v_tax) <> 8 THEN
    RETURN json_build_object('ok', false, 'error', 'bad_tax_id');
  END IF;

  SELECT COALESCE(json_agg(t ORDER BY t.idx), '[]'::json) INTO v_list
  FROM (
    -- 會員本人
    SELECT 0 AS idx, tada_mask_name(m.name) AS masked, m.company
      FROM tada_members m
     WHERE regexp_replace(COALESCE(m.tax_id,''), '\D','','g') = v_tax
       AND NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
    UNION ALL
    -- 團體代表
    SELECT r.ordinality::int AS idx, tada_mask_name(r.elem->>'name') AS masked, m.company
      FROM tada_members m
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.reps,'[]'::jsonb))
             WITH ORDINALITY AS r(elem, ordinality)
     WHERE regexp_replace(COALESCE(m.tax_id,''), '\D','','g') = v_tax
       AND NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
       AND COALESCE(r.elem->>'name','') <> ''
  ) t;

  IF json_array_length(v_list) = 0 THEN
    RETURN json_build_object('ok', false, 'error', 'no_match');
  END IF;

  RETURN json_build_object('ok', true, 'candidates', v_list);
END;
$$;

-- 統編 + 選到的序號 + 手機末 3 碼 → 換到真正的會員編號
CREATE OR REPLACE FUNCTION member_verify_by_tax(p_tax_id TEXT, p_idx INT, p_last3 TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE
  v_tax   TEXT := regexp_replace(COALESCE(p_tax_id,''), '\D','','g');
  v_last3 TEXT := right(regexp_replace(COALESCE(p_last3,''), '\D','','g'), 3);
  v_no    TEXT;
  v_name  TEXT;
BEGIN
  IF length(v_tax) <> 8 OR length(v_last3) <> 3 THEN
    RETURN json_build_object('ok', false, 'error', 'input_incomplete');
  END IF;

  IF p_idx = 0 THEN
    SELECT m.member_no, m.name INTO v_no, v_name
      FROM tada_members m
     WHERE regexp_replace(COALESCE(m.tax_id,''),'\D','','g') = v_tax
       AND v_last3 IN (
             right(regexp_replace(COALESCE(m.mobile,''),'\D','','g'), 3),
             right(regexp_replace(COALESCE(m.phone_office,''),'\D','','g'), 3),
             right(regexp_replace(COALESCE(m.contact_phone,''),'\D','','g'), 3))
     LIMIT 1;
  ELSE
    SELECT m.member_no || '-' || p_idx, r.elem->>'name' INTO v_no, v_name
      FROM tada_members m
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.reps,'[]'::jsonb))
             WITH ORDINALITY AS r(elem, ordinality)
     WHERE regexp_replace(COALESCE(m.tax_id,''),'\D','','g') = v_tax
       AND r.ordinality = p_idx
       AND right(regexp_replace(COALESCE(r.elem->>'tel',''),'\D','','g'), 3) = v_last3
     LIMIT 1;
  END IF;

  IF v_no IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'verify_failed');
  END IF;

  RETURN json_build_object('ok', true, 'member_no', v_no, 'name', v_name);
END;
$$;

-- 手機號碼 → 會員編號。手機不是公開資訊，本身就足以識別，不必再加一道。
CREATE OR REPLACE FUNCTION member_by_mobile(p_mobile TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE
  v_phone TEXT := regexp_replace(COALESCE(p_mobile,''), '\D','','g');
  v_no    TEXT;
  v_name  TEXT;
BEGIN
  IF length(v_phone) < 9 THEN
    RETURN json_build_object('ok', false, 'error', 'input_incomplete');
  END IF;

  SELECT m.member_no, m.name INTO v_no, v_name
    FROM tada_members m
   WHERE NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
     AND v_phone IN (
           regexp_replace(COALESCE(m.mobile,''),'\D','','g'),
           regexp_replace(COALESCE(m.phone_office,''),'\D','','g'),
           regexp_replace(COALESCE(m.contact_phone,''),'\D','','g'))
   LIMIT 1;

  IF v_no IS NULL THEN
    SELECT m.member_no || '-' || r.ordinality, r.elem->>'name' INTO v_no, v_name
      FROM tada_members m
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.reps,'[]'::jsonb))
             WITH ORDINALITY AS r(elem, ordinality)
     WHERE NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
       AND regexp_replace(COALESCE(r.elem->>'tel',''),'\D','','g') = v_phone
     LIMIT 1;
  END IF;

  IF v_no IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'no_match');
  END IF;

  RETURN json_build_object('ok', true, 'member_no', v_no, 'name', v_name);
END;
$$;

GRANT EXECUTE ON FUNCTION tada_mask_name(TEXT)                        TO anon;
GRANT EXECUTE ON FUNCTION member_candidates_by_tax(TEXT)              TO anon;
GRANT EXECUTE ON FUNCTION member_verify_by_tax(TEXT, INT, TEXT)       TO anon;
GRANT EXECUTE ON FUNCTION member_by_mobile(TEXT)                      TO anon;
