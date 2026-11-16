/**
 * Cuándo una consulta que falla merece un aviso global (INF-2, #1600).
 *
 * `QueryCache.onError` avisaba en CADA fallo, con un aviso que además persistía:
 * con una señal que no pasa datos, las consultas de fondo (la campana cada 60 s,
 * los sondeos por intervalo) sumaban una copia igual tras otra y expulsaban los
 * avisos importantes. Ahora:
 *
 *  - Una consulta marcada `meta.silentError` no avisa (ya muestra su error adentro).
 *  - Una consulta que ya tenía datos y falla al refrescarse (o que se sondea por
 *    intervalo) es de fondo: la pantalla sigue mostrando lo que tenía, así que sólo
 *    avisa una vez cada `ESPERA_AVISO_DE_FONDO_MS`, no en cada intento.
 *  - La que falla al cargar por primera vez avisa siempre; que el mismo texto no se
 *    repita mientras siga en pantalla lo resuelve `NotificationContext`.
 *
 * El aviso en sí no persiste: se va solo, como cualquier error común.
 */

export const ESPERA_AVISO_DE_FONDO_MS = 5 * 60 * 1000

interface ConsultaMinima {
  meta?: Record<string, unknown> | undefined
  state: { data: unknown }
  /** El `refetchInterval` es opción de quien observa la consulta, no de la consulta. */
  observers: ReadonlyArray<{ options: { refetchInterval?: unknown } }>
}

/** La consulta ya mostraba datos, o se sondea sola: su falla no deja la pantalla vacía. */
export function esConsultaDeFondo(consulta: ConsultaMinima): boolean {
  if (consulta.state.data !== undefined) return true
  return consulta.observers.some(o => {
    const intervalo = o.options.refetchInterval
    return intervalo !== undefined && intervalo !== false
  })
}

/**
 * Un filtro con memoria propia: la espera de las consultas de fondo es de toda la
 * app (no una por consulta), porque lo que molesta es la pila de avisos, no cuál
 * consulta la causó.
 */
export function crearFiltroDeAvisosDeConsulta(ahora: () => number = Date.now): (consulta: ConsultaMinima) => boolean {
  let ultimoAvisoDeFondo: number | null = null
  return consulta => {
    if (consulta.meta?.silentError) return false
    if (!esConsultaDeFondo(consulta)) return true
    const t = ahora()
    if (ultimoAvisoDeFondo !== null && t - ultimoAvisoDeFondo < ESPERA_AVISO_DE_FONDO_MS) return false
    ultimoAvisoDeFondo = t
    return true
  }
}
