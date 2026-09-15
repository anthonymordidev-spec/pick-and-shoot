import { ensureAnonymousSession, supabase } from './supabase'

export type GameMode = 'tournament' | 'quick'
export type Ruleset = 'classic' | 'custom'

export type BackendCustomRules = {
  id: string
  name: string
  items: Array<{ id: string; label: string; glyph: string }>
  beats: Record<string, string[]>
}

export type BackendRoom = {
  id: string
  code: string
  host_user_id: string
  host_name: string
  game_mode: GameMode
  ruleset: Ruleset
  custom_rules: BackendCustomRules | null
  best_of: 1 | 3 | 5
  max_players: number
  status: 'waiting' | 'playing' | 'finished'
  created_at: string
}

export type BackendPlayer = {
  user_id: string
  display_name: string
  is_host: boolean
  is_ready: boolean
  eliminated: boolean
  joined_at: string
  last_seen_at: string
}

function requireSupabase() {
  if (!supabase) {
    throw new Error('Supabase is not configured. Copy .env.example to .env.local and add your project URL and publishable key.')
  }
  return supabase
}

export async function createRoom(input: {
  displayName: string
  gameMode: GameMode
  ruleset: Ruleset
  customRules?: BackendCustomRules | null
  bestOf: 1 | 3 | 5
  maxPlayers: number
}) {
  const client = requireSupabase()
  const user = await ensureAnonymousSession(input.displayName)

  const { data, error } = await client.rpc('create_room', {
    p_display_name: input.displayName,
    p_game_mode: input.gameMode,
    p_ruleset: input.ruleset,
    p_best_of: input.bestOf,
    p_max_players: input.maxPlayers,
    p_custom_rules: input.customRules ?? null,
  })

  if (error) throw error
  if (!data) throw new Error('Room creation returned no data.')
  return { room: data as BackendRoom, userId: user.id }
}

export async function joinRoom(code: string, displayName: string) {
  const client = requireSupabase()
  const user = await ensureAnonymousSession(displayName)

  const { data, error } = await client.rpc('join_room', {
    p_code: code.trim().toUpperCase(),
    p_display_name: displayName,
  })

  if (error) throw error
  if (!data) throw new Error('Room join returned no data.')
  return { room: data as BackendRoom, userId: user.id }
}

export async function getRoomPlayers(roomId: string) {
  const client = requireSupabase()
  const { data, error } = await client
    .from('room_players')
    .select('user_id, display_name, is_host, is_ready, eliminated, joined_at, last_seen_at')
    .eq('room_id', roomId)
    .order('joined_at', { ascending: true })

  if (error) throw error
  return (data ?? []) as BackendPlayer[]
}

export async function startRoomMatch(roomId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('start_room_match', { p_room_id: roomId })
  if (error) throw error
  if (!data) throw new Error('Match start returned no data.')
  return data as {
    match_id: string
    round_id: string
    pick_deadline: string
    best_of: 1 | 3 | 5
  }
}

export async function getRoom(roomId: string) {
  const client = requireSupabase()
  const { data, error } = await client
    .from('rooms')
    .select('id, code, host_user_id, host_name, game_mode, ruleset, custom_rules, best_of, max_players, status, created_at')
    .eq('id', roomId)
    .single()
  if (error) throw error
  return data as BackendRoom
}

export async function getCurrentMatchState(roomId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('get_current_match_state', { p_room_id: roomId })
  if (error) throw error
  return data as {
    match_id: string
    round_id: string
    round_number: number
    phase: 'picking' | 'reveal' | 'finished'
    pick_deadline: string
    best_of: 1 | 3 | 5
    winner_user_id: string | null
    choices: Record<string, string> | null
    resolved_at: string | null
    custom_rules: BackendCustomRules | null
  }
}

export async function submitRoundChoice(roundId: string, choice: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('submit_round_choice', { p_round_id: roundId, p_choice: choice })
  if (error) throw error
  return data as { accepted: boolean; resolved: boolean; expired?: boolean }
}

