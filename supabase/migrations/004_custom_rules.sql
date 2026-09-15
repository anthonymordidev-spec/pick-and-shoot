-- Pick & Shoot: custom rules + authoritative custom round resolution
-- Run once after 001, 002 and 003.

alter table public.rooms
  add column if not exists custom_rules jsonb;

alter table public.round_choices
  drop constraint if exists round_choices_choice_check;

alter table public.round_choices
  add constraint round_choices_choice_check check (char_length(choice) between 1 and 64);


create or replace function public.validate_custom_rules(p_rules jsonb)
returns boolean
language plpgsql
immutable
as $$
declare
  item jsonb;
  other jsonb;
  item_id text;
  other_id text;
  expected integer;
  item_count integer;
  beats jsonb;
  lhs boolean;
  rhs boolean;
begin
  if p_rules is null or jsonb_typeof(p_rules->'items') <> 'array' or jsonb_typeof(p_rules->'beats') <> 'object' then
    return false;
  end if;

  item_count := jsonb_array_length(p_rules->'items');
  if item_count < 3 or item_count > 9 or mod(item_count, 2) = 0 then return false; end if;
  expected := (item_count - 1) / 2;

  if (select count(distinct value->>'id') from jsonb_array_elements(p_rules->'items') value) <> item_count then
    return false;
  end if;

  for item in select * from jsonb_array_elements(p_rules->'items') loop
    item_id := item->>'id';
    if coalesce(length(trim(item_id)), 0) = 0 then return false; end if;
    if coalesce(length(trim(item->>'label')), 0) = 0 then return false; end if;
    beats := coalesce(p_rules->'beats'->item_id, '[]'::jsonb);
    if jsonb_typeof(beats) <> 'array' or jsonb_array_length(beats) <> expected then return false; end if;
    if (select count(distinct value) from jsonb_array_elements_text(beats)) <> expected then return false; end if;
    if beats ? item_id then return false; end if;
    if exists (
      select 1 from jsonb_array_elements_text(beats) beat_id
      where not exists (select 1 from jsonb_array_elements(p_rules->'items') candidate where candidate->>'id' = beat_id)
    ) then return false; end if;
  end loop;

  for item in select * from jsonb_array_elements(p_rules->'items') loop
    item_id := item->>'id';
    for other in select * from jsonb_array_elements(p_rules->'items') loop
      other_id := other->>'id';
      if item_id < other_id then
        lhs := coalesce(p_rules->'beats'->item_id, '[]'::jsonb) ? other_id;
        rhs := coalesce(p_rules->'beats'->other_id, '[]'::jsonb) ? item_id;
        if lhs = rhs then return false; end if;
      end if;
    end loop;
  end loop;

  return true;
end;
$$;

grant execute on function public.validate_custom_rules(jsonb) to authenticated;

-- Recreate create_room with the custom rules snapshot parameter.
drop function if exists public.create_room(text,text,text,integer,integer);

