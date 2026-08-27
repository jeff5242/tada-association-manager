-- ════════════════════════════════════════════════════════════════════
-- 第六屆選舉：四種選票的職位別
--   director            理事      （會員大會投票，應選 11 席）
--   supervisor          監事      （會員大會投票，應選 3 席）
--   executive           常務理事  （第二階段由當選理事互選）
--   exec_supervisor     常務監事  （第二階段由當選監事互選）← 新增
-- ════════════════════════════════════════════════════════════════════

-- tada_v_candidates.position 放寬，加入 exec_supervisor
ALTER TABLE tada_v_candidates DROP CONSTRAINT IF EXISTS tada_v_candidates_position_check;
ALTER TABLE tada_v_candidates ADD CONSTRAINT tada_v_candidates_position_check
  CHECK (position IN ('director','supervisor','executive','exec_supervisor'));

ALTER TABLE tada_v_votes DROP CONSTRAINT IF EXISTS tada_v_votes_position_check;
ALTER TABLE tada_v_votes ADD CONSTRAINT tada_v_votes_position_check
  CHECK (position IN ('director','supervisor','executive','exec_supervisor'));

-- 紙本掃描也要能記這兩種
ALTER TABLE tada_ballot_scans DROP CONSTRAINT IF EXISTS tada_ballot_scans_position_check;
ALTER TABLE tada_ballot_scans ADD CONSTRAINT tada_ballot_scans_position_check
  CHECK (position IN ('director','supervisor','executive','exec_supervisor'));

-- ── 清除端對端測試殘留（正式開票前必須執行）────────────────────────
-- anon 金鑰受 RLS 限制無法刪除，需在 SQL Editor 以本檔執行。
DELETE FROM tada_v_votes
 WHERE election_id = '66666666-6666-4666-8666-666666666666';

DELETE FROM tada_ballot_scans
 WHERE ballot_no LIKE '2999%';

NOTIFY pgrst, 'reload schema';
