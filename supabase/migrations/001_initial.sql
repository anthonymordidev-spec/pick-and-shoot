-- Pick & Shoot backend foundation
-- Run this in the Supabase SQL editor or through the Supabase CLI.

create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{5}$'),
  host_user_id uuid not null references auth.users(id) on delete cascade,
  host_name text not null check (char_length(host_name) between 1 and 12),
  game_mode text not null default 'tournament' check (game_mode in ('tournament', 'quick')),
  ruleset text not null default 'classic' check (ruleset in ('classic', 'custom')),
  best_of integer not null default 3 check (best_of in (1, 3, 5)),
  max_players integer not null default 8 check (max_players between 2 and 32),
  status text not null default 'waiting' check (status in ('waiting', 'playing', 'finished')),
  created_at timestamptz not null default now()
);

create table if not exists public.room_players (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 12),
  is_host boolean not null default false,
  is_ready boolean not null default false,
  eliminated boolean not null default false,
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create index if not exists room_players_user_idx on public.room_players(user_id);
create index if not exists room_players_room_idx on public.room_players(room_id);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  best_of integer not null check (best_of in (1, 3, 5)),
  target_wins integer generated always as (ceil(best_of::numeric / 2)::integer) stored,
  status text not null default 'active' check (status in ('active', 'finished')),
  winner_user_id uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

create index if not exists matches_room_idx on public.matches(room_id, started_at desc);

create table if not exists public.match_rounds (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  round_number integer not null check (round_number > 0),
  phase text not null default 'picking' check (phase in ('picking', 'reveal', 'finished')),
  pick_deadline timestamptz not null,
  winner_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique(match_id, round_number)
);

create index if not exists match_rounds_match_idx on public.match_rounds(match_id, round_number);

create table if not exists public.round_choices (
  round_id uuid not null references public.match_rounds(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  choice text not null check (choice in ('rock', 'paper', 'scissors')),
  submitted_at timestamptz not null default now(),
  primary key (round_id, user_id)
);

alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.matches enable row level security;
alter table public.match_rounds enable row level security;
alter table public.round_choices enable row level security;

create or replace function public.is_room_member(target_room uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.room_players rp
    where rp.room_id = target_room and rp.user_id = auth.uid()
  );
$$;

grant execute on function public.is_room_member(uuid) to authenticated;

drop policy if exists room_members_can_read on public.rooms;
create policy room_members_can_read on public.rooms
for select to authenticated
using (public.is_room_member(id));

drop policy if exists room_members_read_players on public.room_players;
create policy room_members_read_players on public.room_players
for select to authenticated
using (public.is_room_member(room_id));

drop policy if exists room_members_read_matches on public.matches;
create policy room_members_read_matches on public.matches
for select to authenticated
using (public.is_room_member(room_id));

drop policy if exists room_members_read_rounds on public.match_rounds;
create policy room_members_read_rounds on public.match_rounds
for select to authenticated
using (
  exists (
    select 1 from public.matches m
    where m.id = match_id and public.is_room_member(m.room_id)
  )
);

-- Choices are intentionally not exposed to other players. The backend resolver
-- reads them with SECURITY DEFINER and only the final result is broadcast/stored.
drop policy if exists choice_owner_can_read on public.round_choices;
create policy choice_owner_can_read on public.round_choices
for select to authenticated
using (user_id = auth.uid());

create or replace function public.make_room_code()
returns text
language plpgsql
volatile
as $$
declare
  candidate text;
begin
  loop
    candidate := upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 5));
    exit when not exists (select 1 from public.rooms where code = candidate);
  end loop;
  return candidate;
end;
$$;

create or replace function public.create_room(
  p_display_name text,
  p_game_mode text default 'tournament',
  p_ruleset text default 'classic',
  p_best_of integer default 3,
  p_max_players integer default 8
)
returns public.rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  new_room public.rooms;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if char_length(trim(p_display_name)) not between 1 and 12 then raise exception 'INVALID_NAME'; end if;
  if p_game_mode not in ('tournament','quick') then raise exception 'INVALID_GAME_MODE'; end if;
  if p_ruleset not in ('classic','custom') then raise exception 'INVALID_RULESET'; end if;
  if p_best_of not in (1,3,5) then raise exception 'INVALID_BEST_OF'; end if;
  if p_max_players < 2 or p_max_players > 32 then raise exception 'INVALID_MAX_PLAYERS'; end if;

  insert into public.rooms (code, host_user_id, host_name, game_mode, ruleset, best_of, max_players)
  values (public.make_room_code(), auth.uid(), upper(trim(p_display_name)), p_game_mode, p_ruleset, p_best_of, p_max_players)
  returning * into new_room;

  insert into public.room_players (room_id, user_id, display_name, is_host, is_ready)
  values (new_room.id, auth.uid(), upper(trim(p_display_name)), true, true);

  return new_room;
