export type ThrowId = string

export type GameOption = { id: string; label: string; glyph: string; beats?: string }

export const THROWS: GameOption[] = [
  { id: 'rock', label: 'Rock', glyph: '✊', beats: 'scissors' },
  { id: 'paper', label: 'Paper', glyph: '✋', beats: 'rock' },
  { id: 'scissors', label: 'Scissors', glyph: '✌', beats: 'paper' },
]

export function resolve(a: ThrowId, b: ThrowId, beats: Record<string, string[]> = Object.fromEntries(THROWS.map((item) => [item.id, item.beats ? [item.beats] : []]))): 'a' | 'b' | 'draw' {
  if (a === b) return 'draw'
  return (beats[a] ?? []).includes(b) ? 'a' : 'b'
}

export function pickRandomThrow(options: GameOption[] = THROWS): ThrowId {
  return options[Math.floor(Math.random() * options.length)]?.id ?? 'rock'
}
