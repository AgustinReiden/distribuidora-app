/**
 * ¿Recargar la app ahora borraría algo? (D57 de #1563 y H1/H7 de la revisión de B12a.)
 *
 * La actualización obligatoria salta sola al volver a la app o al cambiar de
 * pantalla, y justo antes de recargar pregunta acá. Hay dos fuentes:
 *
 * 1. Lo que se ve en el DOM: un modal abierto o un campo con el foco.
 * 2. Lo que una pantalla declara (`marcarTrabajoEnCurso` / `useTrabajoEnCurso`):
 *    un alta o un cobro en vuelo, la oferta de la cola (D56) en pantalla, una
 *    sincronización de la cola corriendo, o cambios tipeados que todavía no se
 *    guardaron en una pantalla sin modal (las tarjetas de /configuracion, por
 *    ejemplo, que guardan en `useState` hasta «Guardar»).
 *
 * Una pantalla nueva con edición en línea se suma levantando la marca mientras
 * tenga cambios sin guardar; no hace falta tocar nada más.
 */

const marcas = new Map<number, string>()
let siguiente = 0

/** Levanta una marca de trabajo en curso. Devuelve la función que la baja. */
export function marcarTrabajoEnCurso(motivo: string): () => void {
  const id = ++siguiente
  marcas.set(id, motivo)
  return () => { marcas.delete(id) }
}

/** Los motivos de las marcas vivas (para el log y los tests). */
export function motivosDeTrabajoEnCurso(): string[] {
  return [...marcas.values()]
}

/** Hay un modal abierto o un campo en edición: recargar le borraría algo. */
function hayTrabajoEnElDom(): boolean {
  if (typeof document === 'undefined') return false
  if (document.querySelector('[role="dialog"], [role="alertdialog"]')) return true
  const el = document.activeElement as HTMLElement | null
  if (!el) return false
  return el.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)
}

/** ¿Recargar ahora borraría algo? */
export function hayTrabajoEnCurso(): boolean {
  return marcas.size > 0 || hayTrabajoEnElDom()
}

/** Solo para tests. */
export function _resetTrabajoEnCursoParaTests(): void {
  marcas.clear()
}
