-- ============================================================================
-- 團體會員：由成員自行編輯三位代表人
--   權限：呼叫者的 LINE 必須已綁定為「本團體之某位代表」（即已取得會員證報到碼）。
--   不限第一位代表，任一已綁定的團體代表皆可編輯。
--   儲存時同步更新主檔 tada_members.reps 與投票名冊 tada_v_members 代表列
--   （改名保留該序位既有的綁定/報到；新增序位則建列；移除序位則刪列）。
-- ============================================================================

-- 讀取本團體目前代表（供編輯表單帶入）
CREATE OR REPLACE FUNCTION public.group_reps_get(p_user_id text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE v_el uuid; v tada_v_members%ROWTYPE; v_parent text; m tada_members%ROWTYPE;
BEGIN
  SELECT id INTO v_el FROM tada_v_election WHERE status IN ('checkin','open') ORDER BY created_at DESC LIMIT 1;
  IF v_el IS NULL THEN RETURN json_build_object('ok',false,'error','no_election'); END IF;

  SELECT * INTO v FROM tada_v_members WHERE election_id=v_el AND line_user_id=p_user_id LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_bound'); END IF;
  IF v.member_type <> 'group' THEN RETURN json_build_object('ok',false,'error','not_group'); END IF;

  v_parent := split_part(v.member_no,'-',1);
  SELECT * INTO m FROM tada_members WHERE member_no=v_parent LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','group_not_found'); END IF;

  RETURN json_build_object('ok',true,'member_no',v_parent,
    'company',COALESCE(NULLIF(m.company,''),m.name),
    'reps',COALESCE(m.reps,'[]'::jsonb));
END $fn$;

-- 儲存代表（p_reps：最多 3 筆，每筆 {name, tel, email}）
CREATE OR REPLACE FUNCTION public.group_reps_save(p_user_id text, p_reps jsonb)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER
AS $fn$
DECLARE
  v_el uuid; v tada_v_members%ROWTYPE; v_parent text; m tada_members%ROWTYPE;
  v_clean jsonb := '[]'::jsonb; e jsonb; v_name text; i int; v_no text; v_comp text;
BEGIN
  SELECT id INTO v_el FROM tada_v_election WHERE status IN ('checkin','open') ORDER BY created_at DESC LIMIT 1;
  IF v_el IS NULL THEN RETURN json_build_object('ok',false,'error','no_election'); END IF;

  -- 權限：必須是本團體已綁定的代表
  SELECT * INTO v FROM tada_v_members WHERE election_id=v_el AND line_user_id=p_user_id LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','not_bound'); END IF;
  IF v.member_type <> 'group' THEN RETURN json_build_object('ok',false,'error','not_group'); END IF;
  v_parent := split_part(v.member_no,'-',1);
  SELECT * INTO m FROM tada_members WHERE member_no=v_parent LIMIT 1;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','group_not_found'); END IF;
  v_comp := COALESCE(NULLIF(m.company,''),m.name);

  -- 清洗輸入：取前 3 筆、姓名必填
  FOR e IN SELECT * FROM jsonb_array_elements(COALESCE(p_reps,'[]'::jsonb)) LOOP
    v_name := btrim(COALESCE(e->>'name',''));
    IF v_name <> '' AND jsonb_array_length(v_clean) < 3 THEN
      v_clean := v_clean || jsonb_build_object('name',v_name,'tel',btrim(COALESCE(e->>'tel','')),'email',btrim(COALESCE(e->>'email','')));
    END IF;
  END LOOP;
  IF jsonb_array_length(v_clean)=0 THEN RETURN json_build_object('ok',false,'error','need_one_rep'); END IF;

  -- 更新主檔
  UPDATE tada_members SET reps=v_clean, updated_at=now() WHERE member_no=v_parent;

  -- 同步投票名冊代表列（1..3）
  FOR i IN 1..3 LOOP
    v_no := v_parent||'-'||i;
    IF i <= jsonb_array_length(v_clean) THEN
      v_name := v_clean->(i-1)->>'name';
      UPDATE tada_v_members SET name=v_name, rep=v_name, company=v_comp WHERE election_id=v_el AND member_no=v_no;
      IF NOT FOUND THEN
        INSERT INTO tada_v_members (election_id, member_no, name, member_type, rep, company, tax_id, is_checked_in)
        VALUES (v_el, v_no, v_name, 'group', v_name, v_comp, m.tax_id, FALSE);
      END IF;
    ELSE
      DELETE FROM tada_v_members WHERE election_id=v_el AND member_no=v_no;
    END IF;
  END LOOP;

  RETURN json_build_object('ok',true,'member_no',v_parent,'reps',v_clean);
END $fn$;

NOTIFY pgrst, 'reload schema';
