-- ============================================================================
-- 臨時貴賓掃碼自助報到：貴賓名冊加車號欄，guest_add 支援職稱(併入姓名)與車號
--   /guest/walkin/ 手機表單 → guest_add → 即報到；/guest/ iPad 頁顯示 QR 導向此頁
-- ============================================================================
ALTER TABLE tada_guests ADD COLUMN IF NOT EXISTS plate TEXT;   -- 車號（供停車服務）

DROP FUNCTION IF EXISTS guest_add(text,text,text,text);
DROP FUNCTION IF EXISTS guest_add(text,text,text);
CREATE OR REPLACE FUNCTION guest_add(p_name text, p_org text DEFAULT NULL, p_category text DEFAULT NULL,
                                     p_seat text DEFAULT NULL, p_plate text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_id uuid; v_name text:=btrim(coalesce(p_name,'')); v_org text:=btrim(coalesce(p_org,''));
        v_cat text:=coalesce(nullif(btrim(coalesce(p_category,'')),''),'農業合作單位');
BEGIN
  IF v_name='' THEN RETURN json_build_object('ok',false,'error','need_name'); END IF;
  INSERT INTO tada_guests (name, org, unit, category, seat, plate, status, sort, checked_in, checked_in_at)
  VALUES (v_name, nullif(v_org,''), nullif(v_org,''), v_cat, nullif(btrim(coalesce(p_seat,'')),''),
          nullif(btrim(coalesce(p_plate,'')),''), 'onsite', 9999, TRUE, now())
  RETURNING id INTO v_id;
  RETURN json_build_object('ok',true,'id',v_id,'name',v_name,'org',nullif(v_org,''),
    'seat',nullif(btrim(coalesce(p_seat,'')),''),'plate',nullif(btrim(coalesce(p_plate,'')),''),'category',v_cat);
END $fn$;

NOTIFY pgrst, 'reload schema';