end;
$$;

grant execute on function public.create_room(text,text,text,integer,integer) to authenticated;

create or replace function public.join_room(
  p_code text,
  p_display_name text
)
returns public.rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.rooms;
  current_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if char_length(trim(p_display_name)) not between 1 and 12 then raise exception 'INVALID_NAME'; end if;

  select * into target from public.rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if target.status <> 'waiting' then raise exception 'ROOM_ALREADY_STARTED'; end if;

  select count(*) into current_count from public.room_players where room_id = target.id;
  if current_count >= target.max_players and not exists (
    select 1 from public.room_players where room_id = target.id and user_id = auth.uid()
  ) then
    raise exception 'ROOM_FULL';
  end if;

  insert into public.room_players (room_id, user_id, display_name, is_host, is_ready)
  values (target.id, auth.uid(), upper(trim(p_display_name)), false, false)
  on conflict (room_id, user_id) do update
    set display_name = excluded.display_name,
        last_seen_at = now();

  return target;
end;
$$;

grant execute on function public.join_room(text,text) to authenticated;

create or replace function public.leave_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  was_host boolean;
  replacement uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select is_host into was_host from public.room_players
  where room_id = p_room_id and user_id = auth.uid();
  if was_host is null then return; end if;

  delete from public.room_players where room_id = p_room_id and user_id = auth.uid();

  if was_host then
    select user_id into replacement from public.room_players
    where room_id = p_room_id order by joined_at asc limit 1;
    if replacement is null then
      delete from public.rooms where id = p_room_id;
    else
      update public.room_players set is_host = (user_id = replacement) where room_id = p_room_id;
      update public.rooms set host_user_id = replacement,
        host_name = (select display_name from public.room_players where room_id = p_room_id and user_id = replacement)
      where id = p_room_id;
    end if;
  end if;
end;
$$;

grant execute on function public.leave_room(uuid) to authenticated;

-- Realtime authorization for private room channels. A member can receive
-- Broadcast/Presence on their room topic and can send Broadcast messages.
drop policy if exists room_member_receive on realtime.messages;
create policy room_member_receive on realtime.messages
for select to authenticated
using (
  exists (
    select 1
    from public.rooms r
    join public.room_players rp on rp.room_id = r.id
    where rp.user_id = auth.uid()
      and (select realtime.topic()) = 'room:' || r.code
      and realtime.messages.extension in ('broadcast','presence')
  )
);

drop policy if exists room_member_send on realtime.messages;
create policy room_member_send on realtime.messages
for insert to authenticated
with check (
  exists (
    select 1
    from public.rooms r
    join public.room_players rp on rp.room_id = r.id
    where rp.user_id = auth.uid()
      and (select realtime.topic()) = 'room:' || r.code
      and realtime.messages.extension = 'broadcast'
  )
);

create or replace function public.set_ready(p_room_id uuid, p_ready boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists (select 1 from public.room_players where room_id = p_room_id and user_id = auth.uid()) then
    raise exception 'NOT_IN_ROOM';
  end if;
  if exists (select 1 from public.rooms where id = p_room_id and status <> 'waiting') then
    raise exception 'ROOM_ALREADY_STARTED';
  end if;
  update public.room_players
  set is_ready = p_ready, last_seen_at = now()
  where room_id = p_room_id and user_id = auth.uid();
end;
$$;

grant execute on function public.set_ready(uuid,boolean) to authenticated;

grant select on public.rooms, public.room_players, public.matches, public.match_rounds, public.round_choices to authenticated;

-- Postgres Changes must be enabled for the tables that drive the lobby.
-- Without this, the joiner can see the new player after its own refresh, but
-- an already-open host lobby receives no database change event.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_players'
  ) then
    alter publication supabase_realtime add table public.room_players;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'rooms'
  ) then
    alter publication supabase_realtime add table public.rooms;
  end if;
end $$;

-- The browser may only mutate room state through the SECURITY DEFINER RPCs above.
revoke insert, update, delete on public.rooms from anon, authenticated;
revoke insert, update, delete on public.room_players from anon, authenticated;
revoke insert, update, delete on public.matches from anon, authenticated;
revoke insert, update, delete on public.match_rounds from anon, authenticated;
revoke insert, update, delete on public.round_choices from anon, authenticated;
