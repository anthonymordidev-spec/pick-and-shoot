import { Component, type ErrorInfo, type ReactNode, useEffect, useRef, useState } from 'react'
import { pickRandomThrow, resolve, THROWS, type ThrowId } from './lib/game'
import { createRoom as createBackendRoom, getRoom, getRoomPlayers, joinRoom as joinBackendRoom, leaveRoom as leaveBackendRoom, subscribeToRoom, type BackendCustomRules, startTournament, getTournamentState, getCurrentMatchState, submitTournamentChoice, resolveTournamentRound, advanceTournamentPairing, advanceTournamentStage, setReady as setBackendReady, type TournamentState } from './lib/backend'
import { supabaseConfigured, supabase } from './lib/supabase'

type Screen = 'home' | 'multiplayer' | 'create' | 'join' | 'lobby' | 'match' | 'custom' | 'solo-settings'
type PendingDestination = Screen | null

class AppErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null }

  static getDerivedStateFromError(error: Error) {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('Pick & Shoot runtime error:', error, info)
  }

  render() {
    if (this.state.error) {
      return (
        <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 24, background: '#030609', color: '#eef7ff', fontFamily: 'Inter, system-ui, sans-serif' }}>
          <div style={{ maxWidth: 680, width: '100%', padding: 24, border: '1px solid rgba(37, 199, 255, .25)', borderRadius: 20, background: 'rgba(8, 18, 25, .92)' }}>
            <div style={{ color: '#20c7ff', fontWeight: 700, letterSpacing: '.12em', fontSize: 12 }}>PICK & SHOOT · RUNTIME ERROR</div>
            <h2 style={{ margin: '10px 0 8px' }}>The lobby hit an error.</h2>
            <p style={{ color: '#a9bac8', lineHeight: 1.6, wordBreak: 'break-word' }}>{this.state.error.message}</p>
            <button onClick={() => window.location.reload()} style={{ marginTop: 12, border: 0, borderRadius: 12, padding: '12px 18px', background: '#18bfff', color: '#001018', fontWeight: 800, cursor: 'pointer' }}>Reload</button>
          </div>
        </div>
      )
    }
    return this.props.children
  }
}

type Player = {
  id: string
  name: string
  human: boolean
  isHost?: boolean
  isReady?: boolean
}

const seedPlayers: Player[] = [
  { id: 'you', name: 'ACE', human: true, isHost: true, isReady: true },
  { id: 'p2', name: 'JESSE', human: true, isReady: true },
  { id: 'p3', name: 'MORDI', human: true, isReady: true },
  { id: 'p4', name: 'CHIOMA', human: true, isReady: true },
]

const FORMAT_OPTIONS = [1, 3, 5] as const

type CustomRuleSet = {
  id: string
  name: string
  items: Array<{ id: string; label: string; glyph: string }>
  beats: Record<string, string[]>
  system?: 'preset' | 'user'
}

const CUSTOM_STORAGE_KEY = 'pns_custom_rulesets'
const PLAYER_NAME_KEY = 'pns_player_name'

const CUSTOM_PRESETS: CustomRuleSet[] = [
  {
    id: 'classic-rps', name: 'Classic RPS', system: 'preset',
    items: [
      { id: 'rock', label: 'Rock', glyph: '✊' }, { id: 'paper', label: 'Paper', glyph: '✋' },
      { id: 'scissors', label: 'Scissors', glyph: '✌' },
    ],
    beats: { rock: ['scissors'], paper: ['rock'], scissors: ['paper'] },
  },
  {
    id: 'lizard-spock', name: 'Lizard Spock', system: 'preset',
    items: [
      { id: 'rock', label: 'Rock', glyph: '✊' }, { id: 'paper', label: 'Paper', glyph: '✋' },
      { id: 'scissors', label: 'Scissors', glyph: '✌' }, { id: 'lizard', label: 'Lizard', glyph: '🦎' },
      { id: 'spock', label: 'Spock', glyph: '🖖' },
    ],
    beats: {
      rock: ['scissors','lizard'], paper: ['rock','spock'], scissors: ['paper','lizard'],
      lizard: ['spock','paper'], spock: ['scissors','rock'],
    },
  },
  {
    id: 'rps-7', name: 'RPS-7 · Seven Elements', system: 'preset',
    items: [
      { id: 'rock', label: 'Rock', glyph: '✊' }, { id: 'fire', label: 'Fire', glyph: '🔥' },
      { id: 'scissors', label: 'Scissors', glyph: '✌' }, { id: 'sponge', label: 'Sponge', glyph: '🧽' },
      { id: 'paper', label: 'Paper', glyph: '✋' }, { id: 'air', label: 'Air', glyph: '💨' },
      { id: 'water', label: 'Water', glyph: '💧' },
    ],
    beats: {
      rock: ['scissors','sponge','fire'], fire: ['scissors','sponge','paper'], scissors: ['paper','air','sponge'],
      sponge: ['paper','air','water'], paper: ['rock','water','air'], air: ['rock','fire','water'], water: ['rock','fire','scissors'],
    },
  },
]

