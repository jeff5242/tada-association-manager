-- roster_bind 綁定比對排除 hidden 會籍（吳昆民個人籍 23080801 與祥圃代表重名案）
-- 執行位置：Supabase SQL Editor 貼上執行一次
-- 只改兩處 WHERE：找會員與重名消歧都加 hidden IS NOT TRUE
-- （完整函式仍以 tada_group_reps_voting.sql 為準，這裡用 CREATE OR REPLACE 覆蓋）

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
   WHERE hidden IS NOT TRUE AND (replace(name,' ','')=replace(v_name,' ','')
      OR EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(reps,'[]'::jsonb)) r WHERE replace(coalesce(r->>'name',''),' ','')=replace(v_name,' ',''))
      OR (v_tax<>'' AND (tax_id=v_tax OR cert_no=v_tax)));
  IF array_length(ids,1) IS NULL THEN RETURN json_build_object('ok',false,'error','not_found'); END IF;
  IF array_length(ids,1)>1 THEN
    SELECT coalesce(array_agg(id),'{}') INTO ids FROM tada_members
     WHERE id=ANY(ids) AND hidden IS NOT TRUE AND ((v_comp<>'' AND (name ILIKE '%'||v_comp||'%' OR coalesce(company,'') ILIKE '%'||v_comp||'%'))
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
