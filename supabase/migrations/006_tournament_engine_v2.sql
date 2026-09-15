-- Pick & Shoot: authoritative, synchronized multi-player tournament engine v2.
-- Run after the existing room/custom-rule migrations. Safe to re-run.

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

alter table public.tournaments enable row level security;
alter table public.tournament_pairings enable row level security;
alter table public.tournament_rounds enable row level security;
alter table public.tournament_choices enable row level security;

drop policy if exists tournament_read on public.tournaments;
create policy tournament_read on public.tournaments for select to authenticated using (public.is_room_member(room_id));
drop policy if exists tournament_pairing_read on public.tournament_pairings;
create policy tournament_pairing_read on public.tournament_pairings for select to authenticated using (exists(select 1 from public.tournaments t where t.id=tournament_id and public.is_room_member(t.room_id)));
drop policy if exists tournament_round_read on public.tournament_rounds;
create policy tournament_round_read on public.tournament_rounds for select to authenticated using (exists(select 1 from public.tournament_pairings p join public.tournaments t on t.id=p.tournament_id where p.id=pairing_id and public.is_room_member(t.room_id)));
drop policy if exists tournament_choice_owner_read on public.tournament_choices;
create policy tournament_choice_owner_read on public.tournament_choices for select to authenticated using (user_id=auth.uid());

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tournaments') then alter publication supabase_realtime add table public.tournaments; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tournament_pairings') then alter publication supabase_realtime add table public.tournament_pairings; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tournament_rounds') then alter publication supabase_realtime add table public.tournament_rounds; end if;
end $$;

create or replace function public._pns_rules_for_room(p_room_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
  select case when ruleset='custom' then custom_rules else jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('id','rock','label','Rock','glyph','✊'),
    jsonb_build_object('id','paper','label','Paper','glyph','✋'),
    jsonb_build_object('id','scissors','label','Scissors','glyph','✌')
  ), 'beats', jsonb_build_object('rock',jsonb_build_array('scissors'),'paper',jsonb_build_array('rock'),'scissors',jsonb_build_array('paper'))) end
  from public.rooms where id=p_room_id;
$$;


