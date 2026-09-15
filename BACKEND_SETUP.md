# Pick & Shoot — Supabase backend setup

The first backend slice uses Supabase Auth + Postgres + Realtime.

## 1. Create a Supabase project

Create a project in the Supabase dashboard.

## 2. Enable anonymous sign-in

In Authentication settings, enable **Anonymous Sign-Ins**. Pick & Shoot uses a temporary authenticated identity so players can enter a room without creating an account.

## 3. Run the database migration

Open the SQL Editor and run:

`supabase/migrations/001_initial.sql`, then `supabase/migrations/002_start_match.sql` (and `supabase/realtime-lobby-fix.sql` if the original migration is already applied)

The migration creates the rooms, room players, match and round tables, RLS policies, room creation/join RPCs, leave/ready RPCs, and private Realtime authorization.

## 4. Turn on private Realtime channels

In Realtime settings, disable public channel access for production. The frontend creates room channels with `private: true` and the migration authorizes members through `realtime.messages` RLS.

## 5. Add local environment variables

Copy `.env.example` to `.env.local` and fill in:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_xxxxxxxxxxxxxxxxx
```

Do **not** put a Supabase secret/service key in `VITE_*` variables or in browser code.

## 6. Install and run

```bash
npm install
npm run dev
```

## What is live in this slice

- anonymous authenticated player identity
- real room creation
- real room-code joining
- room player rows stored in Postgres
- RLS-protected room access
- private Realtime room channel
- lobby refresh when players join/leave or room state changes (via Supabase Postgres Changes)
- server-authoritative host-only match start
- automatic joiner transition from lobby to the shared match when the room enters `playing`
- server-created first match round with a 5-second pick deadline
- server-side leave-room handling

## Next backend slice

The next pass should replace the local match demo with the real server-authoritative game engine:

1. match/tournament state machine
2. bracket generation for odd player counts
3. the temporary Randomizer participant rules
4. 5-second server deadline + locked selections
5. atomic round resolution
6. custom balanced rulesets
7. reconnect/rejoin handling
8. match history and player stats

The `resolve-round` Edge Function is already scaffolded for that resolution layer but is not yet the source of truth for the current UI.
