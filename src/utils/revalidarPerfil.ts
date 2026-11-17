/**
 * Pedirle a `useAuth` que vuelva a leer el perfil (1600-b15, a mitad de sesión).
 *
 * Las sesiones no caducan, así que un usuario desactivado seguiría con la app abierta. `useAuth`
 * revalida el perfil al volver el foco o la red y cada tanto; además, quien se entera antes —una RPC
 * que contesta «Usuario desactivado»— se lo pide por acá. Es un evento de `window` y no un import de
 * `useAuth` para que `lib/supabase` y los contextos no dependan de él (ciclo de imports).
 */
export const EVENTO_REVALIDAR_PERFIL = 'perfil:revalidar'

/** El server dice que el usuario está desactivado (el motivo que mandan las RPC). */
export function esMotivoDeUsuarioDesactivado(texto: unknown): boolean {
  return typeof texto === 'string' && /usuario desactivado/i.test(texto)
}

export function pedirRevalidacionDelPerfil(): void {
  try {
    window.dispatchEvent(new Event(EVENTO_REVALIDAR_PERFIL))
  } catch {
    // Sin window no hay nadie a quien avisar.
  }
}
