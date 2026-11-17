/**
 * Pedirle a `useAuth` que vuelva a leer el perfil (1600-b15, a mitad de sesión).
 *
 * Las sesiones no caducan, así que un usuario desactivado seguiría con la app abierta. `useAuth`
 * revalida el perfil al volver el foco o la red y cada tanto; además, quien se entera antes —una RPC
 * que contesta «Usuario desactivado»— se lo pide por acá. Es un evento de `window` y no un import de
 * `useAuth` para que `lib/supabase` y los contextos no dependan de él (ciclo de imports).
 */
export const EVENTO_REVALIDAR_PERFIL = 'perfil:revalidar'

/**
 * El server dice que el usuario está desactivado: «Usuario desactivado» (`cambiar_sucursal`),
 * «Tu usuario está desactivado.» (`generar_codigo_vinculacion_bot`). Sólo dispara la relectura del
 * propio perfil; quien decide si se cierra la sesión es `useAuth`, con la fila.
 */
export function esMotivoDeUsuarioDesactivado(texto: unknown): boolean {
  return typeof texto === 'string' && /usuario (est[aá] )?desactivado/i.test(texto)
}

export function pedirRevalidacionDelPerfil(): void {
  try {
    window.dispatchEvent(new Event(EVENTO_REVALIDAR_PERFIL))
  } catch {
    // Sin window no hay nadie a quien avisar.
  }
}
