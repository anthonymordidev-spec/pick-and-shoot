-- Pick & Shoot: lobby readiness + deliberate pacing
-- Requires the existing tournament tables/functions to already exist.
-- No room, player, or custom-rule data is deleted.

-- Everyone must explicitly be ready before the host can launch.
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
  new_pairing_id uuid;
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

  if room_record.status = 'playing' and existing_tournament.id is not null then
    return jsonb_build_object(
      'tournament_id', existing_tournament.id,
      'stage_number', existing_tournament.stage_number,
      'resumed', true
    );
  end if;

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

  if exists (
    select 1
    from public.room_players rp
    where rp.room_id = p_room_id
      and coalesce(rp.eliminated, false) = false
      and coalesce(rp.is_ready, false) = false
  ) then
    raise exception 'NOT_ALL_READY';
  end if;

  delete from public.tournaments where room_id = p_room_id;

  insert into public.tournaments(room_id, stage_number, best_of, status)
  values(p_room_id, 1, room_record.best_of, 'active')
  returning * into tour;

  update public.room_players
  set eliminated = false
  where room_id = p_room_id;

  -- Build the whole opening stage in one transaction using the corrected function.
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

-- Stage builder: keep a 2-second staging window before each 5-second pick window.
create or replace function public.build_tournament_stage(p_tournament_id uuid, p_stage_number integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  tour record;
  all_ids uuid[];
  human_ids uuid[];
  randomizer_id uuid;
  n integer;
  normal_n integer;
  idx integer := 1;
  pair_no integer := 1;
  new_pairing_id uuid;
begin
  select * into tour
  from public.tournaments
  where id = p_tournament_id
  for update;

  if not found then
    raise exception 'TOURNAMENT_NOT_FOUND';
  end if;

  delete from public.tournament_rounds tr
  where tr.pairing_id in (
    select tp.id
    from public.tournament_pairings tp
    where tp.tournament_id = p_tournament_id
      and tp.stage_number = p_stage_number
  );

  delete from public.tournament_pairings tp
  where tp.tournament_id = p_tournament_id
    and tp.stage_number = p_stage_number;

  select array_agg(rp.user_id order by rp.joined_at, rp.user_id), count(*)
  into all_ids, n
  from public.room_players rp
  where rp.room_id = tour.room_id
    and coalesce(rp.eliminated, false) = false;

  if coalesce(n, 0) < 1 then
    raise exception 'NO_HUMANS_REMAIN';
  end if;

  if mod(n, 2) = 1 then
    randomizer_id := all_ids[1 + floor(random() * n)::int];

    select array_agg(rp.user_id order by rp.joined_at, rp.user_id), count(*)
    into human_ids, normal_n
    from public.room_players rp
    where rp.room_id = tour.room_id
      and coalesce(rp.eliminated, false) = false
      and rp.user_id <> randomizer_id;

    insert into public.tournament_pairings (
      tournament_id, stage_number, pair_index, player_a_id, player_b_id,
      against_randomizer, status
    )
    values (
      p_tournament_id, p_stage_number, pair_no, randomizer_id, null,
      true, 'active'
    )
    returning id into new_pairing_id;

    insert into public.tournament_rounds (
      pairing_id, round_number, phase, pick_deadline
    )
    values (
      new_pairing_id, 1, 'picking', now() + interval '7 seconds'
    );

    pair_no := pair_no + 1;
  else
    human_ids := all_ids;
    normal_n := n;
  end if;

  idx := 1;
  while idx <= coalesce(normal_n, 0) loop
    if idx + 1 > normal_n then
      raise exception 'PAIRING_BUILD_FAILED';
    end if;

    insert into public.tournament_pairings (
      tournament_id, stage_number, pair_index, player_a_id, player_b_id,
      against_randomizer, status
    )
    values (
      p_tournament_id, p_stage_number, pair_no,
      human_ids[idx], human_ids[idx + 1], false, 'active'
    )
    returning id into new_pairing_id;

    insert into public.tournament_rounds (
      pairing_id, round_number, phase, pick_deadline
    )
    values (
      new_pairing_id, 1, 'picking', now() + interval '7 seconds'
    );

    pair_no := pair_no + 1;
    idx := idx + 2;
  end loop;

  return pair_no - 1;
end;
$$;

grant execute on function public.build_tournament_stage(uuid,integer) to authenticated;

-- Pairing advancement: same 2-second staging window between best-of rounds.
create or replace function public.advance_tournament_pairing(p_pairing_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  r record;
  tour record;
  target integer;
  wins_a integer;
  wins_b integer;
  winner uuid;
  randomizer_wins integer;
begin
  select * into p from public.tournament_pairings where id=p_pairing_id for update;
  if not found then raise exception 'PAIRING_NOT_FOUND'; end if;
  select * into tour from public.tournaments where id=p.tournament_id for update;
  if auth.uid() is null or not public.is_room_member(tour.room_id) then raise exception 'NOT_IN_ROOM'; end if;
  if p.status='finished' then return jsonb_build_object('advanced',false,'finished',true); end if;

  select * into r from public.tournament_rounds where pairing_id=p.id order by round_number desc limit 1;
  if not found or r.phase<>'finished' then return jsonb_build_object('advanced',false,'finished',false); end if;
  target := ceil(tour.best_of::numeric/2);

  select count(*) into wins_a from public.tournament_rounds where pairing_id=p.id and phase='finished' and winner_user_id=p.player_a_id;
  if p.player_b_id is null then
    select count(*) into randomizer_wins from public.tournament_rounds where pairing_id=p.id and phase='finished' and randomizer_won=true;
    if wins_a>=target then
      winner := p.player_a_id;
    elsif randomizer_wins>=target then
      winner := null;
      update public.room_players set eliminated=true where room_id=tour.room_id and user_id=p.player_a_id;
      update public.tournament_pairings set status='finished',winner_user_id=null,randomizer_won=true,finished_at=now() where id=p.id;
      return jsonb_build_object('advanced',true,'finished',true,'winner_user_id',null,'randomizer_won',true);
    else
      insert into public.tournament_rounds(pairing_id,round_number,phase,pick_deadline)
      values(p.id,r.round_number+1,'picking',now()+interval '7 seconds');
      return jsonb_build_object('advanced',true,'finished',false,'round_number',r.round_number+1);
    end if;
  else
    select count(*) into wins_b from public.tournament_rounds where pairing_id=p.id and phase='finished' and winner_user_id=p.player_b_id;
    if wins_a>=target then
      winner := p.player_a_id;
    elsif wins_b>=target then
      winner := p.player_b_id;
    else
      insert into public.tournament_rounds(pairing_id,round_number,phase,pick_deadline)
      values(p.id,r.round_number+1,'picking',now()+interval '7 seconds');
      return jsonb_build_object('advanced',true,'finished',false,'round_number',r.round_number+1);
    end if;
  end if;

  update public.tournament_pairings set status='finished',winner_user_id=winner,randomizer_won=false,finished_at=now() where id=p.id;
  if p.player_b_id is null then
    update public.room_players set eliminated=(user_id<>winner) where room_id=tour.room_id and (user_id=p.player_a_id or user_id=winner);
  else
    update public.room_players set eliminated=true where room_id=tour.room_id and user_id in (p.player_a_id,p.player_b_id) and user_id<>winner;
  end if;
  return jsonb_build_object('advanced',true,'finished',true,'winner_user_id',winner);
end;
$$;

grant execute on function public.advance_tournament_pairing(uuid) to authenticated;

select 'PICK & SHOOT readiness and pacing installed' as status;
