-- 報到（Check-in）欄位 —— 附加在 tada_rsvp 上
-- 電子會員證的 QR 被現場人員掃描後，標記該會員已報到。
-- 執行位置：Supabase SQL Editor → RUN（可重複執行）

ALTER TABLE tada_rsvp
  ADD COLUMN IF NOT EXISTS checked_in     BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS checked_in_at  TIMESTAMPTZ;
