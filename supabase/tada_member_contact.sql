-- ============================================================================
-- 電子會員證：會員自行更新聯絡資料／公司名稱
--   依綁定的 LINE userId 解析會員（個人＝tada_members.line_user_id；
--   團體代表＝tada_v_members 綁定→取母編號對應之 tada_members 團體列）。
--   欄位空白＝保留原值（避免誤清空）。
-- ============================================================================
CREATE OR REPLACE FUNCTION member_contact_get(p_user_id text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_no text; m tada_members%ROWTYPE; v_el uuid;
BEGIN
  SELECT member_no INTO v_no FROM tada_members WHERE line_user_id=p_user_id LIMIT 1;
  IF v_no IS NULL THEN
    SELECT id INTO v_el FROM tada_v_election WHERE status IN('checkin','open') ORDER BY created_at DESC LIMIT 1;
    IF v_el IS NOT NULL THEN SELECT split_part(member_no,'-',1) INTO v_no FROM tada_v_members WHERE election_id=v_el AND line_user_id=p_user_id LIMIT 1; END IF;
  END IF;
  IF v_no IS NULL THEN RETURN json_build_object('ok',false,'error','not_bound'); END IF;
  SELECT * INTO m FROM tada_members WHERE member_no=v_no LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_found'); END IF;
  RETURN json_build_object('ok',true,'member_no',m.member_no,'is_group',(m.member_type='group'),
    'name',m.name,'company',m.company,'title',m.title,'mobile',m.mobile,'email',m.email,'addr_mail',m.addr_mail);
END $fn$;

CREATE OR REPLACE FUNCTION member_contact_save(p_user_id text, p_company text DEFAULT NULL, p_title text DEFAULT NULL,
       p_mobile text DEFAULT NULL, p_email text DEFAULT NULL, p_addr text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_no text; v_el uuid;
BEGIN
  SELECT member_no INTO v_no FROM tada_members WHERE line_user_id=p_user_id LIMIT 1;
  IF v_no IS NULL THEN
    SELECT id INTO v_el FROM tada_v_election WHERE status IN('checkin','open') ORDER BY created_at DESC LIMIT 1;
    IF v_el IS NOT NULL THEN SELECT split_part(member_no,'-',1) INTO v_no FROM tada_v_members WHERE election_id=v_el AND line_user_id=p_user_id LIMIT 1; END IF;
  END IF;
  IF v_no IS NULL THEN RETURN json_build_object('ok',false,'error','not_bound'); END IF;
  UPDATE tada_members SET
    company   = COALESCE(NULLIF(btrim(coalesce(p_company,'')),''), company),
    title     = COALESCE(NULLIF(btrim(coalesce(p_title,'')),''), title),
    mobile    = COALESCE(NULLIF(btrim(coalesce(p_mobile,'')),''), mobile),
    email     = COALESCE(NULLIF(btrim(coalesce(p_email,'')),''), email),
    addr_mail = COALESCE(NULLIF(btrim(coalesce(p_addr,'')),''), addr_mail),
    updated_at = now()
  WHERE member_no=v_no;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_found'); END IF;
  RETURN json_build_object('ok',true);
END $fn$;
NOTIFY pgrst, 'reload schema';
