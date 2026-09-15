-- Pick & Shoot — start_tournament hard fix
-- Replaces only the start RPC. It does not change room/player/custom-rule tables.

-- Remove every existing UUID overload so the new parameter name/body is unambiguous.
drop function if exists public.start_tournament(uuid);

create or replace function public.start_tournament(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  room_record record;
  existing_tournament record;
  tour record;
  human_ids uuid[];
  n integer;
  i integer := 1;
  pair_index integer := 1;
  randomizer_human uuid;
  opponent_id uuid;
  pairing_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select r.* into room_record
  from public.rooms r
  where r.id = p_room_id
  for update;

  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  if room_record.host_user_id <> auth.uid() then
    raise exception 'HOST_ONLY';
  end if;

  select t.* into existing_tournament
  from public.tournaments t
  where t.room_id = p_room_id
  order by t.created_at desc
  limit 1;

  -- Idempotent recovery: if the room is already playing, return the active tournament.
  if room_record.status = 'playing' and existing_tournament.id is not null then
    return jsonb_build_object(
      'tournament_id', existing_tournament.id,
      'stage_number', existing_tournament.stage_number,
      'resumed', true
    );
  end if;

  -- A stale playing flag without a tournament can be safely repaired.
  if room_record.status = 'playing' and existing_tournament.id is null then
    update public.rooms set status = 'waiting' where id = p_room_id;
  end if;

  select array_agg(rp.user_id order by rp.joined_at, rp.user_id), count(*)
  into human_ids, n
  from public.room_players rp
  where rp.room_id = p_room_id
    and coalesce(rp.eliminated, false) = false;

  if coalesce(n, 0) < 2 then
    raise exception 'NOT_ENOUGH_PLAYERS';
  end if;

  -- Clear any incomplete tournament belonging to this room.
  delete from public.tournaments where room_id = p_room_id;

  insert into public.tournaments(room_id, stage_number, best_of, status)
  values(p_room_id, 1, room_record.best_of, 'active')
  returning * into tour;

  -- Reset player elimination flags before building the opening stage.
  update public.room_players
  set eliminated = false
  where room_id = p_room_id;

  -- Odd human counts: select ONE real human to face the temporary Randomizer.
  -- That human is removed from the ordinary-human pairing pool for this stage.
  if mod(n, 2) = 1 then
    randomizer_human := human_ids[n];

    insert into public.tournament_pairings(
      tournament_id, stage_number, pair_index,
      player_a_id, player_b_id, against_randomizer, status
    )
    values(
      tour.id, 1, pair_index,
      randomizer_human, null, true, 'active'
    )
    returning id into pairing_id;

    insert into public.tournament_rounds(
      pairing_id, round_number, phase, pick_deadline
    )
    values(pairing_id, 1, 'picking', now() + interval '5 seconds');

    pair_index := pair_index + 1;
    n := n - 1;
  end if;

  -- Pair the remaining humans exactly once for this stage.
  i := 1;
  while i <= n loop
    opponent_id := human_ids[i + 1];

    -- If the temporary Randomizer human was selected above, the last array element
    -- is already outside the loop because n was reduced by one.
    insert into public.tournament_pairings(
      tournament_id, stage_number, pair_index,
      player_a_id, player_b_id, against_randomizer, status
    )
    values(
      tour.id, 1, pair_index,
      human_ids[i], opponent_id, false, 'active'
    )
    returning id into pairing_id;

    insert into public.tournament_rounds(
      pairing_id, round_number, phase, pick_deadline
    )
    values(pairing_id, 1, 'picking', now() + interval '5 seconds');

    pair_index := pair_index + 1;
    i := i + 2;
  end loop;

  -- Only expose the match after the whole opening stage has been persisted.
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

select 'PICK & SHOOT start_tournament hard fix installed' as status;
