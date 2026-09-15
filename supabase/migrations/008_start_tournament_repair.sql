-- Pick & Shoot — resilient start_tournament repair
-- Run after the tournament reset/install. Safe to run more than once.
-- Keeps the existing tournament engine; only makes the start operation
-- idempotent and able to recover a stale room from an earlier test.

create or replace function public.start_tournament(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  room_record record;
  human_count integer;
  existing_tournament record;
  tour record;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select r.*
  into room_record
  from public.rooms r
  where r.id = p_room_id
  for update;

  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  if room_record.host_user_id <> auth.uid() then
    raise exception 'HOST_ONLY';
  end if;

  select t.*
  into existing_tournament
  from public.tournaments t
  where t.room_id = p_room_id
  order by t.created_at desc
  limit 1;

  -- If a previous test already started this room and the tournament exists,
  -- restore that tournament instead of failing with ROOM_ALREADY_STARTED.
  if room_record.status = 'playing' and existing_tournament.id is not null then
    return jsonb_build_object(
      'tournament_id', existing_tournament.id,
      'stage_number', existing_tournament.stage_number,
      'resumed', true
    );
  end if;

  -- A stale 'playing' flag with no tournament is recoverable: return the room
  -- to waiting, then create a fresh tournament below.
  if room_record.status = 'playing' and existing_tournament.id is null then
    update public.rooms
    set status = 'waiting'
    where id = p_room_id;
    room_record.status := 'waiting';
  end if;

  select count(*)
  into human_count
  from public.room_players rp
  where rp.room_id = p_room_id
    and coalesce(rp.eliminated, false) = false;

  if human_count < 2 then
    raise exception 'NOT_ENOUGH_PLAYERS';
  end if;

  -- Remove any incomplete tournament from an earlier failed start.
  delete from public.tournaments
  where room_id = p_room_id;

  insert into public.tournaments(
    room_id,
    stage_number,
    best_of,
    status
  )
  values(
    p_room_id,
    1,
    room_record.best_of,
    'active'
  )
  returning * into tour;

  update public.room_players
  set eliminated = false
  where room_id = p_room_id;

  perform public.build_tournament_stage(tour.id, 1);

  update public.rooms
  set status = 'playing'
  where id = p_room_id;

  return jsonb_build_object(
    'tournament_id', tour.id,
    'stage_number', 1,
    'resumed', false
  );
end;
$$;

grant execute on function public.start_tournament(uuid) to authenticated;

select 'PICK & SHOOT start tournament repair complete' as status;
