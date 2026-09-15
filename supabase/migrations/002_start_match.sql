-- Pick & Shoot: server-authoritative match start
-- Run this once after 001_initial.sql (and the realtime lobby fix if needed).

create or replace function public.start_room_match(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.rooms;
  active_players integer;
  new_match public.matches;
  new_round public.match_rounds;
  deadline timestamptz;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into target
  from public.rooms
  where id = p_room_id
  for update;

  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  if target.host_user_id <> auth.uid() then
    raise exception 'HOST_ONLY';
  end if;

  if target.status <> 'waiting' then
    raise exception 'ROOM_ALREADY_STARTED';
  end if;

  select count(*) into active_players
  from public.room_players
  where room_id = p_room_id and eliminated = false;

  if active_players < 2 then
    raise exception 'NOT_ENOUGH_PLAYERS';
  end if;

  insert into public.matches (room_id, best_of, status)
  values (p_room_id, target.best_of, 'active')
  returning * into new_match;

  deadline := now() + interval '5 seconds';

  insert into public.match_rounds (match_id, round_number, phase, pick_deadline)
  values (new_match.id, 1, 'picking', deadline)
  returning * into new_round;

  update public.rooms
  set status = 'playing'
  where id = p_room_id;

  return jsonb_build_object(
    'match_id', new_match.id,
    'round_id', new_round.id,
    'pick_deadline', new_round.pick_deadline,
    'best_of', new_match.best_of
  );
end;
$$;

grant execute on function public.start_room_match(uuid) to authenticated;

-- Make the match-start transition visible through Postgres Changes.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'match_rounds'
  ) then
    alter publication supabase_realtime add table public.match_rounds;
  end if;
end $$;
