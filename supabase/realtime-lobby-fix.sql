-- Pick & Shoot: host lobby realtime fix
-- Run this once in Supabase SQL Editor if 001_initial.sql was already run.
-- This enables Postgres Changes for the tables the lobby watches.

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'room_players'
  ) then
    alter publication supabase_realtime add table public.room_players;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'rooms'
  ) then
    alter publication supabase_realtime add table public.rooms;
  end if;
end $$;

-- Verify the two lobby tables are now in the Realtime publication.
select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and schemaname = 'public'
  and tablename in ('room_players', 'rooms')
order by tablename;
