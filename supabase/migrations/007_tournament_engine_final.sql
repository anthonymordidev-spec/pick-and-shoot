-- Pick & Shoot: authoritative, stage-synchronised tournament engine.
-- Idempotent repair for an existing database. Run after 001-004 and any
-- previous tournament repair scripts. This migration recreates the tournament
-- RPCs around the agreed rules without changing room/player data.

create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade unique,
  stage_number integer not null default 1,
  best_of integer not null check (best_of in (1,3,5)),
  status text not null default 'active' check (status in ('active','finished')),
  champion_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.tournament_pairings (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  stage_number integer not null,
  pair_index integer not null,
  player_a_id uuid references auth.users(id) on delete set null,
  player_b_id uuid references auth.users(id) on delete set null,
  against_randomizer boolean not null default false,
  status text not null default 'active' check (status in ('active','finished')),
  winner_user_id uuid references auth.users(id) on delete set null,
  randomizer_won boolean not null default false,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  unique(tournament_id, stage_number, pair_index)
);

create table if not exists public.tournament_rounds (
  id uuid primary key default gen_random_uuid(),
  pairing_id uuid not null references public.tournament_pairings(id) on delete cascade,
  round_number integer not null,
  phase text not null default 'picking' check (phase in ('picking','finished')),
  pick_deadline timestamptz not null,
  winner_user_id uuid references auth.users(id) on delete set null,
  randomizer_won boolean not null default false,
  resolved_choices jsonb,
  resolved_at timestamptz,
  unique(pairing_id, round_number)
);