export async function resolveRoundIfReady(roundId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('resolve_round_if_ready', { p_round_id: roundId })
  if (error) throw error
  return data as {
    resolved: boolean
    phase: string
    winner_user_id: string | null
    choices: Record<string, string> | null
    resolved_at: string | null
  }
}

export async function advanceMatchRound(matchId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('advance_match_round', { p_match_id: matchId })
  if (error) throw error
  return data as { finished: boolean; winner_user_id?: string | null; round_id?: string; round_number?: number; pick_deadline?: string }
}

export async function leaveRoom(roomId: string) {
  const client = requireSupabase()
  const { error } = await client.rpc('leave_room', { p_room_id: roomId })
  if (error) throw error
}

export async function setReady(roomId: string, ready: boolean) {
  const client = requireSupabase()
  const { error } = await client.rpc('set_ready', { p_room_id: roomId, p_ready: ready })
  if (error) throw error
}

export function subscribeToRoom(roomCode: string, roomId: string, onChange: () => void, onError?: (message: string) => void) {
  const client = requireSupabase()
  const channel = client
    .channel(`room:${roomCode}`, {
      config: { private: true },
    })
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'room_players', filter: `room_id=eq.${roomId}` },
      onChange,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${roomId}` },
      onChange,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'match_rounds' },
      onChange,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'matches', filter: `room_id=eq.${roomId}` },
      onChange,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'tournaments', filter: `room_id=eq.${roomId}` },
      onChange,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'tournament_pairings' },
      onChange,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'tournament_rounds' },
      onChange,
    )

  void channel.subscribe((status) => {
    if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
      onError?.(`Realtime room connection: ${status}`)
    }
  })

  return () => {
    void client.removeChannel(channel)
  }
}

export type TournamentPairingState = {
  id: string
  pairIndex: number
  playerA: { id: string; name: string } | null
  playerB: { id: string; name: string } | null
  againstRandomizer: boolean
  status: 'active' | 'finished'
  winnerUserId: string | null
  randomizerWon: boolean
  roundNumber: number
  roundId: string | null
  roundPhase: 'picking' | 'finished' | null
  pickDeadline: string | null
  resolvedChoices: Record<string, string> | null
  roundWinnerUserId: string | null
  roundRandomizerWon: boolean
  scoreA: number
  scoreB: number
}

export type TournamentState = {
  tournamentId: string
  stageNumber: number
  status: 'active' | 'finished'
  championUserId: string | null
  bestOf: 1 | 3 | 5
  humanCount: number
  pairings: TournamentPairingState[]
  yourPairingId: string | null
  currentRoundId: string | null
  currentUserSubmitted?: boolean
  stageComplete?: boolean
}

export async function startTournament(roomId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('start_tournament', { p_room_id: roomId })
  if (error) throw error
  return data as { tournament_id: string; stage_number: number }
}

export async function getTournamentState(roomId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('get_tournament_state', { p_room_id: roomId })
  if (error) throw error
  return data as TournamentState
}

export async function submitTournamentChoice(roundId: string, choice: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('submit_tournament_choice', { p_round_id: roundId, p_choice: choice })
  if (error) throw error
  return data as { accepted: boolean; resolved: boolean; expired?: boolean }
}

export async function resolveTournamentRound(roundId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('resolve_tournament_round', { p_round_id: roundId })
  if (error) throw error
  return data as { resolved: boolean; phase: string; winner_user_id: string | null; choices: Record<string, string> | null }
}

export async function advanceTournamentStage(roomId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('advance_tournament_stage', { p_room_id: roomId })
  if (error) throw error
  return data as { advanced: boolean; finished: boolean; stage_number: number; champion_user_id?: string | null }
}

export async function advanceTournamentPairing(pairingId: string) {
  const client = requireSupabase()
  const { data, error } = await client.rpc('advance_tournament_pairing', { p_pairing_id: pairingId })
  if (error) throw error
  return data as { advanced: boolean; finished: boolean }
}
