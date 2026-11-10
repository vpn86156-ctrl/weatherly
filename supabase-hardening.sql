-- Lootora hardening and integration fixes
-- Apply after supabase-clicker.sql and supabase-social.sql.
begin;

alter table public.lootora_chat
  add column if not exists username text not null default 'Охотник';

do $lootora$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='lootora_chat_username_length'
      and conrelid='public.lootora_chat'::regclass
  ) then
    alter table public.lootora_chat
      add constraint lootora_chat_username_length
      check (char_length(username) between 1 and 24);
  end if;
end
$lootora$;

drop policy if exists "Authenticated users read chat" on public.lootora_chat;
drop policy if exists "authenticated read chat" on public.lootora_chat;
drop policy if exists "Players send own chat messages" on public.lootora_chat;
drop policy if exists "send own chat" on public.lootora_chat;
create policy "Authenticated users read chat"
  on public.lootora_chat for select to authenticated using (true);
create policy "Players send own chat messages"
  on public.lootora_chat for insert to authenticated
  with check ((select auth.uid()) = user_id);

alter policy "Players insert own clicker save" on public.lootora_clicker_saves
  with check ((select auth.uid()) = user_id);
alter policy "Players read own clicker save" on public.lootora_clicker_saves
  using ((select auth.uid()) = user_id);
alter policy "Players update own clicker save" on public.lootora_clicker_saves
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
alter policy "Players can view their PvP matches" on public.lootora_pvp_matches
  using ((select auth.uid()) = player_a or (select auth.uid()) = player_b);

create table if not exists public.lootora_public_leaderboard (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null default 'Охотник',
  level integer not null default 1 check (level >= 1),
  kills bigint not null default 0 check (kills >= 0),
  total_damage bigint not null default 0 check (total_damage >= 0),
  updated_at timestamptz not null default now()
);
alter table public.lootora_public_leaderboard enable row level security;
drop policy if exists "Authenticated players can view public leaderboard" on public.lootora_public_leaderboard;
create policy "Authenticated players can view public leaderboard"
  on public.lootora_public_leaderboard for select to authenticated using (true);
revoke all on public.lootora_public_leaderboard from anon, public;
grant select on public.lootora_public_leaderboard to authenticated;

create or replace function public.lootora_sync_public_leaderboard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  insert into public.lootora_public_leaderboard
    (user_id, username, level, kills, total_damage, updated_at)
  values
    (new.user_id, coalesce(nullif(btrim(new.username), ''), 'Охотник'),
     new.level, new.kills, new.total_damage, coalesce(new.updated_at, now()))
  on conflict (user_id) do update set
    username = excluded.username,
    level = excluded.level,
    kills = excluded.kills,
    total_damage = excluded.total_damage,
    updated_at = excluded.updated_at;
  return new;
end;
$function$;
revoke all on function public.lootora_sync_public_leaderboard() from public, anon, authenticated;

drop trigger if exists lootora_sync_public_leaderboard_trigger on public.lootora_clicker_saves;
create trigger lootora_sync_public_leaderboard_trigger
after insert or update of username, level, kills, total_damage, updated_at
on public.lootora_clicker_saves
for each row execute function public.lootora_sync_public_leaderboard();

insert into public.lootora_public_leaderboard
  (user_id, username, level, kills, total_damage, updated_at)
select user_id, coalesce(nullif(btrim(username), ''), 'Охотник'),
       level, kills, total_damage, updated_at
from public.lootora_clicker_saves
on conflict (user_id) do update set
  username=excluded.username, level=excluded.level, kills=excluded.kills,
  total_damage=excluded.total_damage, updated_at=excluded.updated_at;

create or replace view public.lootora_leaderboard
with (security_invoker = true)
as
select user_id, username, level, kills, total_damage
from public.lootora_public_leaderboard;
revoke all on public.lootora_leaderboard from anon, public;
grant select on public.lootora_leaderboard to authenticated;

create index if not exists lootora_chat_user_id_idx on public.lootora_chat(user_id);
create index if not exists lootora_guilds_owner_id_idx on public.lootora_guilds(owner_id);
create index if not exists lootora_pvp_matches_player_a_idx on public.lootora_pvp_matches(player_a);
create index if not exists lootora_pvp_matches_player_b_idx on public.lootora_pvp_matches(player_b);
create index if not exists lootora_pvp_matches_winner_id_idx on public.lootora_pvp_matches(winner_id);
create index if not exists lootora_reports_reporter_id_idx on public.lootora_reports(reporter_id);
create index if not exists lootora_reports_target_id_idx on public.lootora_reports(target_id);
create index if not exists lootora_scam_attempts_attacker_id_idx on public.lootora_scam_attempts(attacker_id);
drop index if exists public.lootora_chat_created_at_idx;
drop index if exists public.lootora_guild_members_guild_idx;


-- Keep auth.uid() evaluation outside per-row RLS expressions.
alter policy "read own reports" on public.lootora_reports
  using ((select auth.uid()) = reporter_id or (select auth.uid()) = target_id);
alter policy "submit own report" on public.lootora_reports
  with check ((select auth.uid()) = reporter_id and reporter_id <> target_id);
alter policy "read scam participant" on public.lootora_scam_attempts
  using ((select auth.uid()) = attacker_id or (select auth.uid()) = target_id);

commit;