create or replace function public._pns_valid_choice(p_room_id uuid, p_choice text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare r jsonb; item_id text;
begin
  r:=public._pns_rules_for_room(p_room_id);
  if r is null or jsonb_typeof(r->'items')<>'array' then return false; end if;
  for item_id in select value->>'id' from jsonb_array_elements(r->'items') loop if item_id=p_choice then return true; end if; end loop;
  return false;
end; $$;

create or replace function public.start_tournament(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare room_row public.rooms; t public.tournaments; human_ids uuid[]; i integer; idx integer:=0; p1 uuid; pairing_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into room_row from public.rooms where id=p_room_id for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if room_row.host_user_id<>auth.uid() then raise exception 'HOST_ONLY'; end if;
  if room_row.status<>'waiting' then raise exception 'ROOM_ALREADY_STARTED'; end if;
  select array_agg(user_id order by random()) into human_ids from public.room_players where room_id=p_room_id and eliminated=false;
  if coalesce(array_length(human_ids,1),0)<2 then raise exception 'NOT_ENOUGH_PLAYERS'; end if;
  if exists(select 1 from public.tournaments where room_id=p_room_id) then raise exception 'TOURNAMENT_ALREADY_STARTED'; end if;
  insert into public.tournaments(room_id,stage_number,best_of,status) values(p_room_id,1,room_row.best_of,'active') returning * into t;
  for i in 1..array_length(human_ids,1) loop
    if p1 is null then p1:=human_ids[i];
    else
      idx:=idx+1;
      insert into public.tournament_pairings(tournament_id,stage_number,pair_index,player_a_id,player_b_id,against_randomizer)
      values(t.id,1,idx,p1,human_ids[i],false) returning id into pairing_id;
      insert into public.tournament_rounds(pairing_id,round_number,phase,pick_deadline) values(pairing_id,1,'picking',now()+interval '5 seconds');
      p1:=null;
    end if;
  end loop;
  if p1 is not null then
    idx:=idx+1;
    insert into public.tournament_pairings(tournament_id,stage_number,pair_index,player_a_id,player_b_id,against_randomizer)
    values(t.id,1,idx,p1,null,true) returning id into pairing_id;
    insert into public.tournament_rounds(pairing_id,round_number,phase,pick_deadline) values(pairing_id,1,'picking',now()+interval '5 seconds');
  end if;
  update public.rooms set status='playing' where id=p_room_id;
  return jsonb_build_object('tournament_id',t.id,'stage_number',1);
end; $$;
grant execute on function public.start_tournament(uuid) to authenticated;

create or replace function public.submit_tournament_choice(p_round_id uuid,p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.tournament_rounds; p public.tournament_pairings; t public.tournaments;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into r from public.tournament_rounds where id=p_round_id for update; if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  select * into p from public.tournament_pairings where id=r.pairing_id; select * into t from public.tournaments where id=p.tournament_id;
  if auth.uid()<>p.player_a_id and auth.uid()<>p.player_b_id then raise exception 'NOT_IN_MATCH'; end if;
  if not public._pns_valid_choice(t.room_id,p_choice) then raise exception 'INVALID_CHOICE'; end if;
  if r.phase<>'picking' or now()>r.pick_deadline then return jsonb_build_object('accepted',false,'resolved',false); end if;
  insert into public.tournament_choices(round_id,user_id,choice) values(r.id,auth.uid(),p_choice)
  on conflict(round_id,user_id) do update set choice=excluded.choice,submitted_at=now();
  return jsonb_build_object('accepted',true,'resolved',false);
end; $$;
grant execute on function public.submit_tournament_choice(uuid,text) to authenticated;

create or replace function public.resolve_tournament_round(p_round_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.tournament_rounds; p public.tournament_pairings; t public.tournaments; rules jsonb; options text[]; c1 text; c2 text; winner uuid; randomizer_won_round boolean:=false; choice_count integer; target integer; score_human integer; score_randomizer integer; now_ts timestamptz;
begin
  now_ts:=now();
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into r from public.tournament_rounds where id=p_round_id for update; if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  select * into p from public.tournament_pairings where id=r.pairing_id for update; select * into t from public.tournaments where id=p.tournament_id;
  if not public.is_room_member(t.room_id) then raise exception 'NOT_IN_ROOM'; end if;
  if r.phase='finished' then return jsonb_build_object('resolved',true,'phase','finished','winner_user_id',r.winner_user_id,'randomizer_won',r.randomizer_won,'choices',r.resolved_choices); end if;
  select count(*) into choice_count from public.tournament_choices where round_id=r.id;
  if (p.against_randomizer and choice_count<1 and now_ts<r.pick_deadline) or (not p.against_randomizer and choice_count<2 and now_ts<r.pick_deadline) then
    return jsonb_build_object('resolved',false,'phase','picking');
  end if;
  rules:=public._pns_rules_for_room(t.room_id);
  select array_agg(value->>'id') into options from jsonb_array_elements(rules->'items');
  select choice into c1 from public.tournament_choices where round_id=r.id and user_id=p.player_a_id;
  if c1 is null then c1:=options[1+floor(random()*array_length(options,1))::int]; end if;
  if p.against_randomizer then
    c2:=options[1+floor(random()*array_length(options,1))::int];
    if c1<>c2 and not (coalesce(rules->'beats'->c1,'[]'::jsonb) ? c2) then randomizer_won_round:=true; end if;
  else
    select choice into c2 from public.tournament_choices where round_id=r.id and user_id=p.player_b_id;
    if c2 is null then c2:=options[1+floor(random()*array_length(options,1))::int]; end if;
    if c1<>c2 and (coalesce(rules->'beats'->c1,'[]'::jsonb) ? c2) then winner:=p.player_a_id;
    elsif c1<>c2 then winner:=p.player_b_id; end if;
  end if;
  update public.tournament_rounds
  set phase='finished',winner_user_id=winner,randomizer_won=randomizer_won_round,
      resolved_choices=jsonb_build_object(p.player_a_id::text,c1,coalesce(p.player_b_id,'00000000-0000-0000-0000-000000000000')::text,c2),resolved_at=now_ts
  where id=r.id;
  target:=ceil(t.best_of::numeric/2)::int;
  select count(*) into score_human from public.tournament_rounds where pairing_id=p.id and phase='finished' and winner_user_id=p.player_a_id;
  select count(*) into score_randomizer from public.tournament_rounds where pairing_id=p.id and phase='finished' and randomizer_won=true;
  if score_human>=target then
    update public.tournament_pairings set status='finished',winner_user_id=p.player_a_id,randomizer_won=false,finished_at=now_ts where id=p.id;
  elsif p.against_randomizer and score_randomizer>=target then
    update public.tournament_pairings set status='finished',winner_user_id=null,randomizer_won=true,finished_at=now_ts where id=p.id;
  elsif not p.against_randomizer and exists(select 1 from public.tournament_rounds where pairing_id=p.id and phase='finished' and winner_user_id=p.player_b_id and (select count(*) from public.tournament_rounds rr where rr.pairing_id=p.id and rr.phase='finished' and rr.winner_user_id=p.player_b_id)>=target) then
    update public.tournament_pairings set status='finished',winner_user_id=p.player_b_id,randomizer_won=false,finished_at=now_ts where id=p.id;
  end if;
  return jsonb_build_object('resolved',true,'phase','finished','winner_user_id',winner,'randomizer_won',randomizer_won_round,'choices',jsonb_build_object(p.player_a_id::text,c1,coalesce(p.player_b_id,'00000000-0000-0000-0000-000000000000')::text,c2));
end; $$;
grant execute on function public.resolve_tournament_round(uuid) to authenticated;

create or replace function public.advance_tournament_pairing(p_pairing_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.tournament_pairings; r public.tournament_rounds; t public.tournaments;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into p from public.tournament_pairings where id=p_pairing_id for update; if not found then raise exception 'PAIRING_NOT_FOUND'; end if;
  select * into t from public.tournaments where id=p.tournament_id;
  if not public.is_room_member(t.room_id) then raise exception 'NOT_IN_ROOM'; end if;
  if p.status='finished' then return jsonb_build_object('advanced',false,'finished',true); end if;
  select * into r from public.tournament_rounds where pairing_id=p.id order by round_number desc limit 1;
  if not found or r.phase<>'finished' then return jsonb_build_object('advanced',false,'finished',false); end if;
  if exists(select 1 from public.tournament_rounds where pairing_id=p.id and phase='picking') then return jsonb_build_object('advanced',false,'finished',false); end if;
  insert into public.tournament_rounds(pairing_id,round_number,phase,pick_deadline) values(p.id,r.round_number+1,'picking',now()+interval '5 seconds');
  return jsonb_build_object('advanced',true,'finished',false);
end; $$;
grant execute on function public.advance_tournament_pairing(uuid) to authenticated;

create or replace function public.advance_tournament_stage(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.tournaments; survivors uuid[]; survivor uuid; idx integer:=0; p1 uuid; pairing_id uuid; human_count integer; next_stage integer;
begin
  if auth.uid() is null or not public.is_room_member(p_room_id) then raise exception 'NOT_IN_ROOM'; end if;
  select * into t from public.tournaments where room_id=p_room_id for update; if not found then raise exception 'TOURNAMENT_NOT_FOUND'; end if;
  if t.status='finished' then return jsonb_build_object('advanced',false,'finished',true,'stage_number',t.stage_number,'champion_user_id',t.champion_user_id); end if;
  if exists(select 1 from public.tournament_pairings where tournament_id=t.id and stage_number=t.stage_number and status<>'finished') then return jsonb_build_object('advanced',false,'finished',false,'stage_number',t.stage_number); end if;
  select array_agg(winner_user_id order by pair_index) into survivors from public.tournament_pairings where tournament_id=t.id and stage_number=t.stage_number and winner_user_id is not null;
  human_count:=coalesce(array_length(survivors,1),0);
  if human_count<=1 then
    update public.tournaments set status='finished',champion_user_id=survivors[1] where id=t.id;
    update public.rooms set status='finished' where id=p_room_id;
    return jsonb_build_object('advanced',false,'finished',true,'stage_number',t.stage_number,'champion_user_id',survivors[1]);
  end if;
  next_stage:=t.stage_number+1;
  if exists(select 1 from public.tournament_pairings where tournament_id=t.id and stage_number=next_stage) then update public.tournaments set stage_number=next_stage where id=t.id; return jsonb_build_object('advanced',true,'finished',false,'stage_number',next_stage); end if;
  update public.tournaments set stage_number=next_stage where id=t.id;
  foreach survivor in array survivors loop
    if p1 is null then p1:=survivor; continue; end if;
    idx:=idx+1;
    insert into public.tournament_pairings(tournament_id,stage_number,pair_index,player_a_id,player_b_id,against_randomizer) values(t.id,next_stage,idx,p1,survivor,false) returning id into pairing_id;
    insert into public.tournament_rounds(pairing_id,round_number,phase,pick_deadline) values(pairing_id,1,'picking',now()+interval '5 seconds');
    p1:=null;
  end loop;
  if p1 is not null then
    idx:=idx+1;
    insert into public.tournament_pairings(tournament_id,stage_number,pair_index,player_a_id,player_b_id,against_randomizer) values(t.id,next_stage,idx,p1,null,true) returning id into pairing_id;
    insert into public.tournament_rounds(pairing_id,round_number,phase,pick_deadline) values(pairing_id,1,'picking',now()+interval '5 seconds');
  end if;
  return jsonb_build_object('advanced',true,'finished',false,'stage_number',next_stage);
end; $$;
grant execute on function public.advance_tournament_stage(uuid) to authenticated;

create or replace function public.get_tournament_state(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t public.tournaments; human_count integer; pairings jsonb; your_id uuid:=auth.uid(); your_pairing uuid; current_round uuid;
begin
  if auth.uid() is null or not public.is_room_member(p_room_id) then raise exception 'NOT_IN_ROOM'; end if;
  select * into t from public.tournaments where room_id=p_room_id; if not found then raise exception 'TOURNAMENT_NOT_FOUND'; end if;
  select count(*) into human_count from (
    select p.player_a_id as user_id from public.tournament_pairings p where p.tournament_id=t.id and p.stage_number=t.stage_number
    union
    select p.player_b_id as user_id from public.tournament_pairings p where p.tournament_id=t.id and p.stage_number=t.stage_number and p.player_b_id is not null
  ) active_humans;
  select jsonb_agg(jsonb_build_object(
    'id',p.id,'pairIndex',p.pair_index,
    'playerA',jsonb_build_object('id',pa.user_id,'name',pa.display_name),
    'playerB',case when p.player_b_id is null then null else jsonb_build_object('id',pb.user_id,'name',pb.display_name) end,
    'againstRandomizer',p.against_randomizer,'status',p.status,'winnerUserId',p.winner_user_id,'randomizerWon',p.randomizer_won,
    'roundNumber',r.round_number,'roundId',r.id,'roundPhase',r.phase,'pickDeadline',r.pick_deadline,
    'resolvedChoices',r.resolved_choices,'roundWinnerUserId',r.winner_user_id,'roundRandomizerWon',r.randomizer_won,
    'scoreA',(select count(*) from public.tournament_rounds rr where rr.pairing_id=p.id and rr.phase='finished' and rr.winner_user_id=p.player_a_id),
    'scoreB',case when p.against_randomizer then (select count(*) from public.tournament_rounds rr where rr.pairing_id=p.id and rr.phase='finished' and rr.randomizer_won=true) else (select count(*) from public.tournament_rounds rr where rr.pairing_id=p.id and rr.phase='finished' and rr.winner_user_id=p.player_b_id) end
  ) order by p.pair_index) into pairings
  from public.tournament_pairings p
  join public.room_players pa on pa.user_id=p.player_a_id and pa.room_id=p_room_id
  left join public.room_players pb on pb.user_id=p.player_b_id and pb.room_id=p_room_id
  left join lateral (select * from public.tournament_rounds rr where rr.pairing_id=p.id order by rr.round_number desc limit 1) r on true
  where p.tournament_id=t.id and p.stage_number=t.stage_number;
  select p.id, r.id into your_pairing,current_round from public.tournament_pairings p left join lateral (select id from public.tournament_rounds rr where rr.pairing_id=p.id order by rr.round_number desc limit 1) r on true where p.tournament_id=t.id and p.stage_number=t.stage_number and (p.player_a_id=your_id or p.player_b_id=your_id);
  return jsonb_build_object('tournamentId',t.id,'stageNumber',t.stage_number,'status',t.status,'championUserId',t.champion_user_id,'bestOf',t.best_of,'humanCount',human_count,'stageComplete',not exists(select 1 from public.tournament_pairings where tournament_id=t.id and stage_number=t.stage_number and status<>'finished'),'pairings',coalesce(pairings,'[]'::jsonb),'yourPairingId',your_pairing,'currentRoundId',current_round,'currentUserSubmitted',case when current_round is null then false else exists(select 1 from public.tournament_choices tc where tc.round_id=current_round and tc.user_id=your_id) end);
end; $$;
grant execute on function public.get_tournament_state(uuid) to authenticated;
