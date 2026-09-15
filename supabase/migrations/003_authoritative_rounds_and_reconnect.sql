-- Pick & Shoot: authoritative rounds + reconnect-safe state
-- Run once after 001/002 (and the realtime lobby patch if needed).

alter table public.match_rounds
  add column if not exists resolved_choices jsonb;

-- Match state changes must reach every connected client.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'matches'
  ) then alter publication supabase_realtime add table public.matches; end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'match_rounds'
  ) then alter publication supabase_realtime add table public.match_rounds; end if;
end $$;

create or replace function public.get_current_match_state(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.matches;
  r public.match_rounds;
  out jsonb;
begin
  if auth.uid() is null or not public.is_room_member(p_room_id) then raise exception 'NOT_IN_ROOM'; end if;
  select * into m from public.matches where room_id = p_room_id order by started_at desc limit 1;
  if not found then raise exception 'MATCH_NOT_FOUND'; end if;
  select * into r from public.match_rounds where match_id = m.id order by round_number desc limit 1;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  out := jsonb_build_object(
    'match_id', m.id,
    'round_id', r.id,
    'round_number', r.round_number,
    'phase', r.phase,
    'pick_deadline', r.pick_deadline,
    'best_of', m.best_of,
    'winner_user_id', r.winner_user_id,
    'choices', r.resolved_choices,
    'resolved_at', r.resolved_at
  );
  return out;
end;
$$;
grant execute on function public.get_current_match_state(uuid) to authenticated;

create or replace function public.submit_round_choice(p_round_id uuid, p_choice text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.match_rounds;
  room_id_value uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_choice not in ('rock','paper','scissors') then raise exception 'INVALID_CHOICE'; end if;
  select * into r from public.match_rounds where id = p_round_id for update;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  select room_id into room_id_value from public.matches where id = r.match_id;
  if not public.is_room_member(room_id_value) then raise exception 'NOT_IN_ROOM'; end if;
  if r.phase <> 'picking' then return jsonb_build_object('accepted', false, 'resolved', true); end if;
  if now() > r.pick_deadline then return jsonb_build_object('accepted', false, 'resolved', false); end if;

  insert into public.round_choices(round_id, user_id, choice)
  values (r.id, auth.uid(), p_choice)
  on conflict (round_id, user_id) do update set choice = excluded.choice, submitted_at = now();

  return jsonb_build_object('accepted', true, 'resolved', false);
end;
$$;
grant execute on function public.submit_round_choice(uuid,text) to authenticated;

create or replace function public.resolve_round_if_ready(p_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.match_rounds;
  m public.matches;
  room_id_value uuid;
  p1 uuid;
  p2 uuid;
  c1 text;
  c2 text;
  winner uuid;
  result jsonb;
  choice_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into r from public.match_rounds where id = p_round_id for update;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  select * into m from public.matches where id = r.match_id;
  select room_id into room_id_value from public.matches where id = r.match_id;
  if not public.is_room_member(room_id_value) then raise exception 'NOT_IN_ROOM'; end if;

  if r.phase <> 'picking' then
    return jsonb_build_object('resolved', true, 'phase', r.phase, 'winner_user_id', r.winner_user_id, 'choices', r.resolved_choices, 'resolved_at', r.resolved_at);
  end if;

  select count(*) into choice_count from public.round_choices where round_id = r.id;
  if choice_count < 2 and now() < r.pick_deadline then
    return jsonb_build_object('resolved', false, 'phase', r.phase, 'winner_user_id', null, 'choices', null, 'resolved_at', null);
  end if;

  select user_id into p1 from public.room_players where room_id = room_id_value and eliminated = false order by joined_at asc limit 1;
  select user_id into p2 from public.room_players where room_id = room_id_value and eliminated = false and user_id <> p1 order by joined_at asc limit 1;
  if p1 is null or p2 is null then raise exception 'NOT_ENOUGH_PLAYERS'; end if;

  select choice into c1 from public.round_choices where round_id = r.id and user_id = p1;
  select choice into c2 from public.round_choices where round_id = r.id and user_id = p2;

  -- A missing pick at the deadline becomes a server-generated random throw.
  if c1 is null then c1 := (array['rock','paper','scissors'])[1 + floor(random()*3)::int]; end if;
  if c2 is null then c2 := (array['rock','paper','scissors'])[1 + floor(random()*3)::int]; end if;

  if c1 = c2 then winner := null;
  elsif (c1 = 'rock' and c2 = 'scissors') or (c1 = 'paper' and c2 = 'rock') or (c1 = 'scissors' and c2 = 'paper') then winner := p1;
  else winner := p2; end if;

  result := jsonb_build_object(p1::text, c1, p2::text, c2);
  update public.match_rounds
  set phase = 'finished', winner_user_id = winner, resolved_choices = result, resolved_at = now()
  where id = r.id;

  return jsonb_build_object('resolved', true, 'phase', 'finished', 'winner_user_id', winner, 'choices', result, 'resolved_at', now());
end;
$$;
grant execute on function public.resolve_round_if_ready(uuid) to authenticated;

-- Explicit Leave remains the only immediate removal path. Refreshes/disconnects do not delete players.

create or replace function public.advance_match_round(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.matches;
  r public.match_rounds;
  room_id_value uuid;
  next_no integer;
  deadline timestamptz;
  winner uuid;
  target integer;
  wins integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'MATCH_NOT_FOUND'; end if;
  room_id_value := m.room_id;
  if not public.is_room_member(room_id_value) then raise exception 'NOT_IN_ROOM'; end if;
  select * into r from public.match_rounds where match_id = m.id order by round_number desc limit 1;
  if not found or r.phase <> 'finished' then raise exception 'ROUND_NOT_FINISHED'; end if;
  if exists (select 1 from public.match_rounds where match_id = m.id and phase = 'picking') then raise exception 'ROUND_ALREADY_ACTIVE'; end if;

  target := m.target_wins;
  select r.winner_user_id into winner;
  if winner is not null then
    select count(*) into wins from public.match_rounds where match_id = m.id and phase = 'finished' and winner_user_id = winner;
    if wins >= target then
      update public.matches set status = 'finished', winner_user_id = winner, finished_at = now() where id = m.id;
      update public.rooms set status = 'finished' where id = room_id_value;
      return jsonb_build_object('finished', true, 'winner_user_id', winner);
    end if;
  end if;

  next_no := r.round_number + 1;
  deadline := now() + interval '5 seconds';
  insert into public.match_rounds(match_id, round_number, phase, pick_deadline)
  values(m.id, next_no, 'picking', deadline)
  returning * into r;
  return jsonb_build_object('finished', false, 'round_id', r.id, 'round_number', r.round_number, 'pick_deadline', r.pick_deadline);
end;
$$;
grant execute on function public.advance_match_round(uuid) to authenticated;
