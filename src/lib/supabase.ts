import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined

export const supabaseConfigured = Boolean(url && publishableKey)

export const supabase = supabaseConfigured
  ? createClient(url!, publishableKey!, {
      auth: {
        autoRefreshToken: true,
        persistSession: true,
        detectSessionInUrl: true,
      },
    })
  : null

export async function ensureAnonymousSession(displayName: string) {
  if (!supabase) throw new Error('Supabase is not configured.')

  const { data: current } = await supabase.auth.getSession()
  if (current.session?.user) return current.session.user

  const { data, error } = await supabase.auth.signInAnonymously({
    options: { data: { display_name: displayName } },
  })

  if (error) throw error
  if (!data.user) throw new Error('Supabase did not return an anonymous user.')
  return data.user
}