create or replace function public.create_room(
  p_display_name text,
  p_game_mode text default 'tournament',
  p_ruleset text default 'classic',
  p_best_of integer default 3,
  p_max_players integer default 8,
  p_custom_rules jsonb default null
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

  if p_ruleset = 'custom' then
    if p_custom_rules is null then raise exception 'CUSTOM_RULES_REQUIRED'; end if;
    if jsonb_typeof(p_custom_rules->'items') <> 'array' then raise exception 'INVALID_CUSTOM_RULES'; end if;
    if jsonb_array_length(p_custom_rules->'items') < 3 or jsonb_array_length(p_custom_rules->'items') > 9 then raise exception 'INVALID_CUSTOM_RULE_COUNT'; end if;
    if jsonb_typeof(p_custom_rules->'beats') <> 'object' then raise exception 'INVALID_CUSTOM_RULES'; end if;
    if not public.validate_custom_rules(p_custom_rules) then raise exception 'INVALID_CUSTOM_RULES'; end if;
  else
    p_custom_rules := null;
  end if;

  insert into public.rooms (code, host_user_id, host_name, game_mode, ruleset, custom_rules, best_of, max_players)
  values (public.make_room_code(), auth.uid(), upper(trim(p_display_name)), p_game_mode, p_ruleset, p_custom_rules, p_best_of, p_max_players)
  returning * into new_room;

  insert into public.room_players (room_id, user_id, display_name, is_host, is_ready)
  values (new_room.id, auth.uid(), upper(trim(p_display_name)), true, true);

  return new_room;
end;
$$;

grant execute on function public.create_room(text,text,text,integer,integer,jsonb) to authenticated;

create or replace function public.get_current_match_state(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.matches;
  r public.match_rounds;
  room_record public.rooms;
begin
  if auth.uid() is null or not public.is_room_member(p_room_id) then raise exception 'NOT_IN_ROOM'; end if;
  select * into room_record from public.rooms where id = p_room_id;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  select * into m from public.matches where room_id = p_room_id order by started_at desc limit 1;
  if not found then raise exception 'MATCH_NOT_FOUND'; end if;
  select * into r from public.match_rounds where match_id = m.id order by round_number desc limit 1;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;

  return jsonb_build_object(
    'match_id', m.id,
    'round_id', r.id,
    'round_number', r.round_number,
    'phase', r.phase,
    'pick_deadline', r.pick_deadline,
    'best_of', m.best_of,
    'winner_user_id', r.winner_user_id,
    'choices', r.resolved_choices,
    'resolved_at', r.resolved_at,
    'custom_rules', room_record.custom_rules
  );
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
  room_record public.rooms;
  valid_choice boolean := false;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into r from public.match_rounds where id = p_round_id for update;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  select m.room_id into room_id_value from public.matches m where m.id = r.match_id;
  if not public.is_room_member(room_id_value) then raise exception 'NOT_IN_ROOM'; end if;
  select * into room_record from public.rooms where id = room_id_value;

  if room_record.ruleset = 'classic' then
    valid_choice := p_choice in ('rock','paper','scissors');
  else
    valid_choice := exists (
      select 1
      from jsonb_array_elements(room_record.custom_rules->'items') item
      where item->>'id' = p_choice
    );
  end if;

  if not valid_choice then raise exception 'INVALID_CHOICE'; end if;
  if r.phase <> 'picking' then return jsonb_build_object('accepted', false, 'resolved', true); end if;
  if now() > r.pick_deadline then return jsonb_build_object('accepted', false, 'resolved', false); end if;

  insert into public.round_choices(round_id, user_id, choice)
  values (r.id, auth.uid(), p_choice)
  on conflict (round_id, user_id) do update
    set choice = excluded.choice, submitted_at = now();

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
  room_record public.rooms;
  room_id_value uuid;
  p1 uuid;
  p2 uuid;
  c1 text;
  c2 text;
  winner uuid;
  result jsonb;
  choice_count integer;
  options text[];
  beats_map jsonb;
  finished_at_value timestamptz;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into r from public.match_rounds where id = p_round_id for update;
  if not found then raise exception 'ROUND_NOT_FOUND'; end if;
  select * into m from public.matches where id = r.match_id;
  room_id_value := m.room_id;
  if not public.is_room_member(room_id_value) then raise exception 'NOT_IN_ROOM'; end if;
  select * into room_record from public.rooms where id = room_id_value;

  if r.phase <> 'picking' then
    return jsonb_build_object('resolved', true, 'phase', r.phase, 'winner_user_id', r.winner_user_id, 'choices', r.resolved_choices, 'resolved_at', r.resolved_at);
  end if;

  select count(*) into choice_count from public.round_choices where round_id = r.id;
  if choice_count < 2 and now() < r.pick_deadline then
    return jsonb_build_object('resolved', false, 'phase', r.phase, 'winner_user_id', null, 'choices', null, 'resolved_at', null);
  end if;

  -- v1 match engine is head-to-head. The tournament layer will select future pairings.
  select user_id into p1
  from public.room_players
  where room_id = room_id_value and eliminated = false
  order by joined_at asc limit 1;

  select user_id into p2
  from public.room_players
  where room_id = room_id_value and eliminated = false and user_id <> p1
  order by joined_at asc limit 1;

  if p1 is null or p2 is null then raise exception 'NOT_ENOUGH_PLAYERS'; end if;

  select choice into c1 from public.round_choices where round_id = r.id and user_id = p1;
  select choice into c2 from public.round_choices where round_id = r.id and user_id = p2;

  if room_record.ruleset = 'classic' then
    options := array['rock','paper','scissors'];
  else
    select array_agg(item->>'id') into options
    from jsonb_array_elements(room_record.custom_rules->'items') item;
  end if;

  -- Missing picks at the deadline become server-generated random picks from the active ruleset.
  if c1 is null then c1 := options[1 + floor(random() * array_length(options, 1))::int]; end if;
  if c2 is null then c2 := options[1 + floor(random() * array_length(options, 1))::int]; end if;

  if room_record.ruleset = 'classic' then
    if c1 = c2 then winner := null;
    elsif (c1 = 'rock' and c2 = 'scissors') or (c1 = 'paper' and c2 = 'rock') or (c1 = 'scissors' and c2 = 'paper') then winner := p1;
    else winner := p2;
    end if;
  else
    beats_map := room_record.custom_rules->'beats';
    if c1 = c2 then
      winner := null;
    elsif coalesce(beats_map->c1, '[]'::jsonb) ? c2 then
      winner := p1;
    elsif coalesce(beats_map->c2, '[]'::jsonb) ? c1 then
      winner := p2;
    else
      raise exception 'INVALID_CUSTOM_RULES';
    end if;
  end if;

  result := jsonb_build_object(p1::text, c1, p2::text, c2);
  finished_at_value := now();

  update public.match_rounds
  set phase = 'finished', winner_user_id = winner, resolved_choices = result, resolved_at = finished_at_value
  where id = r.id;

  return jsonb_build_object('resolved', true, 'phase', 'finished', 'winner_user_id', winner, 'choices', result, 'resolved_at', finished_at_value);
end;
$$;

grant execute on function public.resolve_round_if_ready(uuid) to authenticated;
