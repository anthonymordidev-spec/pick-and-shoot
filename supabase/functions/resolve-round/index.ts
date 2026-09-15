// Server-side round resolver for Pick & Shoot.
// Deploy with: supabase functions deploy resolve-round
import { createClient } from 'jsr:@supabase/supabase-js@2'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const secretKey = Deno.env.get('SUPABASE_SECRET_KEY')
if (!secretKey) throw new Error('SUPABASE_SECRET_KEY is not configured')

const admin = createClient(supabaseUrl, secretKey, {
  auth: { autoRefreshToken: false, persistSession: false },
})

const wins: Record<string, string> = {
  rock: 'scissors',
  scissors: 'paper',
  paper: 'rock',
}

Deno.serve(async (request) => {
  try {
    if (request.method !== 'POST') return new Response('Method Not Allowed', { status: 405 })

    const body = await request.json() as { roundId?: string }
    if (!body.roundId) return Response.json({ error: 'roundId is required' }, { status: 400 })

    const { data: round, error: roundError } = await admin
      .from('match_rounds')
      .select('id, match_id, phase, pick_deadline, round_number')
      .eq('id', body.roundId)
      .single()

    if (roundError) throw roundError
    if (round.phase === 'finished') return Response.json({ resolved: true })
    if (new Date(round.pick_deadline).getTime() > Date.now()) {
      return Response.json({ error: 'ROUND_NOT_DUE' }, { status: 409 })
    }

    const { data: match, error: matchError } = await admin
      .from('matches')
      .select('id, room_id, best_of, status')
      .eq('id', round.match_id)
      .single()
    if (matchError) throw matchError

    const { data: choices, error: choicesError } = await admin
      .from('round_choices')
      .select('user_id, choice, submitted_at')
      .eq('round_id', round.id)
    if (choicesError) throw choicesError

    const { data: members, error: membersError } = await admin
      .from('room_players')
      .select('user_id, display_name, eliminated')
      .eq('room_id', match.room_id)
      .eq('eliminated', false)
    if (membersError) throw membersError

    // For the first backend slice we resolve a two-player round. The tournament
    // engine will reuse this round primitive for bracket pairings.
    const activePlayers = members ?? []
    if (activePlayers.length !== 2) {
      return Response.json({ error: 'ROUND_REQUIRES_TWO_ACTIVE_PLAYERS' }, { status: 422 })
    }

    const choiceMap = new Map((choices ?? []).map((row) => [row.user_id, row.choice]))
    const [a, b] = activePlayers
    const aChoice = choiceMap.get(a.user_id) ?? null
    const bChoice = choiceMap.get(b.user_id) ?? null

    let winnerUserId: string | null = null
    if (aChoice && bChoice && aChoice !== bChoice) {
      winnerUserId = wins[aChoice] === bChoice ? a.user_id : b.user_id
    }

    const now = new Date().toISOString()
    const { error: roundUpdateError } = await admin
      .from('match_rounds')
      .update({ phase: 'finished', winner_user_id: winnerUserId, resolved_at: now })
      .eq('id', round.id)
      .eq('phase', 'picking')
    if (roundUpdateError) throw roundUpdateError

    return Response.json({
      resolved: true,
      roundId: round.id,
      winnerUserId,
      choices: { [a.user_id]: aChoice, [b.user_id]: bChoice },
    })
  } catch (error) {
    console.error(error)
    return Response.json({ error: error instanceof Error ? error.message : 'Unknown error' }, { status: 500 })
  }
})
