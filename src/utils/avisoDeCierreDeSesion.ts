/**
 * Por qué se cerró la sesión, para decírselo al usuario en la pantalla de ingreso
 * (1600-b6, #1600).
 *
 * El cierre por inactividad disparaba un evento de `window` que nadie escuchaba: el
 * usuario volvía al login sin saber por qué. Ahora quien cierra la sesión deja acá
 * el motivo y `LoginScreen` lo muestra una vez. Va a `localStorage` (con respaldo en
 * memoria si no hay storage) porque el cierre limpia el estado de React: es lo único
 * que sobrevive hasta que se monta el login.
 */

export type MotivoDeCierre = 'inactividad' | 'desactivado'

const CLAVE = 'sesion:motivo-de-cierre'

let enMemoria: MotivoDeCierre | null = null

export const MENSAJES_DE_CIERRE: Record<MotivoDeCierre, string> = {
  inactividad: 'Tu sesión se cerró por inactividad. Ingresá de nuevo para seguir.',
  // 1600-b15: un desactivado con el token todavía vivo veía la app vacía, sin explicación.
  desactivado: 'Tu usuario está desactivado, así que no podés usar la app. Consultá con el administrador.',
}

function esMotivo(valor: unknown): valor is MotivoDeCierre {
  return typeof valor === 'string' && valor in MENSAJES_DE_CIERRE
}

export function guardarAvisoDeCierre(motivo: MotivoDeCierre): void {
  enMemoria = motivo
  try {
    localStorage.setItem(CLAVE, motivo)
  } catch {
    // Sin storage queda en memoria, que alcanza mientras no se recargue la app.
  }
}

/** El motivo pendiente, sin borrarlo (se puede leer en un render que React repite). */
export function leerAvisoDeCierre(): MotivoDeCierre | null {
  try {
    const guardado = localStorage.getItem(CLAVE)
    if (esMotivo(guardado)) return guardado
  } catch {
    // Cae al respaldo en memoria.
  }
  return enMemoria
}

/** Lo da por visto: el próximo ingreso no lo repite. */
export function olvidarAvisoDeCierre(): void {
  enMemoria = null
  try {
    localStorage.removeItem(CLAVE)
  } catch {
    // Sin storage no hay nada guardado que borrar.
  }
}
