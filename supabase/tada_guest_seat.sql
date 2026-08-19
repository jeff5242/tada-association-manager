-- ============================================================================
-- 貴賓自助報到（iPad）後端：新增座位欄，guest_checkin 回傳座位/用餐/提醒
-- ============================================================================
ALTER TABLE tada_guests ADD COLUMN IF NOT EXISTS seat TEXT;

-- 報到並回傳歡迎畫面所需資訊（座位、用餐、高鐵、備註）
CREATE OR REPLACE FUNCTION guest_checkin(p_guest_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v tada_guests%ROWTYPE;
BEGIN
  SELECT * INTO v FROM tada_guests WHERE id = p_guest_id FOR UPDATE;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'guest_not_found'); END IF;

  IF v.checked_in THEN
    RETURN json_build_object('ok', false, 'error', 'already_checked_in',
      'name', v.name, 'org', v.org, 'seat', v.seat, 'meal', v.meal, 'train', v.train, 'note', v.note,
      'checked_in_at', v.checked_in_at);
  END IF;

  UPDATE tada_guests SET checked_in = TRUE, checked_in_at = NOW() WHERE id = v.id;

  RETURN json_build_object('ok', true, 'name', v.name, 'org', v.org,
    'seat', v.seat, 'meal', v.meal, 'train', v.train, 'note', v.note);
END;
$$;

-- 撤銷貴賓報到（現場點錯時用）
CREATE OR REPLACE FUNCTION guest_checkin_undo(p_guest_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE tada_guests SET checked_in = FALSE, checked_in_at = NULL WHERE id = p_guest_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'guest_not_found'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

NOTIFY pgrst, 'reload schema';
