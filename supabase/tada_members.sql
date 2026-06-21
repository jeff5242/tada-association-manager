-- 建立 TADA 會員名冊資料表
create table if not exists tada_members (
  id          uuid        default gen_random_uuid() primary key,
  name        text        not null unique,
  company     text        not null default '',
  terms       jsonb       not null default '[]',
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- 自動更新 updated_at
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger tada_members_updated_at
  before update on tada_members
  for each row execute procedure update_updated_at();

-- RLS：允許 anon 讀寫（內部工具，anon key 即為存取憑證）
alter table tada_members enable row level security;

create policy "anon can read"   on tada_members for select using (true);
create policy "anon can insert" on tada_members for insert with check (true);
create policy "anon can update" on tada_members for update using (true) with check (true);
create policy "anon can delete" on tada_members for delete using (true);
