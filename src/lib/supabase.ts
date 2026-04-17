import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

/**
 * Module-level sucursal id used by the fetch wrapper below to inject the
 * X-Sucursal-ID header on every PostgREST request. This header is the
 * session-scoped tenant resolver consumed by current_sucursal_id() in
 * migration 061. Keeping the value at module scope (instead of mutating
 * supabase.rest.headers) means each browser tab has its own independent
 * value -- which is exactly the H10 fix.
 */
let currentSucursalId: number | null = null

/**
 * Set or clear the X-Sucursal-ID header that is attached to every
 * subsequent Supabase REST request from this tab. Pass null to clear it
 * (e.g. on sign-out or when the user has no sucursales assigned).
 */
export function setSucursalHeader(sucursalId: number | null): void {
  currentSucursalId = sucursalId
}

/**
 * Expose the current sucursal id that the fetch wrapper would attach.
 * Used by offline replay to restore the header after per-op overrides.
 */
export function getSucursalHeader(): number | null {
  return currentSucursalId
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    storageKey: 'distribuidora_v2',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
  global: {
    fetch: (input, init) => {
      const headers = new Headers(init?.headers)
      if (currentSucursalId != null) {
        headers.set('X-Sucursal-ID', String(currentSucursalId))
      }
      return fetch(input, { ...init, headers })
    },
  },
})