function AppContent() {
  const [screen, setScreen] = useState<Screen>('home')
  const [name, setName] = useState('')
  const [room, setRoom] = useState('')
  const [players, setPlayers] = useState<Player[]>(seedPlayers)
  const [solo, setSolo] = useState(false)
  const [round, setRound] = useState(1)
  const [backendMatchId, setBackendMatchId] = useState<string | null>(null)
  const [backendRoundId, setBackendRoundId] = useState<string | null>(null)
  const [backendPickDeadline, setBackendPickDeadline] = useState<string | null>(null)
  const [backendChoices, setBackendChoices] = useState<Record<string, ThrowId> | null>(null)
  const [backendWinnerId, setBackendWinnerId] = useState<string | null>(null)
  const [bestOf, setBestOf] = useState(3)
  const [soloBestOf, setSoloBestOf] = useState(3)
  const [soloCustomId, setSoloCustomId] = useState<string | null>(null)
  const [score, setScore] = useState({ you: 0, opp: 0 })
  const [selection, setSelection] = useState<ThrowId | null>(null)
  const [countdown, setCountdown] = useState(5)
  const [phase, setPhase] = useState<'pick' | 'reveal' | 'result'>('pick')
  const [opponentThrow, setOpponentThrow] = useState<ThrowId | null>(null)
  const [result, setResult] = useState<'win' | 'lose' | 'draw' | null>(null)
  const [showLeaveConfirm, setShowLeaveConfirm] = useState(false)
  const [backendRoomId, setBackendRoomId] = useState<string | null>(null)
  const [currentUserId, setCurrentUserId] = useState<string | null>(null)
  const [backendError, setBackendError] = useState('')
  const [backendBusy, setBackendBusy] = useState(false)
  const [pendingDestination, setPendingDestination] = useState<PendingDestination>(null)
  const [showNameOnboarding, setShowNameOnboarding] = useState(false)
  const [profileOpen, setProfileOpen] = useState(false)
  const [profileDraft, setProfileDraft] = useState('')
  const [customRulesets, setCustomRulesets] = useState<CustomRuleSet[]>([])
  const [selectedCustomId, setSelectedCustomId] = useState<string | null>(null)
  const [customDraft, setCustomDraft] = useState<CustomRuleSet | null>(null)
  const [activeCustomRules, setActiveCustomRules] = useState<CustomRuleSet | null>(null)
  const [tournamentState, setTournamentState] = useState<TournamentState | null>(null)
  const [hasSubmitted, setHasSubmitted] = useState(false)
  const [championShown, setChampionShown] = useState(false)
  const [matchIntro, setMatchIntro] = useState<{ title: string; subtitle: string } | null>(null)
  const tournamentTransitionTimer = useRef<number | null>(null)
  const lastIntroKey = useRef<string>('')

  const persistRoom = (value: { roomId: string; code: string; userId: string; name: string }) => {
    localStorage.setItem('pns_active_room', JSON.stringify(value))
  }
  const clearPersistedRoom = () => localStorage.removeItem('pns_active_room')
  const allPlayersReady = players.length >= 2 && players.every((player) => player.isReady)
  const showMatchIntro = (title: string, subtitle: string, key = `${title}:${subtitle}`) => {
    if (lastIntroKey.current === key) return
    lastIntroKey.current = key
    setMatchIntro({ title, subtitle })
    window.setTimeout(() => setMatchIntro(null), 1800)
  }

  const currentPlayer = players.find((p) => p.id === currentUserId)
  const selectedCustom = [...CUSTOM_PRESETS, ...customRulesets].find((item) => item.id === selectedCustomId) ?? CUSTOM_PRESETS[0]
  const currentPlayerIndex = players.findIndex((p) => p.id === currentUserId)
  const isCurrentUserHost = Boolean(currentPlayer?.isHost)
  const currentPairing = tournamentState?.pairings.find((pairing) => pairing.id === tournamentState.yourPairingId) ?? null
  const isPlayerA = Boolean(currentPairing && currentUserId && currentPairing.playerA?.id === currentUserId)
  const matchOpponent = solo
    ? { id: 'randomizer', name: 'RANDOMIZER', human: false }
    : currentPairing
      ? (isPlayerA
        ? (currentPairing.againstRandomizer ? { id: 'randomizer', name: 'RANDOMIZER', human: false } : { id: currentPairing.playerB?.id ?? 'opponent', name: currentPairing.playerB?.name ?? 'OPPONENT', human: true })
        : { id: currentPairing.playerA?.id ?? 'opponent', name: currentPairing.playerA?.name ?? 'OPPONENT', human: true })
      : { id: 'spectator', name: 'TOURNAMENT', human: true }


  function loadCustomRules() {
    try {
      const parsed = JSON.parse(localStorage.getItem(CUSTOM_STORAGE_KEY) ?? '[]')
      setCustomRulesets(Array.isArray(parsed) ? parsed : [])
    } catch { setCustomRulesets([]) }
  }

  function rulesetSignature(ruleset: CustomRuleSet) {
    return JSON.stringify({
      items: ruleset.items.map((item) => ({ id: item.id, label: item.label, glyph: item.glyph })),
      beats: Object.fromEntries(Object.entries(ruleset.beats).sort(([a], [b]) => a.localeCompare(b)).map(([key, values]) => [key, [...values].sort()])),
    })
  }

  function saveCustomRuleset(ruleset: CustomRuleSet) {
    const isExistingUserRule = customRulesets.some((item) => item.id === ruleset.id)
    const signature = rulesetSignature(ruleset)
    const presetMatch = CUSTOM_PRESETS.find((item) => rulesetSignature(item) === signature)
    if (!isExistingUserRule && presetMatch) {
      setSelectedCustomId(presetMatch.id)
      return
    }
    const identicalExisting = customRulesets.find((item) => rulesetSignature(item) === signature)
    const id = isExistingUserRule ? ruleset.id : (identicalExisting?.id ?? `custom-${Date.now()}`)
    const saved: CustomRuleSet = { ...ruleset, id, system: 'user' }
    const next = [saved, ...customRulesets.filter((item) => item.id !== id)]
    setCustomRulesets(next)
    localStorage.setItem(CUSTOM_STORAGE_KEY, JSON.stringify(next))
    setSelectedCustomId(id)
  }

  function deleteCustomRuleset(id: string) {
    const next = customRulesets.filter((item) => item.id !== id)
    setCustomRulesets(next)
    localStorage.setItem(CUSTOM_STORAGE_KEY, JSON.stringify(next))
    if (selectedCustomId === id) setSelectedCustomId(null)
  }

  function saveActiveRulesToDevice() {
    if (!activeCustomRules) return
    const existing = customRulesets.find((item) => rulesetSignature(item) === rulesetSignature(activeCustomRules))
    if (existing) {
      setSelectedCustomId(existing.id)
      return
    }
    const saved: CustomRuleSet = { ...JSON.parse(JSON.stringify(activeCustomRules)), id: `custom-${Date.now()}`, system: 'user' }
    const next = [saved, ...customRulesets]
    setCustomRulesets(next)
    setSelectedCustomId(saved.id)
    localStorage.setItem(CUSTOM_STORAGE_KEY, JSON.stringify(next))
  }

  function openCustomBuilder(ruleset?: CustomRuleSet) {
    const base = ruleset && ruleset.system === 'user'
      ? ruleset
      : {
          id: `custom-${Date.now()}`,
          name: ruleset ? `${ruleset.name} Remix` : 'My Custom Rules',
          system: 'user' as const,
          items: JSON.parse(JSON.stringify(ruleset?.items ?? CUSTOM_PRESETS[0].items.slice(0, 3))),
          beats: JSON.parse(JSON.stringify(ruleset?.beats ?? { rock: ['scissors'], paper: ['rock'], scissors: ['paper'] })),
        }
    setCustomDraft(JSON.parse(JSON.stringify(base)))
    setScreen('custom')
  }

  function updateCustomName(value: string) {
    setCustomDraft((draft) => draft ? { ...draft, name: value.slice(0, 28) } : draft)
  }

  function addCustomItem() {
    setCustomDraft((draft) => {
      if (!draft || draft.items.length >= 9) return draft
      const id = `item-${Date.now()}`
      return { ...draft, items: [...draft.items, { id, label: `Item ${draft.items.length + 1}`, glyph: '◆' }] }
    })
  }

  function removeCustomItem(id: string) {
    setCustomDraft((draft) => {
      if (!draft || draft.items.length <= 3) return draft
      const items = draft.items.filter((item) => item.id !== id)
      const beats = Object.fromEntries(Object.entries(draft.beats).filter(([key]) => key !== id).map(([key, values]) => [key, (values as string[]).filter((v) => v !== id)])) as Record<string, string[]>
      return { ...draft, items, beats }
    })
  }

  function updateCustomItem(id: string, patch: Partial<CustomRuleSet['items'][number]>) {
    setCustomDraft((draft) => draft ? { ...draft, items: draft.items.map((item) => item.id === id ? { ...item, ...patch } : item) } : draft)
  }

  function toggleCustomBeat(source: string, target: string) {
    setCustomDraft((draft) => {
      if (!draft || source === target) return draft
      const current = draft.beats[source] ?? []
      const next = current.includes(target) ? current.filter((id) => id !== target) : [...current, target]
      return { ...draft, beats: { ...draft.beats, [source]: next } }
    })
  }

  function customIsBalanced(ruleset: CustomRuleSet) {
    if (ruleset.items.length % 2 === 0) return false
    const expected = (ruleset.items.length - 1) / 2
    return ruleset.items.every((item) => (ruleset.beats[item.id] ?? []).length === expected) &&
      ruleset.items.every((item) => ruleset.items.every((other) => item.id === other.id || ((ruleset.beats[item.id] ?? []).includes(other.id) !== (ruleset.beats[other.id] ?? []).includes(item.id))))
  }

  useEffect(() => {
    const storedName = localStorage.getItem(PLAYER_NAME_KEY) ?? ''
    setName(storedName)
    setProfileDraft(storedName)
    loadCustomRules()
    if (!storedName) setShowNameOnboarding(true)
  }, [])

  useEffect(() => {
    if (screen !== 'match' || phase === 'result') return
    const deadline = backendPickDeadline ? new Date(backendPickDeadline).getTime() : null
    if (!deadline) return
    let resolved = false
    const tick = () => {
      const remaining = Math.max(0, Math.ceil((deadline - Date.now()) / 1000))
      setCountdown(remaining)
      if (remaining <= 0 && !resolved && backendRoundId && !solo) {
        resolved = true
        if (selection && !hasSubmitted) {
          void (async () => {
            try {
              const response = await submitTournamentChoice(backendRoundId, selection)
              if (!response.accepted && response.expired) await resolveTournamentRound(backendRoundId)
            } catch (error) {
              console.warn('Pick & Shoot auto-shoot:', error)
              await resolveTournamentRound(backendRoundId).catch((fallbackError) => console.warn('Pick & Shoot timeout resolve:', fallbackError))
            }
          })()
        } else {
          void resolveTournamentRound(backendRoundId).catch((error) => console.warn('Pick & Shoot deadline resolve:', error))
        }
      }
    }
    tick()
    const timer = window.setInterval(tick, 150)
    return () => window.clearInterval(timer)
  }, [screen, phase, backendPickDeadline, backendRoundId, solo, selection, hasSubmitted])

  function enterMatch(isSolo = false) {
    setSolo(isSolo)
    setScreen('match')
    setRound(tournamentState?.stageNumber ?? 1)
    setScore({ you: 0, opp: 0 })
    setSelection(null)
    setCountdown(5)
    setPhase('pick')
    setResult(null)
    setOpponentThrow(null)
    setHasSubmitted(false)
    setChampionShown(false)
    setShowLeaveConfirm(false)
    setPendingDestination(null)
    if (isSolo) {
      setActiveCustomRules(null)
      setBackendMatchId(null)
      setBackendRoundId(null)
      setBackendPickDeadline(null)
      setBackendChoices(null)
      setBackendWinnerId(null)
    }
  }

  async function handleToggleReady() {
    if (!backendRoomId || !currentUserId || backendBusy) return
    try {
      setBackendBusy(true)
      const nextReady = !Boolean(currentPlayer?.isReady)
      await setBackendReady(backendRoomId, nextReady)
      const backendPlayers = await getRoomPlayers(backendRoomId)
      setPlayers(backendPlayers.map((p) => ({ id: p.user_id, name: p.display_name, human: true, isHost: p.is_host, isReady: p.is_ready })))
    } catch (error) {
      setBackendError(error instanceof Error ? error.message : 'Could not update ready status.')
    } finally {
      setBackendBusy(false)
    }
  }

  async function handleStartTournament() {
    if (backendBusy) return
    setBackendError('')

    if (!backendRoomId) { setBackendError('This lobby is not connected to a room yet.'); return }
    if (!currentUserId) { setBackendError('Your player session is not ready yet.'); return }
    if (players.length < 2) { setBackendError('At least 2 players are required.'); return }
    if (!allPlayersReady) { setBackendError('Everyone must be ready before the tournament can start.'); return }

    try {
      setBackendBusy(true)

      // Ask Supabase who the real host is instead of trusting only the local
      // player-list flag. This prevents a stale local identity from silently
      // swallowing the Start click.
      const roomState = await getRoom(backendRoomId)
      if (roomState.host_user_id !== currentUserId) {
        setBackendError('Only the room host can start the tournament.')
        return
      }

      if (roomState.status === 'playing') {
        const resumedState = await getTournamentState(backendRoomId)
        setTournamentState(resumedState)
        setBestOf(resumedState.bestOf)
        const resumedPairing = resumedState.pairings.find((item) => item.id === resumedState.yourPairingId)
        setBackendMatchId(resumedState.tournamentId)
        setBackendRoundId(resumedPairing?.roundId ?? null)
        setBackendPickDeadline(resumedPairing?.pickDeadline ?? null)
        setBackendChoices(resumedPairing?.resolvedChoices as Record<string, ThrowId> | null)
        setScreen('match')
        showMatchIntro(`ROUND ${resumedState.stageNumber}`, 'GET READY', `resume:${resumedState.stageNumber}`)
        return
      }

      const started = await startTournament(backendRoomId)

      // The RPC commits the stage first. Poll until the state function can see
      // the new tournament and our own pairing, then leave the lobby.
      let state: TournamentState | null = null
      let lastStateError: unknown = null
      for (let attempt = 0; attempt < 8; attempt += 1) {
        try {
          state = await getTournamentState(backendRoomId)
          if (state.pairings.length > 0 && state.yourPairingId) break
        } catch (stateError) {
          lastStateError = stateError
        }
        await new Promise((resolve) => window.setTimeout(resolve, 250 * (attempt + 1)))
      }

      if (!state || state.pairings.length === 0 || !state.yourPairingId) {
        throw lastStateError ?? new Error('The tournament was created, but the opening match could not be loaded yet.')
      }

      setTournamentState(state)
      const pairing = state.pairings.find((item) => item.id === state.yourPairingId)
      if (!pairing) throw new Error('Your opening pairing was not created.')
      setBestOf(state.bestOf)
      setBackendMatchId(started.tournament_id ?? state.tournamentId)
      setBackendRoundId(pairing.roundId ?? null)
      setBackendPickDeadline(pairing.pickDeadline ?? null)
      setBackendChoices(pairing.resolvedChoices as Record<string, ThrowId> | null)
      setBackendWinnerId(pairing.winnerUserId ?? null)
      setScreen('match')
      showMatchIntro('ROUND 1', 'GET READY', 'start:round1')
    } catch (error) {
      console.error('Pick & Shoot start tournament error:', error)
      const detail = error && typeof error === 'object'
        ? [
            'message' in error ? String(error.message ?? '') : '',
            'code' in error ? `code=${String(error.code ?? '')}` : '',
            'details' in error ? `details=${String(error.details ?? '')}` : '',
            'hint' in error ? `hint=${String(error.hint ?? '')}` : '',
          ].filter(Boolean).join(' | ')
        : String(error ?? '')
      setBackendError(detail || 'Could not start the tournament.')
    } finally {
      setBackendBusy(false)
    }
  }

  function startSoloMatch() {
    setSoloBestOf(bestOf)
    setSoloCustomId(selectedCustomId)
    setScreen('solo-settings')
  }

  function launchSoloMatch() {
    const soloRules = [...CUSTOM_PRESETS, ...customRulesets].find((item) => item.id === soloCustomId) ?? null
    setSolo(true)
    setScreen('match')
    setRound(1)
    setSelection(null)
    setOpponentThrow(null)
    setResult(null)
    setCountdown(5)
    setPhase('pick')
    setHasSubmitted(false)
    setChampionShown(false)
    setScore({ you: 0, opp: 0 })
    setBestOf(soloBestOf)
    setBackendRoundId(null)
    setBackendPickDeadline(null)
    setBackendChoices(null)
    setBackendWinnerId(null)
    setActiveCustomRules(soloRules ? JSON.parse(JSON.stringify(soloRules)) : null)
  }

  async function lockIn(choice = selection) {
    if (phase !== 'pick' || hasSubmitted || !choice) return
    setSelection(choice)

    if (!solo) {
      if (!backendRoundId) return
      try {
        setBackendBusy(true)
        const response = await submitTournamentChoice(backendRoundId, choice)
        setBackendBusy(false)
        if (!response.accepted) {
          setHasSubmitted(false)
          if (response.expired) {
            void resolveTournamentRound(backendRoundId).catch((error) => console.warn('Pick & Shoot expired round resolve:', error))
          }
          setPhase('pick')
          return
        }
        setHasSubmitted(true)
        setPhase('reveal')
        void resolveTournamentRound(backendRoundId).catch((error) => console.warn('Pick & Shoot resolve after submit:', error))
        return
      } catch (error) {
        console.error('Pick & Shoot submit tournament choice error:', error)
        setBackendBusy(false)
        setHasSubmitted(false)
        setPhase('pick')
        setBackendError(error instanceof Error ? error.message : 'Could not submit your throw.')
        return
      }
    }

    const customBeats = activeCustomRules
      ? activeCustomRules.beats
      : Object.fromEntries(THROWS.map((item) => [item.id, item.beats ? [item.beats] : []]))
    const theirs = pickRandomThrow(activeOptions)
    const winner = resolve(choice, theirs, customBeats)
    const nextResult = choice === theirs ? 'draw' : winner === 'a' ? 'win' : 'lose'
    const nextScore = {
      you: score.you + (nextResult === 'win' ? 1 : 0),
      opp: score.opp + (nextResult === 'lose' ? 1 : 0),
    }
    setOpponentThrow(theirs)
    setPhase('reveal')
    window.setTimeout(() => {
      setResult(nextResult)
      setScore(nextScore)
      setPhase('result')
    }, 700)
  }

  const matchComplete = Boolean(currentPairing?.status === 'finished') || (solo && (score.you >= Math.ceil(bestOf / 2) || score.opp >= Math.ceil(bestOf / 2)))

  async function nextRound() {
    if (solo) {
      if (matchComplete) { startSoloMatch(); return }
      setRound((value) => value + 1)
      setSelection(null); setOpponentThrow(null); setResult(null); setCountdown(5); setPhase('pick'); setHasSubmitted(false)
      return
    }
    if (currentPairing) {
      try {
        if (currentPairing.status === 'finished') {
          await advanceTournamentStage(backendRoomId!)
        } else if (backendRoundId) {
          await advanceTournamentPairing(backendRoundId ? currentPairing.id : '')
        }
        const state = await getTournamentState(backendRoomId!)
        setTournamentState(state)
        setRound(state.stageNumber)
        const pairing = state.pairings.find((item) => item.id === state.yourPairingId)
        setBackendRoundId(pairing?.roundId ?? null)
        setBackendPickDeadline(pairing?.pickDeadline ?? null)
        setSelection(null); setOpponentThrow(null); setResult(null); setHasSubmitted(false)
        setPhase(pairing?.roundPhase === 'finished' ? 'result' : 'pick')
      } catch (error) {
        setBackendError(error instanceof Error ? error.message : 'Could not continue the tournament.')
      }
    }
  }

  function openMultiplayer() {
    setSolo(false)
    setBackendError('')
    setScreen('multiplayer')
  }

  function openJoinRoom() {
    if (screen === 'match') { requestNavigation('join'); return }
    setBackendError('')
    setRoom('')
    setScreen('join')
  }

  async function openLobby() {
    setSolo(false)
    setBackendError('')
    if (!supabaseConfigured) {
      setPlayers(seedPlayers)
      setScreen('lobby')
      return
    }
    if (!backendRoomId) {
      setPlayers(seedPlayers)
    }
    if (backendRoomId) {
      setScreen('lobby')
      return
    }
    setScreen('lobby')
  }

  async function handleCreateRoom() {
    setBackendError('')
    const safeName = name.trim().replace(/\s+/g, ' ')
    if (!safeName) { setBackendError('Enter your player name first.'); return }
    const normalizedName = safeName.toUpperCase().slice(0, 12)
    setName(normalizedName)
    localStorage.setItem(PLAYER_NAME_KEY, normalizedName)
    setProfileDraft(normalizedName)
    if (!supabaseConfigured) {
      openLobby()
      return
    }
    try {
      setBackendBusy(true)
      const usingCustom = Boolean(selectedCustomId)
      const customRules: BackendCustomRules | null = usingCustom && selectedCustom ? { id: selectedCustom.id, name: selectedCustom.name, items: selectedCustom.items, beats: selectedCustom.beats } : null
      const created = await createBackendRoom({ displayName: normalizedName, gameMode: 'tournament', ruleset: usingCustom ? 'custom' : 'classic', customRules, bestOf: bestOf as 1 | 3 | 5, maxPlayers: 32 })
      const sessionUser = (await supabase?.auth.getUser())?.data.user
      const resolvedUserId = sessionUser?.id ?? created.userId
      setBackendRoomId(created.room.id)
      setCurrentUserId(resolvedUserId)
      setRoom(created.room.code)
      persistRoom({ roomId: created.room.id, code: created.room.code, userId: created.userId, name: safeName.toUpperCase().slice(0, 12) })
      setBestOf(created.room.best_of)
      setActiveCustomRules(created.room.custom_rules ? JSON.parse(JSON.stringify(created.room.custom_rules)) : null)
      const backendPlayers = await getRoomPlayers(created.room.id)
      setPlayers(backendPlayers.map((p) => ({ id: p.user_id, name: p.display_name, human: true, isHost: p.is_host, isReady: p.is_ready })))
      setScreen('lobby')
    } catch (error) {
      console.error('Pick & Shoot create room error:', error)
      const detail = error && typeof error === 'object'
        ? [
            'message' in error ? String(error.message ?? '') : '',
            'code' in error ? `code=${String(error.code ?? '')}` : '',
            'details' in error ? `details=${String(error.details ?? '')}` : '',
            'hint' in error ? `hint=${String(error.hint ?? '')}` : '',
          ].filter(Boolean).join(' | ')
        : String(error ?? '')
      setBackendError(detail || 'Could not create room. Check the browser console for the Supabase error.')
    } finally {
      setBackendBusy(false)
    }
  }

  async function handleJoinRoom() {
    setBackendError('')
    const safeName = name.trim().replace(/\s+/g, ' ')
    const safeRoom = room.trim().toUpperCase()
    if (!safeName) { setBackendError('Enter your player name first.'); return }
    if (!safeRoom) { setBackendError('Enter a room code first.'); return }
    const normalizedName = safeName.toUpperCase().slice(0, 12)
    setName(normalizedName)
    localStorage.setItem(PLAYER_NAME_KEY, normalizedName)
    setProfileDraft(normalizedName)
    setRoom(safeRoom)
    if (!supabaseConfigured) {
      setPlayers(seedPlayers)
      setScreen('lobby')
      return
    }
    try {
      setBackendBusy(true)
      const joined = await joinBackendRoom(safeRoom, normalizedName)
      const sessionUser = (await supabase?.auth.getUser())?.data.user
      const resolvedUserId = sessionUser?.id ?? joined.userId
      setBackendRoomId(joined.room.id)
      setCurrentUserId(resolvedUserId)
      setRoom(joined.room.code)
      persistRoom({ roomId: joined.room.id, code: joined.room.code, userId: joined.userId, name: safeName.toUpperCase().slice(0, 12) })
      setBestOf(joined.room.best_of)
      setActiveCustomRules(joined.room.custom_rules ? JSON.parse(JSON.stringify(joined.room.custom_rules)) : null)
      const backendPlayers = await getRoomPlayers(joined.room.id)
      setPlayers(backendPlayers.map((p) => ({ id: p.user_id, name: p.display_name, human: true, isHost: p.is_host, isReady: p.is_ready })))
      setScreen('lobby')
    } catch (error) {
      console.error('Pick & Shoot join room error:', error)
      const detail = error && typeof error === 'object'
        ? [
            'message' in error ? String(error.message ?? '') : '',
            'code' in error ? `code=${String(error.code ?? '')}` : '',
            'details' in error ? `details=${String(error.details ?? '')}` : '',
            'hint' in error ? `hint=${String(error.hint ?? '')}` : '',
          ].filter(Boolean).join(' | ')
        : String(error ?? '')
      setBackendError(detail || 'Could not join room. Check the browser console for the Supabase error.')
    } finally {
      setBackendBusy(false)
    }
  }

  async function leaveGame() {
    const destination = pendingDestination ?? 'home'
    setShowLeaveConfirm(false)
    setPendingDestination(null)
    try {
      if (backendRoomId && supabaseConfigured) await leaveBackendRoom(backendRoomId)
    } catch (error) {
      setBackendError(error instanceof Error ? error.message : 'Could not leave room cleanly.')
    }
    clearPersistedRoom()
    setBackendRoomId(null)
    setCurrentUserId(null)
    setBackendMatchId(null)
    setBackendRoundId(null)
    setBackendPickDeadline(null)
    setBackendChoices(null)
    setBackendWinnerId(null)
    setSolo(false)
    setScreen(destination)
    setSelection(null)
    setOpponentThrow(null)
    setResult(null)
    setPhase('pick')
    setCountdown(5)
  }

  function requestNavigation(destination: Screen) {
    if (screen === 'match') {
      setPendingDestination(destination)
      setShowLeaveConfirm(true)
      return
    }
    setScreen(destination)
  }

  function attemptLeave() {
    requestNavigation('home')
  }

  function cancelToMultiplayer() {
    requestNavigation('multiplayer')
  }

  useEffect(() => {
    if (!supabase || !supabaseConfigured) return
    const raw = localStorage.getItem('pns_active_room')
    if (!raw || backendRoomId) return
    let saved: { roomId: string; code: string; userId: string; name: string } | null = null
    try { saved = JSON.parse(raw) } catch { clearPersistedRoom(); return }
    if (!saved) return
    let alive = true
    ;(async () => {
      try {
        const [sessionResult, savedRoom] = await Promise.all([supabase!.auth.getSession(), getRoom(saved!.roomId)])
        if (!alive || !sessionResult.data.session?.user) return
        const userId = sessionResult.data.session.user.id
        if (userId !== saved!.userId) { clearPersistedRoom(); return }
        const backendPlayers = await getRoomPlayers(saved!.roomId)
        if (!alive) return
        setCurrentUserId(userId); setBackendRoomId(saved!.roomId); setRoom(savedRoom.code); setName(saved!.name); setBestOf(savedRoom.best_of); setActiveCustomRules(savedRoom.custom_rules ? JSON.parse(JSON.stringify(savedRoom.custom_rules)) : null)
        setPlayers(backendPlayers.map((p) => ({ id: p.user_id, name: p.display_name, human: true, isHost: p.is_host, isReady: p.is_ready })))
        if (savedRoom.status === 'playing') {
          const state = await getCurrentMatchState(saved!.roomId)
          if (!alive) return
          setBackendMatchId(state.match_id); setBackendRoundId(state.round_id); setBackendPickDeadline(state.pick_deadline); setRound(state.round_number); setBestOf(state.best_of)
        if (state.custom_rules) setActiveCustomRules(JSON.parse(JSON.stringify(state.custom_rules)))
          if (state.choices) setBackendChoices(state.choices)
          if (state.winner_user_id) setBackendWinnerId(state.winner_user_id)
          setScreen('match')
        } else if (savedRoom.status === 'waiting') setScreen('lobby')
        else { clearPersistedRoom(); setScreen('home') }
      } catch (error) {
        console.warn('Pick & Shoot reconnect recovery:', error)
      }
    })()
    return () => { alive = false }
  }, [backendRoomId])

  useEffect(() => {
    if (!supabase || !supabaseConfigured || screen !== 'lobby' || !backendRoomId) return
    const client = supabase
    let alive = true
    const refresh = async () => {
      try {
        const [backendRoom, backendPlayers, authResult] = await Promise.all([getRoom(backendRoomId), getRoomPlayers(backendRoomId), client.auth.getUser()])
        if (!alive) return
        const resolvedUserId = authResult.data.user?.id ?? currentUserId
        if (resolvedUserId && resolvedUserId !== currentUserId) setCurrentUserId(resolvedUserId)
        setBestOf(backendRoom.best_of)
        setActiveCustomRules(backendRoom.custom_rules ? JSON.parse(JSON.stringify(backendRoom.custom_rules)) : null)
        setPlayers(backendPlayers.map((p) => ({ id: p.user_id, name: p.display_name, human: true, isHost: p.is_host, isReady: p.is_ready })))
        if (backendRoom.status === 'playing') {
          const state = await getTournamentState(backendRoomId)
          if (!alive) return
          setTournamentState(state)
          setRound(state.stageNumber)
          setScreen('match')
          showMatchIntro(state.stageNumber === 1 ? 'ROUND 1' : `ROUND ${state.stageNumber}`, 'GET READY', `load:${state.stageNumber}`)
        }
      } catch (error) { if (alive) setBackendError(error instanceof Error ? error.message : 'Could not refresh room.') }
    }
    void refresh()
    const poll = window.setInterval(() => { void refresh() }, 1500)
    const cleanup = subscribeToRoom(room, backendRoomId, () => { void refresh() }, (message) => console.warn(message))
    return () => { alive = false; window.clearInterval(poll); cleanup() }
  }, [screen, backendRoomId, room])

  useEffect(() => {
    if (!supabase || !supabaseConfigured || screen !== 'match' || solo || !backendRoomId) return
    let alive = true

    const scheduleTransition = (key: string, delay: number, action: () => Promise<unknown>) => {
      if (tournamentTransitionTimer.current !== null) return
      tournamentTransitionTimer.current = window.setTimeout(() => {
        tournamentTransitionTimer.current = null
        void action().catch((error) => {
          if (alive) console.warn('Pick & Shoot tournament transition:', error)
        })
      }, delay)
      return key
    }

    const sync = async () => {
      try {
        const state = await getTournamentState(backendRoomId)
        if (!alive) return
        setTournamentState(state)
        setBestOf(state.bestOf)
        setRound(state.stageNumber)

        const pairing = state.pairings.find((item) => item.id === state.yourPairingId) ?? null
        const isA = Boolean(pairing && currentUserId && pairing.playerA?.id === currentUserId)

        if (state.status === 'finished') {
          setChampionShown(true)
          setPhase('result')
          setResult(state.championUserId === currentUserId ? 'win' : 'lose')
          return
        }

        if (state.stageComplete && state.humanCount === 1) {
          showMatchIntro('TOURNAMENT RESULT', 'ONE HUMAN REMAINS', `champion:${state.stageNumber}`)
          scheduleTransition(`champion:${state.stageNumber}`, 2600, () => advanceTournamentStage(backendRoomId))
        } else if (state.stageComplete && state.humanCount > 1) {
          showMatchIntro('ROUND COMPLETE', 'NEXT STAGE LOADING', `stage:${state.stageNumber}`)
          scheduleTransition(`stage:${state.stageNumber}`, 3000, () => advanceTournamentStage(backendRoomId))
        }

        if (!pairing) {
          setBackendRoundId(null)
          setBackendPickDeadline(null)
          setBackendChoices(null)
          setSelection(null)
          setOpponentThrow(null)
          setPhase('result')
          setResult('lose')
          setChampionShown(false)
          return
        }

        setBackendMatchId(state.tournamentId)
        setBackendRoundId(pairing.roundId)
        setBackendPickDeadline(pairing.pickDeadline)
        setScore(isA ? { you: pairing.scoreA, opp: pairing.scoreB } : { you: pairing.scoreB, opp: pairing.scoreA })

        const resolved = pairing.resolvedChoices ?? null
        setBackendChoices(resolved as Record<string, ThrowId> | null)
        const selfChoice = currentUserId ? resolved?.[currentUserId] : undefined
        const opponentKey = pairing.againstRandomizer ? 'randomizer' : (isA ? pairing.playerB?.id : pairing.playerA?.id)
        const opponentChoice = opponentKey ? resolved?.[opponentKey] : undefined
        if (selfChoice) setSelection(selfChoice as ThrowId)
        if (opponentChoice) setOpponentThrow(opponentChoice as ThrowId)

        const submitted = state.currentRoundId === pairing.roundId && Boolean(state.currentUserSubmitted)
        setHasSubmitted(submitted)

        if (pairing.roundPhase === 'finished') {
          setPhase('result')
          setResult(
            pairing.roundWinnerUserId == null
              ? (pairing.againstRandomizer && pairing.roundRandomizerWon ? 'lose' : 'draw')
              : pairing.roundWinnerUserId === currentUserId ? 'win' : 'lose'
          )
          if (pairing.status !== 'finished') {
            showMatchIntro('ROUND COMPLETE', 'NEXT THROW LOADING', `pairing:${pairing.id}:${pairing.roundNumber}`)
            scheduleTransition(`pairing:${pairing.id}:${pairing.roundNumber}`, 2200, () => advanceTournamentPairing(pairing.id))
          }
        } else {
          setPhase(submitted ? 'reveal' : 'pick')
        }
      } catch (error) {
        if (alive) console.warn('Pick & Shoot tournament sync:', error)
      }
    }

    void sync()
    const poll = window.setInterval(() => { void sync() }, 500)
    const cleanup = subscribeToRoom(room, backendRoomId, () => { void sync() }, (message) => console.warn(message))
    return () => {
      alive = false
      window.clearInterval(poll)
      cleanup()
      if (tournamentTransitionTimer.current !== null) {
        window.clearTimeout(tournamentTransitionTimer.current)
        tournamentTransitionTimer.current = null
      }
    }
  }, [screen, solo, backendRoomId, room, currentUserId])

  const activeOptions = activeCustomRules?.items?.length ? activeCustomRules.items : THROWS
  const roundLoading = !solo && phase === 'pick' && countdown > 5
  const displayThrow = (id: ThrowId | null) => activeOptions.find((item) => item.id === id)

  return (
    <div className="app-shell">
      <div className="noise" />

      <header className="topbar">
        <button className="brand-lockup" onClick={attemptLeave} aria-label="Pick & Shoot home">
          <img src="/brand-emblem-transparent.png" alt="" className="brand-icon" />
          <span>
            <strong>PICK <em>&</em> SHOOT</strong>
            <small>MULTIPLAYER RPS</small>
          </span>
        </button>
        <div className="topbar-right">
          <button className="profile-trigger" onClick={() => { setProfileDraft(name); setProfileOpen(true) }} aria-label="Open profile">{(name || 'P').slice(0, 1)}</button>
        </div>
      </header>

      {screen === 'home' && (
        <main className="home-grid page-enter">
          <section className="hero-copy">
            <p className="eyebrow">ROCK · PAPER · SCISSORS · AND BEYOND</p>
            <h1>Pick fast.<br /><span>Shoot to win.</span></h1>
            <p className="hero-text">Fast rounds. Hidden picks. Real people. Build a room, join your friends, or test yourself against the Randomizer.</p>
            <div className="hero-actions mode-actions">
              <button className="primary mode-action" onClick={openMultiplayer}>
                <span className="action-icon">◉</span>
                <span><b>Play online</b><small>Create or join a room</small></span>
                <strong>→</strong>
              </button>
              <button className="secondary mode-action" onClick={startSoloMatch}>
                <span className="action-icon">✦</span>
                <span><b>Vs Randomizer</b><small>Single-player practice</small></span>
                <strong>→</strong>
              </button>
            </div>
            <div className="mini-stats">
              <div><b>5s</b><span>PICK WINDOW</span></div>
              <div><b>2–∞</b><span>PLAYERS</span></div>
              <div><b>{CUSTOM_PRESETS.length + customRulesets.length}</b><span>RULESETS</span></div>
            </div>
            <button className="custom-home-link" onClick={() => openCustomBuilder(customRulesets[0] ?? CUSTOM_PRESETS[0])}>
              <span className="custom-link-icon">✦</span>
              <span><b>Custom Rules</b><small>{customRulesets.length + CUSTOM_PRESETS.length} rulesets available · build or remix your own</small></span>
              <strong>→</strong>
            </button>
          </section>

          <section className="hero-stage">
            <div className="halo" />
            <img src="/brand-emblem-transparent.png" alt="Pick & Shoot emblem" className="hero-mark" />
            <div className="stage-caption">
              <span>READY TO PLAY</span>
              <b>YOUR MOVE.</b>
            </div>
          </section>

          <section className="feature-row">
            <article><span>01</span><b>5 SECOND RUSH</b><p>Pick before the clock locks your hand.</p></article>
            <article><span>02</span><b>TOURNAMENTS</b><p>Odd numbers? The Randomizer keeps everyone moving.</p></article>
            <article><span>03</span><b>CUSTOM RULES</b><p>Start with RPS. Expand the arena when you are ready.</p></article>
          </section>
        </main>
      )}

      {screen === 'multiplayer' && (
        <main className="center-page multiplayer-page page-enter">
          <div className="multiplayer-shell">
            <div className="panel-heading compact-heading">
              <div><p className="eyebrow">PLAY ONLINE</p><h2>Choose your way in.</h2></div>
              <button className="text-button" onClick={() => requestNavigation('home')}>Cancel</button>
            </div>
            <div className="multiplayer-grid">
              <button className="glass-card multiplayer-choice" onClick={() => requestNavigation('join')}>
                <span className="choice-icon">↗</span>
                <div><p className="eyebrow">ALREADY HAVE A CODE?</p><h3>Join a Room</h3><p>Enter an existing room code and jump straight into the lobby.</p></div>
                <strong>→</strong>
              </button>
              <button className="glass-card multiplayer-choice" onClick={() => requestNavigation('create')}>
                <span className="choice-icon">＋</span>
                <div><p className="eyebrow">HOST YOUR OWN GAME</p><h3>Create a Room</h3><p>Choose Classic or Custom rules, set the match format, then invite players.</p></div>
                <strong>→</strong>
              </button>
            </div>
            <div className="multiplayer-note"><span className="online-dot" /> {supabaseConfigured ? 'LIVE ROOMS CONNECTED · REALTIME BACKEND READY' : 'DEMO MODE · ADD SUPABASE ENVIRONMENT VARIABLES TO CONNECT LIVE ROOMS'}</div>{backendError && <p className="backend-error">{backendError}</p>}
          </div>
        </main>
      )}

      {screen === 'create' && (
        <main className="panel-page page-enter">
          <div className="panel-heading">
            <div><p className="eyebrow">NEW ROOM</p><h2>Set the arena.</h2></div>
            <button className="text-button" onClick={cancelToMultiplayer}>Cancel</button>
          </div>
          <div className="settings-grid create-single">
            <div className="glass-card tall">
              <label>Your name</label>
              <input value={name} onChange={(e) => setName(e.target.value.replace(/\s+/g, ' ').slice(0, 12))} placeholder="YOUR NAME" maxLength={12} autoComplete="nickname" />
              <label>Game mode</label>
              <div className="static-mode-label"><span>TOURNAMENT</span><small>Every multiplayer room is a tournament.</small></div>
              <label>Rules</label>
              <button className={selectedCustomId ? 'mode-card' : 'mode-card active'} onClick={() => setSelectedCustomId(null)}><b>Classic RPS</b><span>Rock · Paper · Scissors</span></button>
              <button className={selectedCustomId ? 'mode-card active' : 'mode-card'} onClick={() => openCustomBuilder(selectedCustomId ? selectedCustom : undefined)}><b>Custom</b><span>{selectedCustom?.name ?? 'Choose a saved or preset ruleset'}</span></button>
              {selectedCustomId && <button className="text-button custom-manage" onClick={() => setScreen('custom')}>Manage custom rules →</button>}
              <label>Match format</label>
              <div className="best-of-picker" aria-label="Choose match length">
                {FORMAT_OPTIONS.map((value) => (
                  <button key={value} className={bestOf === value ? 'active' : ''} onClick={() => setBestOf(value)}>Best of {value}</button>
                ))}
              </div>
              <button className="primary full" onClick={handleCreateRoom} disabled={backendBusy}>{backendBusy ? 'Connecting…' : 'Create room'} <span>→</span></button>{backendError && <p className="backend-error">{backendError}</p>}
            </div>

          </div>
        </main>
      )}

      {screen === 'join' && (
        <main className="center-page page-enter">
          <div className="glass-card join-card">
            <button className="back-button" onClick={cancelToMultiplayer} aria-label="Back to multiplayer">←</button>
            <p className="eyebrow">JOIN A ROOM</p>
            <h2>Jump into a room.</h2>
            <label>Your name</label>
            <input value={name} onChange={(e) => setName(e.target.value.replace(/\s+/g, ' ').slice(0, 12))} placeholder="YOUR NAME" maxLength={12} autoComplete="nickname" />
            <label>Room code</label>
            <input className="code-input" value={room} onChange={(e) => setRoom(e.target.value.replace(/[^a-z0-9]/gi, '').toUpperCase().slice(0, 5))} placeholder="ROOM CODE" maxLength={5} autoComplete="off" />
            <button className="primary full" onClick={handleJoinRoom} disabled={backendBusy || !name.trim() || !room.trim()}>{backendBusy ? 'Joining…' : 'Join room'} <span>→</span></button>{backendError && <p className="backend-error">{backendError}</p>}
            <button className="secondary full cancel-action" onClick={cancelToMultiplayer}>Cancel</button>
          </div>
        </main>
      )}


      {screen === 'solo-settings' && (
        <main className="center-page page-enter">
          <section className="glass-card solo-settings-card">
            <div className="panel-heading">
              <div><p className="eyebrow">VS RANDOMIZER</p><h2>Set your match.</h2></div>
              <button className="text-button" onClick={() => setScreen('home')}>Cancel</button>
            </div>
            <div className="solo-setting-group">
              <label>Match format</label>
              <div className="best-of-picker">
                {FORMAT_OPTIONS.map((value) => <button key={value} className={soloBestOf === value ? 'active' : ''} onClick={() => setSoloBestOf(value)}>Best of {value}</button>)}
              </div>
            </div>
            <div className="solo-setting-group">
              <label>Rules</label>
              <button className={`mode-card ${soloCustomId === null ? 'active' : ''}`} onClick={() => setSoloCustomId(null)}><b>Classic RPS</b><span>Rock · Paper · Scissors</span></button>
              {customRulesets.length > 0 && <div className="solo-rules-grid">{customRulesets.map((ruleset) => <button key={ruleset.id} className={`mode-card ${soloCustomId === ruleset.id ? 'active' : ''}`} onClick={() => setSoloCustomId(ruleset.id)}><b>{ruleset.name}</b><span>{ruleset.items.length} items · your custom</span></button>)}</div>}
              <div className="preset-mini-row">{CUSTOM_PRESETS.map((ruleset) => <button key={ruleset.id} className={`preset-mini ${soloCustomId === ruleset.id ? 'active' : ''}`} onClick={() => setSoloCustomId(ruleset.id)}>{ruleset.name}</button>)}</div>
            </div>
            <button className="primary full" onClick={launchSoloMatch}>Start match <span>→</span></button>
          </section>
        </main>
      )}

      {screen === 'custom' && customDraft && (
        <main className="panel-page page-enter">
          <div className="panel-heading">
            <div><p className="eyebrow">CUSTOM RULES</p><h2>Build your arena.</h2></div>
            <button className="text-button" onClick={() => setScreen('create')}>Back</button>
          </div>
          <div className="custom-layout">
            <section className="glass-card custom-builder">
              <label>Ruleset name</label>
              <input value={customDraft.name} onChange={(e) => updateCustomName(e.target.value)} placeholder="NAME YOUR RULES" maxLength={28} />
              <div className="custom-builder-head"><span>{customDraft.items.length} ITEMS</span><button className="secondary" onClick={addCustomItem} disabled={customDraft.items.length >= 9}>+ Add item</button></div>
              <div className="custom-items">
                {customDraft.items.map((item) => (
                  <div className="custom-item-row" key={item.id}>
                    <input value={item.glyph} onChange={(e) => updateCustomItem(item.id, { glyph: e.target.value.slice(0, 2) })} aria-label={`${item.label} icon`} className="custom-glyph-input" />
                    <input value={item.label} onChange={(e) => updateCustomItem(item.id, { label: e.target.value.slice(0, 18) })} aria-label={`${item.label} name`} />
                    <button className="icon-button" onClick={() => removeCustomItem(item.id)} disabled={customDraft.items.length <= 3}>×</button>
                  </div>
                ))}
              </div>
              <div className="rules-matrix">
                <div className="custom-builder-head"><span>WHAT DOES EACH ITEM BEAT?</span><small>Pick exactly {(customDraft.items.length - 1) / 2} for balance.</small></div>
                {customDraft.items.map((source) => (
                  <div className="rule-row" key={source.id}><b>{source.glyph} {source.label}</b><div>{customDraft.items.filter((target) => target.id !== source.id).map((target) => <button key={target.id} className={customDraft.beats[source.id]?.includes(target.id) ? 'rule-chip active' : 'rule-chip'} onClick={() => toggleCustomBeat(source.id, target.id)}>{target.glyph} {target.label}</button>)}</div></div>
                ))}
              </div>
              <div className={`balance-status ${customIsBalanced(customDraft) ? 'ok' : ''}`}>{customIsBalanced(customDraft) ? '✓ Balanced ruleset ready to save.' : `Build a balanced ruleset: each item must beat ${(customDraft.items.length - 1) / 2} and lose to the rest.`}</div>
              <button className="primary full" disabled={!customIsBalanced(customDraft) || !customDraft.name.trim()} onClick={() => { const presetMatch = CUSTOM_PRESETS.some((item) => rulesetSignature(item) === rulesetSignature(customDraft)); saveCustomRuleset({ ...customDraft, system: 'user' }); if (!presetMatch || customRulesets.some((item) => item.id === customDraft.id)) setScreen('create') }}>{customRulesets.some((item) => item.id === customDraft.id) ? 'Save changes' : 'Save to My Customs'} <span>→</span></button>
            </section>
            <aside className="glass-card custom-library">
              <div className="custom-library-top">
                <div><p className="eyebrow">RULE LIBRARY</p><h3>Start from something proven.</h3></div>
                <button className="secondary add-custom-button" onClick={() => openCustomBuilder()}>＋ New custom</button>
              </div>
              {CUSTOM_PRESETS.map((ruleset) => (
                <div className={`saved-rule-card ${selectedCustomId === ruleset.id ? 'active' : ''}`} key={ruleset.id}>
                  <button className="saved-rule-main" onClick={() => { setSelectedCustomId(ruleset.id); setCustomDraft(JSON.parse(JSON.stringify(ruleset))) }}>
                    <span>PRESET</span><b>{ruleset.name}</b><small>{ruleset.items.length} items · balanced</small>
                  </button>
                  <div className="saved-rule-actions"><button className="text-button" onClick={() => openCustomBuilder(ruleset)}>Remix</button></div>
                </div>
              ))}
              <div className="saved-customs-header"><span>MY CUSTOMS</span><small>{customRulesets.length} saved</small></div>
              {customRulesets.length === 0 ? (
                <div className="saved-empty">No saved custom rules yet.<br />Build one and save it here.</div>
              ) : customRulesets.map((ruleset) => (
                <div className={`saved-rule-card saved-user-rule ${selectedCustomId === ruleset.id ? 'active' : ''}`} key={ruleset.id}>
                  <button className="saved-rule-main" onClick={() => { setSelectedCustomId(ruleset.id); setCustomDraft(JSON.parse(JSON.stringify(ruleset))) }}>
                    <span>SAVED</span><b>{ruleset.name}</b><small>{ruleset.items.length} items · balanced</small>
                  </button>
                  <div className="saved-rule-actions"><button className="text-button" onClick={() => { setCustomDraft(JSON.parse(JSON.stringify(ruleset))); setSelectedCustomId(ruleset.id); setScreen('custom') }}>Edit</button><button className="delete-rule" onClick={() => deleteCustomRuleset(ruleset.id)}>Delete</button></div>
                </div>
              ))}
              <p className="custom-tip">Presets stay permanent. Your saved customs can be edited, replaced, deleted, and saved from other rooms.</p>
            </aside>
          </div>
        </main>
      )}

      {screen === 'lobby' && (
        <main className="panel-page page-enter">
          <div className="panel-heading">
            <div><p className="eyebrow">ROOM {room}</p><h2>Ready when you are.</h2></div>
            <button className="text-button" onClick={() => requestNavigation('multiplayer')}>Leave lobby</button>
          </div>
          <div className="lobby-layout">
            <section className="glass-card players-card">
              <div className="card-head"><b>PLAYERS</b><span>{players.length} HUMANS</span></div>
              <div className="player-list">
                {players.map((player) => (
                  <div className="player-row" key={player.id}>
                    <div className="avatar">{player.name.slice(0, 2)}</div>
                    <div><b>{player.name}</b><span>{player.isHost ? (player.isReady ? 'HOST · READY' : 'HOST · NOT READY') : player.isReady ? 'READY' : 'NOT READY'}</span></div>
                    {player.isHost && <em>♛</em>}
                  </div>
                ))}
              </div>
              {currentPlayer && (
                <div className="your-ready-bar">
                  <div><span className="eyebrow">YOUR STATUS</span><b>{currentPlayer.isReady ? 'READY TO PLAY' : 'NOT READY'}</b></div>
                  <button className={`ready-toggle ${currentPlayer.isReady ? 'active' : ''}`} onClick={handleToggleReady} disabled={backendBusy}>
                    {currentPlayer.isReady ? 'READY ✓' : 'READY UP'}
                  </button>
                </div>
              )}
              {room && currentUserId && players.find((player) => player.id === currentUserId)?.isHost ? (
                <button className="primary full" onClick={handleStartTournament} disabled={players.length < 2 || backendBusy || !allPlayersReady}>
                  {players.length < 2 ? 'Waiting for players…' : !allPlayersReady ? 'Waiting for everyone…' : backendBusy ? 'Starting…' : 'Start tournament'} <span>→</span>
                </button>
              ) : (
                <div className="lobby-waiting"><span className="online-dot" /> Waiting for the host to start the tournament.</div>
              )}
            </section>
            <section className="lobby-side">
              <div className="glass-card room-card"><span className="eyebrow">ROOM CODE</span><strong>{room}</strong><button onClick={() => navigator.clipboard?.writeText(room)}>Copy invite</button></div>
              <div className="glass-card room-card format-room-card"><span className="eyebrow">FORMAT</span><strong>TOURNAMENT</strong><span>5s picks · Classic RPS · Randomizer balances odd brackets</span>
                <label>BEST OF</label>
                <div className="best-of-picker compact" aria-label="Edit match length">
                  {FORMAT_OPTIONS.map((value) => (
                    <button key={value} className={bestOf === value ? 'active' : ''} onClick={() => setBestOf(value)}>BO{value}</button>
                  ))}
                </div>
                <small>First to {Math.ceil(bestOf / 2)} wins.</small>
              </div>
            </section>
          </div>
        </main>
      )}

      {screen === 'match' && (
        <main className="match-page page-enter">
          {matchIntro && <div className="match-intro" aria-live="polite"><div className="match-intro-card"><span className="eyebrow">PICK &amp; SHOOT</span><h3>{matchIntro.title}</h3><p>{matchIntro.subtitle}</p><div className="match-intro-pulse" /></div></div>}
          <div className="match-topline">
            <div>
              <span className="eyebrow">{solo ? 'SOLO · VS RANDOMIZER' : tournamentState ? (tournamentState.pairings.length === 1 && tournamentState.humanCount === 2 ? 'THE FINAL' : tournamentState.pairings.length === 2 && tournamentState.humanCount === 4 ? 'SEMIFINALS' : tournamentState.pairings.length === 4 && tournamentState.humanCount === 8 ? 'QUARTERFINALS' : `ROUND ${tournamentState.stageNumber}`) : `ROUND ${round}`}</span>
              <div className="match-format"><h2>Best of {bestOf}</h2><div className="best-of-picker tiny" aria-label="Match format">{FORMAT_OPTIONS.map((value) => <button key={value} className={bestOf === value ? 'active' : ''} disabled>{`BO${value}`}</button>)}</div></div>
            </div>
            <div className="match-score"><b>{score.you}</b><span>:</span><b>{score.opp}</b></div>
          </div>

          {!solo && tournamentState && (
            <section className="tournament-board glass-card">
              <div className="tournament-board-head"><div><span className="eyebrow">TOURNAMENT BOARD</span><b>STAGE {tournamentState.stageNumber}</b></div><span>{tournamentState.humanCount} HUMANS REMAIN</span></div>
              <div className="pairing-grid">
                {tournamentState.pairings.map((pairing) => {
                  const mine = pairing.id === tournamentState.yourPairingId
                  const winnerName = pairing.winnerUserId ? (pairing.playerA?.id === pairing.winnerUserId ? pairing.playerA?.name : pairing.playerB?.name) : null
                  return <div className={`pairing-card ${mine ? 'mine' : ''} ${pairing.status === 'finished' ? 'finished' : ''}`} key={pairing.id}>
                    <div><b>{pairing.playerA?.name ?? 'PLAYER'}</b><span>{pairing.scoreA}</span></div>
                    <div className="pairing-vs">{pairing.againstRandomizer ? 'VS 🎲' : 'VS'}</div>
                    <div>{pairing.againstRandomizer ? <><b>RANDOMIZER</b><span>{pairing.scoreB}</span></> : <><b>{pairing.playerB?.name ?? 'PLAYER'}</b><span>{pairing.scoreB}</span></>}</div>
                    <small>{pairing.status === 'finished' ? (winnerName ? `${winnerName} ADVANCES` : pairing.randomizerWon ? 'RANDOMIZER ELIMINATED PLAYER' : 'DRAW') : mine ? 'YOUR MATCH' : 'IN PROGRESS'}</small>
                  </div>
                })}
              </div>
            </section>
          )}

          {!solo && !currentPairing ? (
            <section className="glass-card tournament-watching">
              <span className="eyebrow">ELIMINATED</span>
              <h3>You're out.</h3>
              <p>Watch the remaining matches. The tournament will continue without you.</p>
              {tournamentState?.status !== 'finished' && <div className="lobby-waiting"><span className="online-dot" /> Waiting for the next stage…</div>}
            </section>
          ) : (
            <>
              <div className="duel">
                <section className="fighter self"><div className="fighter-name">YOU <span>{(currentPlayer?.name ?? name.toUpperCase()) || 'PLAYER'}</span></div><div className={`throw-card ${selection ? 'locked' : ''}`}><span>{selection ? displayThrow(selection)?.glyph : '?'}</span></div><small>{selection ? (hasSubmitted ? 'SHOT LOCKED' : 'SELECTED') : 'CHOOSE YOUR THROW'}</small></section>
                <div className="versus"><span>{phase === 'pick' && !hasSubmitted ? (roundLoading ? '…' : countdown) : 'VS'}</span><small>{phase === 'pick' && !hasSubmitted ? (roundLoading ? 'GET READY' : 'SECONDS') : 'PICK & SHOOT'}</small></div>
                <section className="fighter opp"><div className="fighter-name"><span>{matchOpponent.name}</span>{matchOpponent.id === 'randomizer' ? '' : ' OP'}</div><div className={`throw-card ${phase !== 'pick' ? 'locked' : ''}`}><span>{phase === 'result' && opponentThrow ? displayThrow(opponentThrow)?.glyph : '✦'}</span></div><small>{phase === 'pick' ? 'HIDDEN' : phase === 'reveal' ? 'REVEALING' : 'REVEALED'}</small></section>
              </div>
              {phase === 'pick' && roundLoading && <div className="round-loading"><span className="eyebrow">GET READY</span><b>Next throw loading…</b></div>}
              {phase === 'pick' && !hasSubmitted && !roundLoading && (
                <div className="throw-picker">
                  {activeOptions.map((item) => <button key={item.id} className={selection === item.id ? 'picked' : ''} onClick={() => setSelection(item.id)}><span>{item.glyph}</span><small>{item.label}</small></button>)}
                  <button className={`shoot-button ${selection ? 'ready' : ''}`} onClick={() => lockIn()} disabled={!selection || backendBusy} aria-label="Shoot"><strong>{backendBusy ? 'SENDING' : 'SHOOT'}</strong><span className="shoot-arrow">↗</span></button>
                </div>
              )}
              {phase === 'reveal' && <div className="reveal-banner"><span>{hasSubmitted ? 'SHOT LOCKED' : 'LOCKED'}</span><b>{tournamentState && currentPairing?.roundPhase === 'finished' ? 'REVEALING…' : 'WAITING FOR OPPONENT…'}</b></div>}
              {phase === 'result' && (
                <div className="result-panel">
                  <div><span className="eyebrow">{tournamentState?.status === 'finished' ? 'TOURNAMENT RESULT' : currentPairing?.status === 'finished' ? 'MATCH RESULT' : 'ROUND RESULT'}</span><h3>{tournamentState?.status === 'finished' ? (tournamentState.championUserId === currentUserId ? 'CHAMPION.' : 'TOURNAMENT OVER.') : currentPairing?.status === 'finished' ? (result === 'win' ? 'YOU ADVANCE.' : 'YOU’RE OUT.') : (result === 'win' ? 'YOU WIN.' : result === 'lose' ? 'YOU LOSE.' : 'DRAW.')}</h3><p>{selection && opponentThrow ? `${displayThrow(selection)?.label} vs ${displayThrow(opponentThrow)?.label}` : ''}</p></div>
                  {!solo && tournamentState && tournamentState.stageComplete && (
                    <div className="stage-hierarchy" aria-label="Stage results">
                      <div className="stage-hierarchy-head"><span className="eyebrow">STAGE RESULTS</span><b>{tournamentState.humanCount <= 2 ? 'FINALISTS' : 'SURVIVORS'}</b></div>
                      <div className="hierarchy-list">
                        {tournamentState.pairings.filter((pairing) => pairing.status === 'finished').map((pairing, index) => {
                          const winnerId = pairing.randomizerWon ? null : pairing.winnerUserId
                          const winnerName = winnerId ? (pairing.playerA?.id === winnerId ? pairing.playerA?.name : pairing.playerB?.name) : null
                          return <div className="hierarchy-row" key={pairing.id} style={{ animationDelay: `${index * 90}ms` }}>
                            <span className="hierarchy-rank">{index + 1}</span>
                            <span className="hierarchy-line" />
                            <b>{winnerName ?? 'RANDOMIZER'}</b>
                            <small>{pairing.randomizerWon ? 'BALANCING MATCH' : 'ADVANCES'}</small>
                          </div>
                        })}
                      </div>
                    </div>
                  )}
                  <div className="result-actions">
                    {activeCustomRules && <button className="secondary" onClick={saveActiveRulesToDevice}>♡ Save rules</button>}
                    {tournamentState?.status === 'finished'
                      ? <button className="primary" onClick={() => leaveGame()}>Back home <span>→</span></button>
                      : currentPairing?.status === 'finished'
                        ? <button className="primary" disabled={Boolean(matchIntro)} onClick={() => nextRound()}>Continue <span>→</span></button>
                        : <button className="primary" disabled={Boolean(matchIntro)} onClick={() => nextRound()}>Next round <span>→</span></button>}
                  </div>
                </div>
              )}
            </>
          )}
        </main>
      )}

      {showNameOnboarding && (
        <div className="modal-backdrop">
          <div className="leave-modal name-onboarding" role="dialog" aria-modal="true">
            <p className="eyebrow">WELCOME TO PICK & SHOOT</p><h3>What should we call you?</h3>
            <p>Your name is saved on this device. You can change it anytime from your profile.</p>
            <input autoFocus value={profileDraft} onChange={(e) => setProfileDraft(e.target.value.replace(/\s+/g, ' ').slice(0, 12))} placeholder="YOUR NAME" maxLength={12} />
            <button className="primary full" disabled={!profileDraft.trim()} onClick={() => { const clean = profileDraft.trim().replace(/\s+/g, ' ').toUpperCase().slice(0, 12); localStorage.setItem(PLAYER_NAME_KEY, clean); setName(clean); setProfileDraft(clean); setShowNameOnboarding(false) }}>Continue <span>→</span></button>
          </div>
        </div>
      )}

      {profileOpen && (
        <div className="modal-backdrop" onMouseDown={() => setProfileOpen(false)}>
          <div className="leave-modal profile-modal" onMouseDown={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
            <p className="eyebrow">PLAYER PROFILE</p><h3>Change your name.</h3>
            <input autoFocus value={profileDraft} onChange={(e) => setProfileDraft(e.target.value.replace(/\s+/g, ' ').slice(0, 12))} placeholder="YOUR NAME" maxLength={12} />
            <div className="modal-actions"><button className="secondary" onClick={() => setProfileOpen(false)}>Cancel</button><button className="primary" onClick={() => { const clean = profileDraft.trim().replace(/\s+/g, ' ').toUpperCase().slice(0, 12); localStorage.setItem(PLAYER_NAME_KEY, clean); setName(clean); setProfileDraft(clean); setProfileOpen(false) }}>Save</button></div>
          </div>
        </div>
      )}

      <footer className="footer"><span>PICK & SHOOT · 0.1</span><span>SAME GAME. BIGGER PLAYGROUND.</span></footer>

      <nav className="floating-nav" aria-label="Game navigation">
        <button className={screen === 'match' ? 'danger-nav' : ''} onClick={attemptLeave}>{screen === 'match' ? 'LEAVE' : 'HOME'}</button>
        <button onClick={openJoinRoom}>JOIN ROOM</button>
        <button onClick={() => requestNavigation('create')}>CREATE ROOM</button>
      </nav>

      {showLeaveConfirm && (
        <div className="modal-backdrop" role="presentation">
          <div className="leave-modal" role="dialog" aria-modal="true" aria-labelledby="leave-title">
            <div className="leave-icon">↪</div>
            <p className="eyebrow">LEAVE MATCH</p>
            <h3 id="leave-title">Leave the game?</h3>
            <p>You'll exit this room and forfeit your current progress in this match.</p>
            <div className="modal-actions">
              <button className="secondary" onClick={() => setShowLeaveConfirm(false)}>Cancel</button>
              <button className="danger-button" onClick={leaveGame}>Leave game</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

export function App() {
  return (
    <AppErrorBoundary>
      <AppContent />
    </AppErrorBoundary>
  )
}

