/**
 * D57 (decisión del dueño, 1563-b8 de #1563): cuando hay una versión nueva de la
 * app, se actualiza sola al volver a la app o al cambiar de pantalla, con aviso.
 *
 * Antes el salto era opcional: el cartel tenía «Más tarde» y el bundle viejo podía
 * seguir días llamando a una RPC cuya firma ya había cambiado. Ahora el cartel
 * avisa que se va a actualizar y el salto llega en el próximo momento en que no
 * se pierde nada.
 *
 * Lo que sigue frenando el salto, aun obligatorio:
 * - un modal abierto o un campo en edición (`trabajoEnCurso`): recargar borraría
 *   el pedido que se está cargando. Se salta en el próximo cambio de pantalla o
 *   vuelta a la app;
 * - el enfriamiento tras un salto que no prosperó (sin señal no se puede bajar el
 *   build nuevo): sin él, cada vuelta a la app lanzaría otro intento.
 */
export type DisparadorActualizacion =
  /** Se volvió a la app (la pestaña estaba escondida y se ve de nuevo). */
  | 'volver'
  /** Se cambió de pantalla (la ruta cambió). */
  | 'pantalla'
  /** Se supo de la versión nueva con la app en uso (al abrirla, el chequeo periódico, el service worker). */
  | 'aviso'

export interface MomentoDeActualizar {
  disparador: DisparadorActualizacion
  /** Hay un modal abierto o un campo en edición. */
  trabajoEnCurso: boolean
  /** Hubo un salto automático hace poco y no prosperó. */
  enEnfriamiento: boolean
  /** La app se acaba de abrir: todavía no hay nada que perder. */
  recienAbierta: boolean
}

/** ¿Se salta al build nuevo ahora, sin que lo toque nadie? */
export function saltarAlBuildNuevo(m: MomentoDeActualizar): boolean {
  if (m.enEnfriamiento || m.trabajoEnCurso) return false
  if (m.disparador === 'volver' || m.disparador === 'pantalla') return true
  return m.recienAbierta
}
