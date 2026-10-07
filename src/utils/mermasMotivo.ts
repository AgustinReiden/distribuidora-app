/**
 * Etiquetas legibles de los motivos y clasificaciones de merma.
 *
 * Vive acá y no adentro de una pantalla porque lo usan las DOS: la card
 * "Mermas del período" del gerencial y la pestaña Mermas de /reportes. Si cada
 * una tuviera su mapa, el mismo motivo se llamaría distinto en cada lado y
 * nadie sabría si son el mismo número.
 *
 * La lista de motivos es la del CHECK vivo de `mermas_stock` (10 valores).
 * `promociones_reversion` estaba faltando en el mapa original del modal: caía
 * al fallback y se renderizaba el string crudo de la base, con guion bajo.
 */

/** Clasificación de negocio que devuelve `reporte_mermas` (mig 226). */
export type ClasificacionMerma = 'perdida' | 'ajuste' | 'muestra' | 'promocion'

/** De dónde salió el costo de la fila. Espejo del CASE de la mig 226. */
export type OrigenCostoMerma = 'congelado' | 'estimado' | 'sin_costo'

export const LABELS_MOTIVO: Record<string, string> = {
  rotura: 'Rotura',
  vencimiento: 'Vencimiento',
  robo: 'Robo/Hurto',
  decomiso: 'Decomiso',
  devolucion: 'Devolución',
  error_inventario: 'Error inventario',
  muestra: 'Muestra',
  promociones: 'Promociones',
  promociones_reversion: 'Reversión de promoción',
  otro: 'Otro',
}

export function labelMotivo(motivo: string): string {
  return LABELS_MOTIVO[motivo] ?? motivo
}

export const LABELS_CLASIFICACION: Record<ClasificacionMerma, string> = {
  perdida: 'Pérdida',
  ajuste: 'Ajuste',
  muestra: 'Muestra',
  promocion: 'Ajuste de promoción',
}

export function labelClasificacion(clasificacion: string): string {
  return LABELS_CLASIFICACION[clasificacion as ClasificacionMerma] ?? clasificacion
}

/**
 * De dónde vino la merma (mig 301, #847). Espejo del CASE de
 * `merma_procedencia()`. Es otro eje que el motivo: el mismo 'error_inventario'
 * puede ser un faltante en la entrega, una cancelación por falta de stock o un
 * ajuste cargado a mano, y en el corte por motivo los tres eran un solo renglón.
 */
export type ProcedenciaMerma = 'entrega_salvedad' | 'cancelacion_falta_stock' | 'carga_directa' | 'promocion'

export const LABELS_PROCEDENCIA: Record<ProcedenciaMerma, string> = {
  entrega_salvedad: 'Entrega con salvedad',
  cancelacion_falta_stock: 'Cancelación por falta de stock',
  carga_directa: 'Carga directa',
  promocion: 'Promoción',
}

export function labelProcedencia(procedencia: string): string {
  return LABELS_PROCEDENCIA[procedencia as ProcedenciaMerma] ?? procedencia
}

/** El renglón del corte por procedencia. El error de inventario de una entrega
 *  con salvedad es, por construcción, el faltante: se lo nombra así. */
export function labelProcedenciaMotivo(procedencia: string, motivo: string): string {
  if (procedencia === 'entrega_salvedad' && motivo === 'error_inventario') return 'Faltante en la entrega'
  return `${labelProcedencia(procedencia)} · ${labelMotivo(motivo)}`
}

/**
 * Los ajustes de promoción no son pérdida: son la contrapartida en stock de un
 * regalo que ya se contabilizó como bonificación en el pedido. El total de
 * mermas los excluye — contarlos lo triplicaría.
 */
export function esAjustePromocion(clasificacion: string): boolean {
  return clasificacion === 'promocion'
}
