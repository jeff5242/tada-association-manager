-- ════════════════════════════════════════════════════════════════════
-- 貴賓自助報到 v2：先查名冊帶入資料，再補齊聯絡方式
--
-- 現況問題：/guest/walkin/ 是純新增表單，已在名冊上的貴賓從這裡報到會
-- 產生第二筆資料，而且拿不到桌次，只能請他去問接待。
--
-- 本檔提供：
--   tada_detitle()          去職稱正規化（「謝董事長明達」→「謝明達」）
--   guest_lookup()          以姓名跨 貴賓名冊／出席回報／會員名冊 找人並合併欄位
--   guest_walkin_checkin()  補登聯絡資料後報到，回傳桌次
--   guest_add()             擴充：職稱、手機、Email
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE tada_guests ADD COLUMN IF NOT EXISTS mobile TEXT;
ALTER TABLE tada_guests ADD COLUMN IF NOT EXISTS email  TEXT;
ALTER TABLE tada_guests ADD COLUMN IF NOT EXISTS title  TEXT;   -- 職稱（原本併在 name 裡）


-- ── 去職稱正規化 ─────────────────────────────────────────────────────
-- 貴賓名冊常把職稱寫進姓名（「徐前院長源泰」），出席回報則是「徐源泰」，
-- 直接比對會漏掉。長職稱要排在短的前面，否則「副院長」會先被「院長」吃掉。
CREATE OR REPLACE FUNCTION tada_detitle(t TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(
           regexp_replace(coalesce(t,''), '\s+', '', 'g'),
           '(副理事長|理事長|副董事長|董事長|副總經理|總經理|執行長|副校長|校長|副司長|司長|'
           '副署長|署長|副院長|前院長|院長|副所長|分所長|前所長|所長|副處長|處長|副主任|主任|'
           '總幹事|副總|總監|教授|研究員|經理|技正|技監|組長|鄉長|社長|顧問|博士|董事|老師|'
           '高專|秘書|助理)', '', 'g')
$$;


-- ── 姓名查詢：貴賓名冊為主，出席回報與會員名冊補欄位 ────────────────
CREATE OR REPLACE FUNCTION guest_lookup(p_name TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  q  TEXT := tada_detitle(p_name);
  v  JSON;
  im BOOLEAN;
BEGIN
  IF length(q) < 2 THEN
    RETURN json_build_object('ok', false, 'error', 'need_name');
  END IF;

  -- 會員走會員證報到，不從貴賓自助頁進來
  SELECT EXISTS (
    SELECT 1 FROM tada_members m
     WHERE m.status <> '退會會員'
       AND (tada_detitle(m.name) = q
            OR EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(m.reps,'[]'::jsonb)) rp
                        WHERE tada_detitle(rp->>'name') = q))
  ) INTO im;

  SELECT json_agg(row_to_json(t)) INTO v FROM (
    SELECT g.id                                              AS guest_id,
           g.name,
           g.checked_in,
           g.category,
           g.unit,
           coalesce(nullif(btrim(g.seat),''), r.table_no)     AS seat,
           coalesce(nullif(btrim(g.title),''), r.title, m.title)                 AS title,
           coalesce(nullif(btrim(g.org),''),  r.org,   m.company)                AS org,
           coalesce(nullif(btrim(g.mobile),''), r.mobile, m.mobile, m.contact_phone) AS mobile,
           coalesce(nullif(btrim(g.email),''), m.email, m.contact_email)         AS email,
           g.plate
      FROM tada_guests g
      LEFT JOIN LATERAL (
        SELECT r2.title, r2.org, r2.mobile, r2.table_no
          FROM tada_rsvp r2
         WHERE r2.attending AND NOT r2.hidden
           AND tada_detitle(r2.display_name) = tada_detitle(g.name)
         LIMIT 1
      ) r ON TRUE
      LEFT JOIN LATERAL (
        SELECT m2.title, m2.company, m2.mobile, m2.contact_phone, m2.email, m2.contact_email
          FROM tada_members m2
         WHERE tada_detitle(m2.name) = tada_detitle(g.name)
         LIMIT 1
      ) m ON TRUE
     WHERE tada_detitle(g.name) LIKE '%' || q || '%'
     ORDER BY (tada_detitle(g.name) = q) DESC, g.name
     LIMIT 12
  ) t;

  RETURN json_build_object('ok', true,
                           'is_member', im,
                           'matches', coalesce(v, '[]'::json));
