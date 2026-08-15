-- ============================================================================
-- 報到牆：公司 Logo 欄位與專用查詢
-- 執行位置：Supabase SQL Editor → RUN（本檔可重複執行）
--
-- 需要先在 Supabase Dashboard → Storage 建一個 public bucket：
--   名稱 member-logos，Public 打勾
-- 後臺上傳後把公開網址存進 logo_url 即可。
-- ============================================================================

ALTER TABLE tada_members ADD COLUMN IF NOT EXISTS logo_url TEXT;
ALTER TABLE tada_guests  ADD COLUMN IF NOT EXISTS logo_url TEXT;


-- ============================================================================
-- RPC：報到牆要顯示的內容
--
-- 刻意做成 RPC 而不是讓牆直接讀 tada_members：
--   牆只需要「已報到者的姓名、公司、logo、時間」，不需要整份名冊。
--   之後收回 anon 對 tada_members 的直讀時（見規格第十節），這面牆不會壞。
--
-- 團體代表的 member_no 是「會員編號-N」，要去掉尾碼才對得回主名冊。
-- ============================================================================
CREATE OR REPLACE FUNCTION checkin_wall(p_election UUID)
RETURNS JSON LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT COALESCE(json_agg(t ORDER BY t.checked_at DESC), '[]'::json)
  FROM (
    SELECT
      COALESCE(NULLIF(v.rep, ''), v.name)                    AS display_name,
      COALESCE(NULLIF(m.company, ''), v.name)                AS company,
      m.logo_url                                             AS logo_url,
      v.check_in_time                                        AS checked_at,
      'member'                                               AS kind
    FROM tada_v_members v
    LEFT JOIN tada_members m
           ON m.member_no = split_part(v.member_no, '-', 1)
   WHERE v.election_id = p_election AND v.is_checked_in

    UNION ALL

    SELECT g.name, COALESCE(NULLIF(g.org,''), g.name), g.logo_url, g.checked_in_at, 'guest'
      FROM tada_guests g
     WHERE g.checked_in
  ) t;
$$;

GRANT EXECUTE ON FUNCTION checkin_wall(UUID) TO anon;


-- ============================================================================
-- Storage：member-logos bucket 的寫入政策
--
-- bucket 本身要在 Dashboard → Storage → New bucket 建立（名稱 member-logos、
-- 勾 Public）。建好之後執行下面這段，後臺才上傳得了。
--
-- ⚠️ 這會讓持有 anon key 的人都能往這個 bucket 寫檔——而 anon key 就在公開的
--    assets/liff-common.js 裡。與本專案既有的作法一致（tada_members 目前也是
--    anon 可寫），但這是一筆技術債：正確做法是後臺改用需要登入的金鑰。
--    在那之前，至少把它限制在單一 bucket、且不開刪除。
-- ============================================================================

DROP POLICY IF EXISTS "anon upload member logos" ON storage.objects;
CREATE POLICY "anon upload member logos" ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (bucket_id = 'member-logos');

DROP POLICY IF EXISTS "public read member logos" ON storage.objects;
CREATE POLICY "public read member logos" ON storage.objects
  FOR SELECT TO anon
  USING (bucket_id = 'member-logos');
