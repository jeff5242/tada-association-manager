-- 報到機裝置管理：kiosk-agent 開機自動註冊（heartbeat upsert），
-- 後台把 managed 打開後，該裝置才會下載離線名冊快照。
-- 在 Supabase SQL Editor 執行一次即可。

create table if not exists tada_devices (
  id uuid primary key default gen_random_uuid(),
  device_id text unique not null,          -- hostname-MAC後6碼，agent 自動產生
  label text,                              -- 後台自訂名稱（例：服務台1號機）
  managed boolean not null default false,  -- 打開後 agent 才下載離線名冊
  hostname text,
  ip text,
  version text,
  election_id uuid,
  pending_count integer default 0,         -- 尚未回放的離線報到筆數
  last_seen timestamptz,
  created_at timestamptz not null default now()
);

alter table tada_devices enable row level security;

-- 與其他 tada_ 表一致：anon 可讀寫（報到機用 publishable key 註冊/heartbeat）
drop policy if exists "tada_devices_all" on tada_devices;
create policy "tada_devices_all" on tada_devices
  for all using (true) with check (true);

notify pgrst, 'reload schema';
