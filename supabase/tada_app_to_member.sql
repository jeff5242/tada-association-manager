-- ============================================================================
-- 入會申請 → 正式會員：把 tada_applications 轉成 tada_members，並加進第六屆投票名冊
--   會員編號 = 西元後2碼+月+日+序號（如 26081901）；狀態=有效會員；join_date=民國
--   團體：name=org_name、reps=代表人(姓名+電話+email)；個人：name=姓名、company=org_name
-- ============================================================================
CREATE OR REPLACE FUNCTION app_to_member(p_app_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  a tada_applications%ROWTYPE;
  v_prefix TEXT; v_seq INT; v_no TEXT; v_reps JSONB := '[]'::jsonb;
  v_name TEXT; v_type TEXT; v_join TEXT;
  v_e UUID := '66666666-6666-4666-8666-666666666666';   -- 第六屆
BEGIN
  SELECT * INTO a FROM tada_applications WHERE id = p_app_id;
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'error','app_not_found'); END IF;

  v_type := COALESCE(a.type,'personal');
  v_name := CASE WHEN v_type='group' THEN COALESCE(NULLIF(a.org_name,''), a.name) ELSE COALESCE(a.name, a.org_name) END;
  IF COALESCE(TRIM(v_name),'')='' THEN RETURN json_build_object('ok',false,'error','no_name'); END IF;

  -- 防重複：同統編或同名已在名冊 → 不重建
  IF EXISTS (SELECT 1 FROM tada_members
             WHERE (COALESCE(a.license_no,'')<>'' AND tax_id = a.license_no)
                OR replace(name,' ','') = replace(v_name,' ','')) THEN
    RETURN json_build_object('ok',false,'error','already_member');
  END IF;

  -- 會員編號：YYMMDD(西元後2碼) + 兩碼序號
  v_prefix := to_char(now(),'YYMMDD');
  SELECT COALESCE(MAX((substring(member_no from 7 for 2))::int),0)+1 INTO v_seq
    FROM tada_members WHERE member_no LIKE v_prefix||'%' AND member_no ~ '^[0-9]{8}$';
  v_no := v_prefix || lpad(v_seq::text,2,'0');

  -- 團體代表人（只留姓名+電話+email）
  IF v_type='group' THEN
    IF COALESCE(a.rep_name,'')<>''  THEN v_reps := v_reps || jsonb_build_array(jsonb_build_object('name',a.rep_name,'tel',a.rep_tel,'email',a.rep_email)); END IF;
    IF COALESCE(a.rep2_name,'')<>'' THEN v_reps := v_reps || jsonb_build_array(jsonb_build_object('name',a.rep2_name,'tel',a.rep2_tel,'email',a.rep2_email)); END IF;
    IF COALESCE(a.rep3_name,'')<>'' THEN v_reps := v_reps || jsonb_build_array(jsonb_build_object('name',a.rep3_name,'tel',a.rep3_tel,'email',a.rep3_email)); END IF;
  END IF;

  v_join := (extract(year from now())::int - 1911)::text || '.' || to_char(now(),'MM.DD');

  INSERT INTO tada_members (member_no, name, member_type, company, tax_id, mobile, email,
                            contact_name, contact_phone, contact_email, addr_mail, reps,
                            status, join_date, note)
    VALUES (v_no, v_name, v_type, COALESCE(a.org_name,''), NULLIF(a.license_no,''),
            COALESCE(NULLIF(a.tel_mobile,''), a.rep_tel),
            COALESCE(NULLIF(a.email,''), a.rep_email),
            a.rep_name, COALESCE(NULLIF(a.contact_tel,''), a.rep_tel),
            COALESCE(NULLIF(a.contact_email,''), a.rep_email),
            COALESCE(NULLIF(a.addr_mail,''), a.org_addr), v_reps,
            '有效會員', v_join, '由入會申請轉入'||CASE WHEN a.is_renewal THEN '（續約）' ELSE '' END);

  -- 加進第六屆投票名冊（可報到/投票）
  INSERT INTO tada_v_members (election_id, member_no, name, member_type)
    VALUES (v_e, v_no, v_name, v_type)
    ON CONFLICT (election_id, member_no) DO NOTHING;

  -- 申請標記為已核准（已轉會員）
  UPDATE tada_applications SET status='approved', approved_at=COALESCE(approved_at, now()) WHERE id = p_app_id;

  RETURN json_build_object('ok',true,'member_no',v_no,'name',v_name,'member_type',v_type);
END $$;
GRANT EXECUTE ON FUNCTION app_to_member(UUID) TO anon;

NOTIFY pgrst, 'reload schema';
