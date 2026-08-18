-- ============================================================================
-- 續約帶入：以統編／會員編號／LINE 綁定查出會員，回傳「帶入表單」必要欄位
--   隱私：只認精確識別碼（不做姓名模糊查詢，防列舉）；
--         代表人只回姓名＋電話，不外洩生日／身分證／email 等敏感欄位。
-- ============================================================================
CREATE OR REPLACE FUNCTION member_prefill(p_query TEXT DEFAULT NULL, p_user_id TEXT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE m tada_members%ROWTYPE; q TEXT; v_reps JSON;
BEGIN
  -- ① LINE 綁定
  IF COALESCE(p_user_id,'') <> '' THEN
    SELECT * INTO m FROM tada_members WHERE line_user_id = p_user_id LIMIT 1;
  END IF;
  -- ② 統編（8碼）或 會員編號
  IF m.id IS NULL AND COALESCE(TRIM(p_query),'') <> '' THEN
    q := regexp_replace(TRIM(p_query), '\s', '', 'g');
    SELECT * INTO m FROM tada_members
     WHERE regexp_replace(COALESCE(tax_id,''), '\D', '', 'g') = q
        OR member_no = q
     LIMIT 1;
  END IF;

  IF m.id IS NULL THEN RETURN json_build_object('found', false); END IF;

  -- 代表人只留姓名＋電話
  SELECT json_agg(json_build_object('name', r->>'name', 'tel', r->>'tel')) INTO v_reps
    FROM jsonb_array_elements(COALESCE(m.reps::jsonb, '[]'::jsonb)) r
   WHERE COALESCE(r->>'name','') <> '';

  RETURN json_build_object(
    'found', true,
    'member_no', m.member_no, 'member_type', m.member_type,
    'name', m.name, 'company', m.company, 'tax_id', m.tax_id,
    'mobile', COALESCE(NULLIF(m.mobile,''), m.contact_phone),
    'contact_name', m.contact_name, 'contact_phone', m.contact_phone,
    'reps', COALESCE(v_reps, '[]'::json),
    'status', m.status
  );
END $$;
GRANT EXECUTE ON FUNCTION member_prefill(TEXT, TEXT) TO anon;

NOTIFY pgrst, 'reload schema';