END $$;

GRANT EXECUTE ON FUNCTION tada_detitle(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION guest_lookup(TEXT)  TO anon, authenticated;


-- ── 名冊中已有：補登聯絡資料後報到，回傳桌次 ────────────────────────
CREATE OR REPLACE FUNCTION guest_walkin_checkin(
  p_guest_id UUID,
  p_title    TEXT DEFAULT NULL,
  p_org      TEXT DEFAULT NULL,
  p_mobile   TEXT DEFAULT NULL,
  p_email    TEXT DEFAULT NULL,
  p_plate    TEXT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v tada_guests%ROWTYPE; v_was BOOLEAN;
BEGIN
  SELECT * INTO v FROM tada_guests WHERE id = p_guest_id FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'guest_not_found'); END IF;
  v_was := v.checked_in;

  -- 只補空欄，不覆蓋名冊既有內容（現場填錯不會蓋掉正確資料）
  UPDATE tada_guests SET
      title      = coalesce(nullif(btrim(title),''),  nullif(btrim(p_title),'')),
      org        = coalesce(nullif(btrim(org),''),    nullif(btrim(p_org),'')),
      mobile     = coalesce(nullif(btrim(mobile),''), nullif(btrim(p_mobile),'')),
      email      = coalesce(nullif(btrim(email),''),  nullif(btrim(p_email),'')),
      plate      = coalesce(nullif(btrim(p_plate),''), plate),   -- 車號以現場填的為準
      checked_in = TRUE,
      checked_in_at = coalesce(checked_in_at, now())
   WHERE id = v.id
   RETURNING * INTO v;

  RETURN json_build_object('ok', true, 'already', v_was,
    'id', v.id, 'name', v.name, 'org', v.org, 'title', v.title,
    'seat', v.seat, 'meal', v.meal, 'train', v.train, 'note', v.note, 'plate', v.plate);
END $$;

GRANT EXECUTE ON FUNCTION guest_walkin_checkin(UUID,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon, authenticated;


-- ── 名冊中沒有：現場新增（擴充職稱／手機／Email）────────────────────
DROP FUNCTION IF EXISTS guest_add(text,text,text,text,text);
DROP FUNCTION IF EXISTS guest_add(text,text,text,text);
DROP FUNCTION IF EXISTS guest_add(text,text,text);
CREATE OR REPLACE FUNCTION guest_add(
  p_name     TEXT,
  p_org      TEXT DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_seat     TEXT DEFAULT NULL,
  p_plate    TEXT DEFAULT NULL,
  p_title    TEXT DEFAULT NULL,
  p_mobile   TEXT DEFAULT NULL,
  p_email    TEXT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_id UUID;
        v_name TEXT := btrim(coalesce(p_name,''));
        v_org  TEXT := btrim(coalesce(p_org,''));
        v_cat  TEXT := coalesce(nullif(btrim(coalesce(p_category,'')),''),'農業合作單位');
BEGIN
  IF v_name = '' THEN RETURN json_build_object('ok',false,'error','need_name'); END IF;
  INSERT INTO tada_guests (name, org, unit, category, seat, plate, title, mobile, email,
                           status, sort, checked_in, checked_in_at)
  VALUES (v_name, nullif(v_org,''), nullif(v_org,''), v_cat,
          nullif(btrim(coalesce(p_seat,'')),''),
          nullif(btrim(coalesce(p_plate,'')),''),
          nullif(btrim(coalesce(p_title,'')),''),
          nullif(btrim(coalesce(p_mobile,'')),''),
          nullif(btrim(coalesce(p_email,'')),''),
          'onsite', 9999, TRUE, now())
  RETURNING id INTO v_id;
  RETURN json_build_object('ok',true,'id',v_id,'name',v_name,'org',nullif(v_org,''),
    'seat',nullif(btrim(coalesce(p_seat,'')),''),
    'plate',nullif(btrim(coalesce(p_plate,'')),''),'category',v_cat);
END $fn$;

GRANT EXECUTE ON FUNCTION guest_add(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
