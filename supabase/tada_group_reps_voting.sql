-- ============================================================================
-- 團體會員：每位代表各一票
--   規則：團體會員的「所有代表人」各自為一位投票人（各一票、各自綁 LINE、各自報到）。
--   做法：
--     1) 於第六屆投票名冊 tada_v_members 將團體展開為「每位代表一列」
--        member_no = 母編號-N（-1/-2/-3），name/rep = 代表姓名，company = 公司全銜。
--     2) 報到查詢 RPC（手機／統編末3碼）對「有代表的團體」只列代表、隱藏「本人」，
--        避免母編號另外再投一票（重複計票）。
--     3) LINE 綁定 roster_bind / roster_bound 改為「代表感知」：輸入姓名對到某位代表時，
--        綁到該代表的投票名冊列（每位代表可各自綁定電子會員證）。
--   註：tada_v_members / tokens 刻意無 FK（匿名投票），本檔僅動資料與 SECURITY DEFINER 函式。
-- 目標場次：第六屆 66666666-6666-4666-8666-666666666666
-- ============================================================================

-- ── 1. 展開團體代表為投票列（僅第六屆；idempotent）────────────────────────
DO $$
DECLARE el uuid := '66666666-6666-4666-8666-666666666666';
BEGIN
  -- 插入每位代表一列（尚未存在者才插）
  INSERT INTO tada_v_members (election_id, member_no, name, member_type, rep, company, tax_id, is_checked_in)
  SELECT el,
         m.member_no || '-' || r.ord,
         r.elem->>'name',
         'group',
         r.elem->>'name',
         COALESCE(NULLIF(m.company,''), m.name),
         m.tax_id,
         FALSE
    FROM tada_members m
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.reps,'[]'::jsonb))
           WITH ORDINALITY AS r(elem, ord)
   WHERE m.member_type = 'group'
     AND jsonb_array_length(COALESCE(m.reps,'[]'::jsonb)) >= 1
     AND COALESCE(r.elem->>'name','') <> ''
     -- 僅針對原本就在第六屆名冊中的團體（有投票資格者）
     AND EXISTS (SELECT 1 FROM tada_v_members v0
                  WHERE v0.election_id = el AND v0.member_no = m.member_no)
     -- 尚未展開者才插入
     AND NOT EXISTS (SELECT 1 FROM tada_v_members vx
                      WHERE vx.election_id = el AND vx.member_no = m.member_no || '-' || r.ord);

  -- 刪除已展開團體的「母列」（母號無 -N；避免母號另計一票）
  DELETE FROM tada_v_members v
   WHERE v.election_id = el
     AND v.member_type = 'group'
     AND v.member_no !~ '-'
     AND EXISTS (SELECT 1 FROM tada_v_members vc
                  WHERE vc.election_id = el AND vc.member_no LIKE v.member_no || '-%');
END $$;

-- ── 2. 報到查詢 RPC：有代表的團體隱藏「本人」，只解析到代表 ────────────────

-- 手機查詢：本人比對排除團體（團體只透過代表 tel 解析為 母號-N）
CREATE OR REPLACE FUNCTION public.member_by_mobile(p_mobile text)
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_phone TEXT := regexp_replace(COALESCE(p_mobile,''), '\D','','g');
  v_no TEXT; v_name TEXT;
BEGIN
  IF length(v_phone) < 9 THEN RETURN json_build_object('ok',false,'error','input_incomplete'); END IF;

  -- 本人（個人會員；團體不以公司電話報到）
  SELECT m.member_no, m.name INTO v_no, v_name
    FROM tada_members m
   WHERE m.member_type <> 'group'
     AND NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
     AND v_phone IN (regexp_replace(COALESCE(m.mobile,''),'\D','','g'),
                     regexp_replace(COALESCE(m.phone_office,''),'\D','','g'),
                     regexp_replace(COALESCE(m.contact_phone,''),'\D','','g'))
   LIMIT 1;

  -- 團體代表
  IF v_no IS NULL THEN
    SELECT m.member_no || '-' || r.ordinality, r.elem->>'name' INTO v_no, v_name
      FROM tada_members m
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.reps,'[]'::jsonb))
             WITH ORDINALITY AS r(elem, ordinality)
     WHERE NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
       AND regexp_replace(COALESCE(r.elem->>'tel',''),'\D','','g') = v_phone
     LIMIT 1;
  END IF;

  IF v_no IS NULL THEN RETURN json_build_object('ok',false,'error','no_match'); END IF;
  RETURN json_build_object('ok',true,'member_no',v_no,'name',v_name);
END; $function$;

-- 統編候選：團體只列代表（不列本人 idx 0）；個人列本人
CREATE OR REPLACE FUNCTION public.member_candidates_by_tax(p_tax_id text)
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tax TEXT := regexp_replace(COALESCE(p_tax_id,''), '\D','','g');
  v_list JSON;
