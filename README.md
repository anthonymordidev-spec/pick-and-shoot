# Pick & Shoot

A premium dark multiplayer Rock Paper Scissors prototype.

## Run

```bash
npm install
npm run dev
```

## Current prototype

- Premium landing screen and brand treatment
- Create room flow
- Join room flow
- Lobby with human players + Randomizer concept
- 5-second pick phase
- Hidden opponent pick and reveal state
- Classic RPS resolution
- Best-of-3 demo loop
- Responsive UI
- Approved Pick & Shoot brand mark used as temporary raster asset

## Next implementation layer

The UI is intentionally ready to connect to a server-authoritative realtime room layer. The next pass should replace the local demo state with Supabase Realtime or a dedicated WebSocket/room service, then implement the full human-count tournament + Randomizer rules and custom rule builder.


## Tournament engine final repair
Run `supabase/migrations/007_tournament_engine_final.sql` once in the existing Supabase project after the earlier room/custom-rules setup. It recreates the tournament RPC layer idempotently. Do not rerun the old broken 006 function patch.

The tournament engine pairs active humans once per stage, uses a temporary Randomizer only for odd human counts, resolves picks authoritatively on the server, pauses between rounds/stages, and promotes the last two humans to the final.
