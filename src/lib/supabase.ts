import { createClient } from '@supabase/supabase-js'
import { respuestaDeErrorLegible } from '../utils/errorDeSupabase'
import { esMotivoDeUsuarioDesactivado, pedirRevalidacionDelPerfil } from '../utils/revalidarPerfil'

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

/** `distribuidora/<build>`, lo que el fetch de abajo le suma al X-Client-Info. */
export const MARCA_DE_BUILD = `distribuidora/${typeof __APP_BUILD_ID__ === 'string' ? __APP_BUILD_ID__ : 'dev'}`

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
    // Apagado (1600-b1). Con `true`, un link con `#access_token=...` abría esa sesión sin
    // preguntar: el visitante de un link ajeno quedaba logueado en la cuenta de otro. La app
    // sólo entra por `signInWithPassword` (LoginScreen) y no tiene pantalla de «recuperar
    // contraseña», de invitación ni de magic link —tampoco el `updateUser` que pondría la
    // contraseña—, así que ningún flujo necesita leer un token de la URL. Si algún día se
    // suma uno, que lo pida a propósito (`exchangeCodeForSession` / `setSession`).
    detectSessionInUrl: false,
  },
  global: {
    // Sin plazo a propósito: por acá pasan las subidas a Storage y las descargas
    // largas, y un plazo global las cortaría aunque estén andando. El que necesita
    // uno (el replay de la cola, #1303) pasa su `signal`, que viaja en `init`.
    fetch: async (input, init) => {
      const headers = new Headers(init?.headers)
      // Un request que ya trae su sucursal la conserva: es el replay de la cola,
      // que manda la de cada operación sin tocar la global (INF-2, #1563).
      if (currentSucursalId != null && !headers.has('X-Sucursal-ID')) {
        headers.set('X-Sucursal-ID', String(currentSucursalId))
      }
      // El build que hace el pedido, al final del X-Client-Info que ya pone supabase-js
      // (#1601, 1601-b5): los logs del gateway guardan ese header, y es la forma de medir si
      // todavía hay teléfonos con un bundle viejo antes de cerrar una columna (sin la marca =
      // un bundle anterior a esta). No es un header nuevo: no cambia el CORS.
      const clientInfo = headers.get('X-Client-Info')
      if (clientInfo && !clientInfo.includes(MARCA_DE_BUILD)) {
        headers.set('X-Client-Info', `${clientInfo} ${MARCA_DE_BUILD}`)
      }
      const respuesta = await fetch(input, { ...init, headers })
      if (!respuesta.ok && String(input).includes('/rest/v1/rpc/')) {
        // Una RPC que rechaza con «Usuario desactivado»: `useAuth` confirma con el perfil (1600-b15).
        void respuesta.clone().text().then(cuerpo => {
          if (esMotivoDeUsuarioDesactivado(cuerpo)) pedirRevalidacionDelPerfil()
        }).catch(() => {})
      }
      return String(input).includes('/rest/v1/') ? respuestaDeErrorLegible(respuesta) : respuesta
    },
  },
})