BEGIN
  IF length(v_tax) <> 8 THEN RETURN json_build_object('ok',false,'error','bad_tax_id'); END IF;

  SELECT COALESCE(json_agg(t ORDER BY t.idx), '[]'::json) INTO v_list
  FROM (
    -- 本人（個人會員；團體不列本人）
    SELECT 0 AS idx, tada_mask_name(m.name) AS masked, m.company
      FROM tada_members m
     WHERE regexp_replace(COALESCE(m.tax_id,''),'\D','','g') = v_tax
       AND m.member_type <> 'group'
       AND NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
    UNION ALL
    -- 團體代表
    SELECT r.ordinality::int AS idx, tada_mask_name(r.elem->>'name') AS masked, m.company
      FROM tada_members m
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.reps,'[]'::jsonb))
             WITH ORDINALITY AS r(elem, ordinality)
     WHERE regexp_replace(COALESCE(m.tax_id,''),'\D','','g') = v_tax
       AND NOT COALESCE(m.status,'') ~ '退會|退出|停權|註銷'
       AND COALESCE(r.elem->>'name','') <> ''
  ) t;

  IF json_array_length(v_list) = 0 THEN RETURN json_build_object('ok',false,'error','no_match'); END IF;
  RETURN json_build_object('ok',true,'candidates',v_list);
END; $function$;

-- 統編＋末3碼驗證：idx 0（本人）排除團體
CREATE OR REPLACE FUNCTION public.member_verify_by_tax(p_tax_id text, p_idx integer, p_last3 text)
 RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tax TEXT := regexp_replace(COALESCE(p_tax_id,''), '\D','','g');
  v_last3 TEXT := right(regexp_replace(COALESCE(p_last3,''), '\D','','g'), 3);
  v_no TEXT; v_name TEXT;
BEGIN
  IF length(v_tax) <> 8 OR length(v_last3) <> 3 THEN RETURN json_build_object('ok',false,'error','input_incomplete'); END IF;

  IF p_idx = 0 THEN
    SELECT m.member_no, m.name INTO v_no, v_name
      FROM tada_members m
     WHERE regexp_replace(COALESCE(m.tax_id,''),'\D','','g') = v_tax
       AND m.member_type <> 'group'
       AND v_last3 IN (right(regexp_replace(COALESCE(m.mobile,''),'\D','','g'),3),
                       right(regexp_replace(COALESCE(m.phone_office,''),'\D','','g'),3),
                       right(regexp_replace(COALESCE(m.contact_phone,''),'\D','','g'),3))
     LIMIT 1;
  ELSE
    SELECT m.member_no || '-' || p_idx, r.elem->>'name' INTO v_no, v_name
      FROM tada_members m
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.reps,'[]'::jsonb))
             WITH ORDINALITY AS r(elem, ordinality)
     WHERE regexp_replace(COALESCE(m.tax_id,''),'\D','','g') = v_tax
       AND r.ordinality = p_idx
       AND right(regexp_replace(COALESCE(r.elem->>'tel',''),'\D','','g'),3) = v_last3
     LIMIT 1;
  END IF;

  IF v_no IS NULL THEN RETURN json_build_object('ok',false,'error','verify_failed'); END IF;
  RETURN json_build_object('ok',true,'member_no',v_no,'name',v_name);
END; $function$;