create table if not exists public.tournament_choices (
  round_id uuid not null references public.tournament_rounds(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  choice text not null check (char_length(choice) between 1 and 64),
  submitted_at timestamptz not null default now(),
  primary key(round_id, user_id)
);

alter table public.tournament_rounds add column if not exists randomizer_won boolean not null default false;
alter table public.rooms add column if not exists custom_rules jsonb;

alter table public.tournaments enable row level security;
alter table public.tournament_pairings enable row level security;
alter table public.tournament_rounds enable row level security;
alter table public.tournament_choices enable row level security;

drop policy if exists tournament_read on public.tournaments;
create policy tournament_read on public.tournaments for select to authenticated
using (public.is_room_member(room_id));

drop policy if exists tournament_pairing_read on public.tournament_pairings;
create policy tournament_pairing_read on public.tournament_pairings for select to authenticated
using (exists(select 1 from public.tournaments t where t.id = tournament_id and public.is_room_member(t.room_id)));

drop policy if exists tournament_round_read on public.tournament_rounds;
create policy tournament_round_read on public.tournament_rounds for select to authenticated
using (exists(select 1 from public.tournament_pairings p join public.tournaments t on t.id = p.tournament_id where p.id = pairing_id and public.is_room_member(t.room_id)));

drop policy if exists tournament_choice_read on public.tournament_choices;
create policy tournament_choice_read on public.tournament_choices for select to authenticated
using (user_id = auth.uid());

-- Realtime publication: explicit and resilient.
do $$
begin
  begin
    alter publication supabase_realtime add table public.tournaments;
  exception when duplicate_object then
    null;
  end;

  begin
    alter publication supabase_realtime add table public.tournament_pairings;
  exception when duplicate_object then
    null;
  end;

  begin
    alter publication supabase_realtime add table public.tournament_rounds;
  exception when duplicate_object then
    null;
  end;

  begin
    alter publication supabase_realtime add table public.room_players;
  exception when duplicate_object then
    null;
  end;

  begin
    alter publication supabase_realtime add table public.rooms;
  exception when duplicate_object then
    null;
  end;
end $$;

-- Return a deterministic random choice from the room's actual rules.
create or replace function public.random_tournament_choice(p_room_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  room_record public.rooms;
  choices text[];
  chosen text;
begin
  select * into room_record from public.rooms where id=p_room_id;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if room_record.ruleset='custom' and room_record.custom_rules is not null then
    select array_agg(value->>'id' order by value->>'id') into choices
    from jsonb_array_elements(room_record.custom_rules->'items');
  else
    choices := array['rock','paper','scissors'];
  end if;
  if choices is null or array_length(choices,1)=0 then raise exception 'INVALID_RULES'; end if;
  chosen := choices[1 + floor(random()*array_length(choices,1))::int];
  return chosen;
end;
$$;
grant execute on function public.random_tournament_choice(uuid) to authenticated;

-- Build one synchronized stage. Odd human counts get exactly one temporary
-- Randomizer matchup. The randomizer never enters the survivor list.
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
  pairing_id uuid;
begin
  select * into tour from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'TOURNAMENT_NOT_FOUND'; end if;

  delete from public.tournament_rounds
  where pairing_id in (select id from public.tournament_pairings where tournament_id=p_tournament_id and stage_number=p_stage_number);
  delete from public.tournament_pairings where tournament_id=p_tournament_id and stage_number=p_stage_number;

  select array_agg(rp.user_id order by rp.joined_at, rp.user_id), count(*)
  into all_ids, n
  from public.room_players rp
  where rp.room_id=tour.room_id and rp.eliminated=false;

  if coalesce(n,0) < 1 then raise exception 'NO_HUMANS_REMAIN'; end if;

  if mod(n,2)=1 then
    randomizer_id := all_ids[1 + floor(random()*n)::int];
    select array_agg(rp.user_id order by rp.joined_at, rp.user_id), count(*)
    into human_ids, normal_n
    from public.room_players rp
    where rp.room_id=tour.room_id and rp.eliminated=false and rp.user_id<>randomizer_id;

    insert into public.tournament_pairings(
      tournament_id, stage_number, pair_index, player_a_id, player_b_id, against_randomizer
    ) values (
      p_tournament_id, p_stage_number, pair_no, randomizer_id, null, true
    ) returning id into pairing_id;
    insert into public.tournament_rounds(pairing_id, round_number, phase, pick_deadline)
    values(pairing_id,1,'picking',now()+interval '5 seconds');
    pair_no := pair_no + 1;
  else
    human_ids := all_ids;
    normal_n := n;
  end if;

  idx := 1;
  while idx <= coalesce(normal_n,0) loop
    if idx + 1 > normal_n then
      raise exception 'PAIRING_BUILD_FAILED';
    end if;

    insert into public.tournament_pairings(
      tournament_id, stage_number, pair_index, player_a_id, player_b_id, against_randomizer
    ) values (
      p_tournament_id, p_stage_number, pair_no, human_ids[idx], human_ids[idx+1], false
    ) returning id into pairing_id;

    insert into public.tournament_rounds(pairing_id, round_number, phase, pick_deadline)
    values(pairing_id,1,'picking',now()+interval '5 seconds');

    pair_no := pair_no + 1;
    idx := idx + 2;
  end loop;

  return pair_no-1;
end;
$$;
grant execute on function public.build_tournament_stage(uuid,integer) to authenticated;

create or replace function public.start_tournament(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  room_record public.rooms;
  human_count integer;
  tour public.tournaments;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into room_record from public.rooms where id=p_room_id for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if room_record.host_user_id <> auth.uid() then raise exception 'HOST_ONLY'; end if;
  if room_record.status <> 'waiting' then raise exception 'ROOM_ALREADY_STARTED'; end if;
  select count(*) into human_count from public.room_players where room_id=p_room_id and eliminated=false;
  if human_count < 2 then raise exception 'NOT_ENOUGH_PLAYERS'; end if;

  delete from public.tournaments where room_id=p_room_id;
  insert into public.tournaments(room_id,stage_number,best_of,status)
  values(p_room_id,1,room_record.best_of,'active') returning * into tour;

  update public.room_players set eliminated=false where room_id=p_room_id;
  perform public.build_tournament_stage(tour.id,1);
  update public.rooms set status='playing' where id=p_room_id;
  return jsonb_build_object('tournament_id',tour.id,'stage_number',1);
end;
$$;
grant execute on function public.start_tournament(uuid) to authenticated;

create or replace function public.submit_tournament_choice(p_round_id uuid,p_choice text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rr record;
  pairing record;
  room_id_value uuid;
  valid boolean := false;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select tr.*,tp.player_a_id,tp.player_b_id,tp.against_randomizer,tp.status as pairing_status
  into rr
  from public.tournament_rounds tr
  join public.tournament_pairings tp on tp.id=tr.pairing_id
  where tr.id=p_round_id
  for update;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;

  select t.room_id into room_id_value
  from public.tournaments t
  join public.tournament_pairings tp on tp.tournament_id=t.id
  where tp.id=rr.pairing_id;
  if not public.is_room_member(room_id_value) then raise exception 'NOT_IN_ROOM'; end if;
  if auth.uid()<>rr.player_a_id and (rr.player_b_id is null or auth.uid()<>rr.player_b_id) then raise exception 'NOT_YOUR_MATCH'; end if;
  if rr.phase<>'picking' or rr.pairing_status<>'active' then return jsonb_build_object('accepted',false,'resolved',true); end if;
  if now()>rr.pick_deadline then return jsonb_build_object('accepted',false,'resolved',false,'expired',true); end if;

  if exists(select 1 from public.rooms r where r.id=room_id_value and r.ruleset='custom') then
    select exists(select 1 from jsonb_array_elements((select custom_rules from public.rooms where id=room_id_value)->'items') x where x->>'id'=p_choice) into valid;
  else
    valid := p_choice in ('rock','paper','scissors');
  end if;
  if not valid then raise exception 'INVALID_CHOICE'; end if;

  insert into public.tournament_choices(round_id,user_id,choice)
  values(p_round_id,auth.uid(),p_choice)
  on conflict(round_id,user_id) do update set choice=excluded.choice,submitted_at=now();

  return jsonb_build_object('accepted',true,'resolved',false);
end;
$$;
grant execute on function public.submit_tournament_choice(uuid,text) to authenticated;

create or replace function public.resolve_tournament_round(p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rr record;
  tp record;
  room_record public.rooms;
  a_choice text;
  b_choice text;
  random_choice text;
  winner uuid;
  randomizer_wins boolean := false;
  choices jsonb;
  beats jsonb;
  choice_count integer;
  now_value timestamptz := now();
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select tr.*,t.room_id
  into rr
  from public.tournament_rounds tr
  join public.tournament_pairings tp0 on tp0.id=tr.pairing_id
  join public.tournaments t on t.id=tp0.tournament_id
  where tr.id=p_round_id
  for update;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  if not public.is_room_member(rr.room_id) then raise exception 'NOT_IN_ROOM'; end if;

  select p.* into tp from public.tournament_pairings p where p.id=rr.pairing_id for update;
  select * into room_record from public.rooms where id=rr.room_id;

  if rr.phase='finished' then
    return jsonb_build_object('resolved',true,'phase','finished','winner_user_id',rr.winner_user_id,'choices',rr.resolved_choices,'randomizer_won',rr.randomizer_won);
  end if;

  select count(*) into choice_count from public.tournament_choices where round_id=rr.id;
  if tp.player_b_id is not null and choice_count < 2 and now_value < rr.pick_deadline then
    return jsonb_build_object('resolved',false,'phase','picking');
  end if;
  if tp.player_b_id is null and choice_count < 1 and now_value < rr.pick_deadline then
    return jsonb_build_object('resolved',false,'phase','picking');
  end if;

  select choice into a_choice from public.tournament_choices where round_id=rr.id and user_id=tp.player_a_id;
  if a_choice is null then a_choice := public.random_tournament_choice(rr.room_id); end if;

  if tp.against_randomizer then
    b_choice := public.random_tournament_choice(rr.room_id);
    choices := jsonb_build_object(tp.player_a_id::text,a_choice,'randomizer',b_choice);
  else
    select choice into b_choice from public.tournament_choices where round_id=rr.id and user_id=tp.player_b_id;
    if b_choice is null then b_choice := public.random_tournament_choice(rr.room_id); end if;
    choices := jsonb_build_object(tp.player_a_id::text,a_choice,tp.player_b_id::text,b_choice);
  end if;

  if room_record.ruleset='custom' and room_record.custom_rules is not null then
    beats := room_record.custom_rules->'beats';
  else
    beats := '{"rock":["scissors"],"paper":["rock"],"scissors":["paper"]}'::jsonb;
  end if;

  if a_choice=b_choice then
    winner := null;
  elsif coalesce(beats->a_choice,'[]'::jsonb) ? b_choice then
    winner := tp.player_a_id;
  else
    if tp.against_randomizer then
      winner := null;
      randomizer_wins := true;
    else
      winner := tp.player_b_id;
    end if;
  end if;

  update public.tournament_rounds
  set phase='finished',winner_user_id=winner,randomizer_won=randomizer_wins,resolved_choices=choices,resolved_at=now_value
  where id=rr.id;

  return jsonb_build_object('resolved',true,'phase','finished','winner_user_id',winner,'choices',choices,'randomizer_won',randomizer_wins,'resolved_at',now_value);
end;
$$;
grant execute on function public.resolve_tournament_round(uuid) to authenticated;

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
      values(p.id,r.round_number+1,'picking',now()+interval '5 seconds');
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
      values(p.id,r.round_number+1,'picking',now()+interval '5 seconds');
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

create or replace function public.advance_tournament_stage(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  winner_count integer;
  champion uuid;
begin
  if auth.uid() is null or not public.is_room_member(p_room_id) then raise exception 'NOT_IN_ROOM'; end if;
  select * into t from public.tournaments where room_id=p_room_id for update;
  if not found then raise exception 'TOURNAMENT_NOT_FOUND'; end if;
  if t.status='finished' then return jsonb_build_object('advanced',false,'finished',true,'stage_number',t.stage_number,'champion_user_id',t.champion_user_id); end if;

  if exists(select 1 from public.tournament_pairings p where p.tournament_id=t.id and p.stage_number=t.stage_number and p.status<>'finished') then
    return jsonb_build_object('advanced',false,'finished',false,'stage_number',t.stage_number);
  end if;

  select count(*) into winner_count from public.room_players where room_id=p_room_id and eliminated=false;
  if winner_count=0 then raise exception 'NO_HUMANS_REMAIN'; end if;

  if winner_count=1 then
    select user_id into champion from public.room_players where room_id=p_room_id and eliminated=false limit 1;
    update public.tournaments set status='finished',champion_user_id=champion where id=t.id;
    update public.rooms set status='finished' where id=p_room_id;
    return jsonb_build_object('advanced',false,'finished',true,'stage_number',t.stage_number,'champion_user_id',champion);
  end if;

  update public.tournaments set stage_number=t.stage_number+1 where id=t.id;
  perform public.build_tournament_stage(t.id,t.stage_number+1);
  return jsonb_build_object('advanced',true,'finished',false,'stage_number',t.stage_number+1);
end;
$$;
grant execute on function public.advance_tournament_stage(uuid) to authenticated;

create or replace function public.get_tournament_state(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  your_id uuid := auth.uid();
  human_count integer;
  pairings jsonb;
  your_pairing uuid;
  current_round uuid;
  current_submitted boolean := false;
begin
  if auth.uid() is null or not public.is_room_member(p_room_id) then raise exception 'NOT_IN_ROOM'; end if;
  select * into t from public.tournaments where room_id=p_room_id;
  if not found then raise exception 'TOURNAMENT_NOT_FOUND'; end if;

  select count(*) into human_count from public.room_players where room_id=p_room_id and eliminated=false;

  select jsonb_agg(
    jsonb_build_object(
      'id',p.id,
      'pairIndex',p.pair_index,
      'playerA',jsonb_build_object('id',pa.user_id,'name',pa.display_name),
      'playerB',case when p.player_b_id is null then null else jsonb_build_object('id',pb.user_id,'name',pb.display_name) end,
      'againstRandomizer',p.against_randomizer,
      'status',p.status,
      'winnerUserId',p.winner_user_id,
      'randomizerWon',p.randomizer_won,
      'roundNumber',r.round_number,
      'roundId',r.id,
      'roundPhase',r.phase,
      'pickDeadline',r.pick_deadline,
      'resolvedChoices',case when r.phase='finished' then r.resolved_choices else null end,
      'roundWinnerUserId',r.winner_user_id,
      'roundRandomizerWon',case when r.phase='finished' then r.randomizer_won else false end,
      'scoreA',(select count(*) from public.tournament_rounds x where x.pairing_id=p.id and x.phase='finished' and x.winner_user_id=p.player_a_id),
      'scoreB',case when p.against_randomizer then (select count(*) from public.tournament_rounds x where x.pairing_id=p.id and x.phase='finished' and x.randomizer_won=true) else (select count(*) from public.tournament_rounds x where x.pairing_id=p.id and x.phase='finished' and x.winner_user_id=p.player_b_id) end
    ) order by p.pair_index
  ) into pairings
  from public.tournament_pairings p
  join public.room_players pa on pa.room_id=p_room_id and pa.user_id=p.player_a_id
  left join public.room_players pb on pb.room_id=p_room_id and pb.user_id=p.player_b_id
  left join lateral(select * from public.tournament_rounds x where x.pairing_id=p.id order by x.round_number desc limit 1) r on true
  where p.tournament_id=t.id and p.stage_number=t.stage_number;

  select p.id,r.id into your_pairing,current_round
  from public.tournament_pairings p
  left join lateral(select id from public.tournament_rounds x where x.pairing_id=p.id order by x.round_number desc limit 1) r on true
  where p.tournament_id=t.id and p.stage_number=t.stage_number
    and (p.player_a_id=your_id or p.player_b_id=your_id);

  if current_round is not null then
    select exists(select 1 from public.tournament_choices c where c.round_id=current_round and c.user_id=your_id) into current_submitted;
  end if;

  return jsonb_build_object(
    'tournamentId',t.id,
    'stageNumber',t.stage_number,
    'status',t.status,
    'championUserId',t.champion_user_id,
    'bestOf',t.best_of,
    'humanCount',human_count,
    'stageComplete',not exists(select 1 from public.tournament_pairings tp where tp.tournament_id=t.id and tp.stage_number=t.stage_number and tp.status<>'finished'),
    'pairings',coalesce(pairings,'[]'::jsonb),
    'yourPairingId',your_pairing,
    'currentRoundId',current_round,
    'currentUserSubmitted',current_submitted
  );
end;
$$;
grant execute on function public.get_tournament_state(uuid) to authenticated;

-- Backward compatibility: old UI/client function names still work.
create or replace function public.advance_tournament_pairing_legacy(p_pairing_id uuid)
returns jsonb
language sql
security definer
set search_path=public
as $$ select public.advance_tournament_pairing(p_pairing_id); $$;
