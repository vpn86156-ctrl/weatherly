-- Lootora game backend (Supabase SQL Editor)
-- Run this whole file once in the Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.lootora_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null default 'Игрок',
  balance integer not null default 1000 check (balance >= 0),
  reputation integer not null default 100 check (reputation between 0 and 100),
  created_at timestamptz not null default now()
);
create unique index if not exists lootora_profiles_username_lower on public.lootora_profiles (lower(username));

create or replace function public.lootora_new_profile()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.lootora_profiles(id, username, balance, reputation)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'display_name',''), split_part(new.email,'@',1), 'Игрок'), 1000, 100)
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists lootora_auth_user_created on auth.users;
create trigger lootora_auth_user_created after insert on auth.users
for each row execute procedure public.lootora_new_profile();

create table if not exists public.lootora_chat (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists lootora_chat_created on public.lootora_chat(created_at desc);

create table if not exists public.lootora_reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  target_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (char_length(reason) between 3 and 300),
  created_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','reviewed','dismissed'))
);

create table if not exists public.lootora_scam_attempts (
  id bigint generated always as identity primary key,
  attacker_id uuid not null references auth.users(id) on delete cascade,
  target_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null check (amount between 10 and 500),
  status text not null default 'pending' check (status in ('pending','accepted','declined','resolved')),
  result text,
  created_at timestamptz not null default now(),
  check (attacker_id <> target_id)
);
create index if not exists lootora_scam_target on public.lootora_scam_attempts(target_id, status);

create table if not exists public.lootora_daily_scores (
  user_id uuid not null references auth.users(id) on delete cascade,
  score_date date not null default (timezone('utc', now())::date),
  trade_score integer not null default 0 check (trade_score >= 0),
  primary key(user_id, score_date)
);

alter table public.lootora_profiles enable row level security;
alter table public.lootora_chat enable row level security;
alter table public.lootora_reports enable row level security;
alter table public.lootora_scam_attempts enable row level security;
alter table public.lootora_daily_scores enable row level security;

drop policy if exists "profiles visible to authenticated" on public.lootora_profiles;
create policy "profiles visible to authenticated" on public.lootora_profiles for select to authenticated using (true);
drop policy if exists "users update own profile" on public.lootora_profiles;
create policy "users update own profile" on public.lootora_profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id and balance = (select p.balance from public.lootora_profiles p where p.id = auth.uid()) and reputation = (select p.reputation from public.lootora_profiles p where p.id = auth.uid()));

drop policy if exists "authenticated read chat" on public.lootora_chat;
create policy "authenticated read chat" on public.lootora_chat for select to authenticated using (true);
drop policy if exists "send own chat" on public.lootora_chat;
create policy "send own chat" on public.lootora_chat for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "submit own report" on public.lootora_reports;
create policy "submit own report" on public.lootora_reports for insert to authenticated with check (auth.uid() = reporter_id and reporter_id <> target_id);
drop policy if exists "read own reports" on public.lootora_reports;
create policy "read own reports" on public.lootora_reports for select to authenticated using (auth.uid() = reporter_id or auth.uid() = target_id);

drop policy if exists "read scam participant" on public.lootora_scam_attempts;
create policy "read scam participant" on public.lootora_scam_attempts for select to authenticated using (auth.uid() = attacker_id or auth.uid() = target_id);

drop policy if exists "read daily leaderboard" on public.lootora_daily_scores;
create policy "read daily leaderboard" on public.lootora_daily_scores for select to authenticated using (true);

create or replace function public.lootora_try_scam(p_target uuid, p_amount integer)
returns bigint language plpgsql security definer set search_path = public
as $$
declare new_id bigint;
begin
  if auth.uid() is null or p_target = auth.uid() or p_amount < 10 or p_amount > 500 then
    raise exception 'Некорректная игровая попытка';
  end if;
  if not exists(select 1 from public.lootora_profiles where id = p_target) then raise exception 'Игрок не найден'; end if;
  insert into public.lootora_scam_attempts(attacker_id,target_id,amount)
  values(auth.uid(),p_target,p_amount) returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.lootora_resolve_scam(p_attempt bigint, p_accept boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare a public.lootora_scam_attempts%rowtype; won boolean;
begin
  select * into a from public.lootora_scam_attempts where id=p_attempt for update;
  if not found or a.target_id <> auth.uid() or a.status <> 'pending' then raise exception 'Предложение недоступно'; end if;
  if not p_accept then
    update public.lootora_scam_attempts set status='declined', result='Игрок отказался' where id=p_attempt;
    return 'declined';
  end if;
  select (random() < 0.35) into won;
  if won then
    update public.lootora_profiles set balance=balance-a.amount where id=a.target_id and balance>=a.amount;
    if not found then raise exception 'Недостаточно виртуальных рублей'; end if;
    update public.lootora_profiles set balance=balance+a.amount, reputation=greatest(0,reputation-12) where id=a.attacker_id;
    update public.lootora_profiles set reputation=least(100,reputation+2) where id=a.target_id;
    update public.lootora_scam_attempts set status='resolved', result='success' where id=p_attempt;
    return 'success';
  else
    update public.lootora_profiles set reputation=greatest(0,reputation-5), balance=greatest(0,balance-25) where id=a.attacker_id;
    update public.lootora_profiles set reputation=least(100,reputation+3) where id=a.target_id;
    update public.lootora_scam_attempts set status='resolved', result='failed' where id=p_attempt;
    return 'failed';
  end if;
end;
$$;

create or replace function public.lootora_daily_trade(p_points integer default 1)
returns integer language plpgsql security definer set search_path = public
as $$
declare new_score integer;
begin
  if auth.uid() is null or p_points < 1 or p_points > 10 then raise exception 'Некорректное действие'; end if;
  insert into public.lootora_daily_scores(user_id, score_date, trade_score)
  values(auth.uid(), timezone('utc',now())::date, p_points)
  on conflict(user_id,score_date) do update set trade_score=lootora_daily_scores.trade_score+excluded.trade_score
  returning trade_score into new_score;
  return new_score;
end;
$$;

grant execute on function public.lootora_try_scam(uuid,integer) to authenticated;
grant execute on function public.lootora_resolve_scam(bigint,boolean) to authenticated;
grant execute on function public.lootora_daily_trade(integer) to authenticated;

-- Realtime chat: enable the table in Database -> Publications -> supabase_realtime if not already enabled.
