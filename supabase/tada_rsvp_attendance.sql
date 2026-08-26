-- 出席名單管理：新增欄位
-- meal: 'yes'=會用餐, 'no'=不會用餐, null=未確認
-- invite_source: '協會貴賓','陳總貴賓','長官貴賓','理監事貴賓', null=未標註
ALTER TABLE tada_rsvp ADD COLUMN IF NOT EXISTS meal text;
ALTER TABLE tada_rsvp ADD COLUMN IF NOT EXISTS invite_source text;
ALTER TABLE tada_guests ADD COLUMN IF NOT EXISTS invite_source text;
NOTIFY pgrst, 'reload schema';