-- ── 3. LINE 綁定：代表感知（綁到投票名冊該身分列）─────────────────────────
CREATE OR REPLACE FUNCTION public.roster_bind(p_user_id text, p_name text, p_company text, p_tax_id text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_name TEXT := btrim(coalesce(p_name,''));
  v_comp TEXT := btrim(coalesce(p_company,''));
  v_tax  TEXT := btrim(coalesce(p_tax_id,''));
  v_el uuid; ids uuid[]; c tada_members%rowtype;
  v_no TEXT; v_disp TEXT; v_ord INT;
BEGIN
  IF v_name='' THEN RETURN json_build_object('ok',false,'error','missing_name'); END IF;
  SELECT id INTO v_el FROM tada_v_election WHERE status IN ('checkin','open') ORDER BY created_at DESC LIMIT 1;

  -- 已綁定？先查投票名冊（涵蓋個人與代表）
  IF v_el IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM tada_v_members WHERE election_id=v_el AND line_user_id=p_user_id) THEN
      RETURN (SELECT json_build_object('ok',true,'already',true,'name',v.name,'member_no',v.member_no,
                'member_type',v.member_type,'company',v.company,'status',pm.status)
              FROM tada_v_members v LEFT JOIN tada_members pm ON pm.member_no=split_part(v.member_no,'-',1)
              WHERE v.election_id=v_el AND v.line_user_id=p_user_id LIMIT 1);
    END IF;
  END IF;
  -- 舊式個人綁定
  SELECT * INTO c FROM tada_members WHERE line_user_id=p_user_id LIMIT 1;
  IF FOUND THEN RETURN json_build_object('ok',true,'already',true,'name',c.name,'member_no',c.member_no,'member_type',c.member_type,'company',c.company,'status',c.status); END IF;

  -- 找會員
  SELECT coalesce(array_agg(id),'{}') INTO ids FROM tada_members
   WHERE replace(name,' ','')=replace(v_name,' ','')
      OR EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(reps,'[]'::jsonb)) r WHERE replace(coalesce(r->>'name',''),' ','')=replace(v_name,' ',''))
      OR (v_tax<>'' AND (tax_id=v_tax OR cert_no=v_tax));
  IF array_length(ids,1) IS NULL THEN RETURN json_build_object('ok',false,'error','not_found'); END IF;
  IF array_length(ids,1)>1 THEN
    SELECT coalesce(array_agg(id),'{}') INTO ids FROM tada_members
     WHERE id=ANY(ids) AND ((v_comp<>'' AND (name ILIKE '%'||v_comp||'%' OR coalesce(company,'') ILIKE '%'||v_comp||'%'))
                         OR (v_tax<>'' AND (tax_id=v_tax OR cert_no=v_tax)));
    IF coalesce(array_length(ids,1),0)<>1 THEN RETURN json_build_object('ok',false,'error','multiple'); END IF;
  END IF;
  SELECT * INTO c FROM tada_members WHERE id=ids[1];

  -- 團體且輸入姓名對到某代表 → 綁該代表列
  v_ord := NULL;
  IF c.member_type='group' THEN
    SELECT r.ord INTO v_ord FROM jsonb_array_elements(coalesce(c.reps,'[]'::jsonb)) WITH ORDINALITY AS r(elem,ord)
     WHERE replace(coalesce(r.elem->>'name',''),' ','')=replace(v_name,' ','') LIMIT 1;
  END IF;
  IF v_ord IS NOT NULL THEN v_no := c.member_no||'-'||v_ord; v_disp := v_name;
  ELSE v_no := c.member_no; v_disp := c.name; END IF;

  -- 綁定投票名冊該身分列
  IF v_el IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM tada_v_members WHERE election_id=v_el AND member_no=v_no AND line_user_id IS NOT NULL AND line_user_id<>p_user_id) THEN
      RETURN json_build_object('ok',false,'error','taken');
    END IF;
    UPDATE tada_v_members SET line_user_id=p_user_id WHERE election_id=v_el AND member_no=v_no;
    IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_in_roster'); END IF;
  END IF;

  -- 個人：同步主檔綁定與公司/統編補寫（團體代表不動主檔共用欄位）
  IF v_ord IS NULL THEN
    UPDATE tada_members SET line_user_id=p_user_id,
      company=CASE WHEN v_comp<>'' THEN v_comp ELSE company END,
      tax_id =CASE WHEN v_tax<>''  THEN v_tax  ELSE tax_id  END, updated_at=now()
     WHERE id=c.id AND (line_user_id IS NULL OR line_user_id=p_user_id);
  END IF;

  RETURN json_build_object('ok',true,'name',v_disp,'member_no',v_no,'member_type',c.member_type,
    'company',coalesce(nullif(v_comp,''),c.company),'status',c.status);
END; $function$;

CREATE OR REPLACE FUNCTION public.roster_bound(p_user_id text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE v_el uuid; r record; c tada_members%rowtype;
BEGIN
  SELECT id INTO v_el FROM tada_v_election WHERE status IN ('checkin','open') ORDER BY created_at DESC LIMIT 1;
  IF v_el IS NOT NULL THEN
    SELECT v.name, v.member_no, v.member_type, v.company, pm.status, pm.join_date INTO r
      FROM tada_v_members v LEFT JOIN tada_members pm ON pm.member_no=split_part(v.member_no,'-',1)
     WHERE v.election_id=v_el AND v.line_user_id=p_user_id LIMIT 1;
    IF FOUND THEN
      RETURN json_build_object('bound',true,'name',r.name,'member_no',r.member_no,'member_type',r.member_type,
        'company',r.company,'status',r.status,'join_date',r.join_date);
    END IF;
  END IF;
  SELECT * INTO c FROM tada_members WHERE line_user_id=p_user_id LIMIT 1;
  IF FOUND THEN RETURN json_build_object('bound',true,'name',c.name,'member_no',c.member_no,'member_type',c.member_type,
    'company',c.company,'status',c.status,'join_date',c.join_date); END IF;
  RETURN json_build_object('bound',false);
END; $function$;

NOTIFY pgrst, 'reload schema';
