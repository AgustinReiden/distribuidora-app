/**
 * «Otro lo cambió mientras lo editabas» en combos, promos y clientes (C4b de #1603, 1599-b8; el
 * molde es la edición de un gasto, 1599-b9).
 *
 * `guardar_combo` y `cambiar_regalo_promocion` comparan la versión (`updated_at`) que vio quien
 * edita con la de ahora y, si otro guardó en el medio, no escriben nada y devuelven un `codigo`:
 * 'combo_cambiado', 'orden_cambiado' (cambió otro combo del orden que se reescribe) o
 * 'promocion_cambiada'. El formulario sigue abierto con lo tipeado: el mensaje lo dice.
 */

export type CodigoConflicto = 'combo_cambiado' | 'orden_cambiado' | 'promocion_cambiada' | 'cliente_cambiado'

const CODIGOS: ReadonlySet<string> = new Set<CodigoConflicto>(['combo_cambiado', 'orden_cambiado', 'promocion_cambiada', 'cliente_cambiado'])

/** El rechazo por versión. 409: el retry global no lo repite (reintentar no lo destraba). */
export class ConflictoDeVersionError extends Error {
  readonly codigo: CodigoConflicto
  readonly status = 409

  constructor(message: string, codigo: CodigoConflicto) {
    super(message)
    this.name = 'ConflictoDeVersionError'
    this.codigo = codigo
  }
}

export function esConflictoDeVersion(e: unknown): e is ConflictoDeVersionError {
  return e instanceof ConflictoDeVersionError
}

/**
 * El error de un `{ success: false, codigo, error }` de esas RPC, o null si no es un conflicto. El
 * texto del server dice qué pasó; el de acá, qué hacer con lo tipeado.
 */
export function conflictoDeRespuesta(r: { success?: boolean; codigo?: string; error?: string } | null | undefined): ConflictoDeVersionError | null {
  if (!r || r.success !== false || !r.codigo || !CODIGOS.has(r.codigo)) return null
  const codigo = r.codigo as CodigoConflicto
  const servidor = (r.error ?? '').trim() || 'Otro usuario lo cambió mientras lo editabas: no se guardó nada.'
  const queHacer = codigo === 'orden_cambiado'
    ? 'Ya se cargaron los combos de ahora: revisá el orden y volvé a guardar.'
    : 'Lo que cargaste sigue en esta ventana: anotalo antes de cerrarla.'
  return new ConflictoDeVersionError(`${servidor} ${queHacer}`, codigo)
}

/**
 * La versión de cada combo del orden que `guardar_combo` reescribe, salvo el que se guarda (va en
 * `updated_at_esperado`) y el nuevo (0). El texto viaja tal cual lo dio la base: en un `Date` se
 * pierden los microsegundos y la comparación daría «cambió» siempre.
 */
export function versionesDelOrden(
  orden: readonly number[] | undefined,
  combos: ReadonlyArray<{ id: string; updatedAt?: string | null }>,
  idQueSeGuarda: string | undefined,
): Record<string, string | null> | undefined {
  if (!orden) return undefined
  const porId = new Map(combos.map(c => [c.id, c.updatedAt]))
  const versiones: Record<string, string | null> = {}
  for (const id of orden) {
    const clave = String(id)
    if (id === 0 || clave === idQueSeGuarda || !porId.has(clave)) continue
    versiones[clave] = porId.get(clave) ?? null
  }
  return versiones
}

/** Lanza el ConflictoDeVersionError de la respuesta, si lo es (y si no, no hace nada). */
export function lanzarSiConflicto(r: { success?: boolean; codigo?: string; error?: string } | null | undefined): void {
  const c = conflictoDeRespuesta(r)
  if (c) throw new ConflictoDeVersionError(c.message, c.codigo)
}
