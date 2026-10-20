/**
 * Qué neto y qué bonificación se precargan al agregar un producto a una compra.
 *
 * El producto guarda `costo_sin_iva` YA bonificado (las RPCs de compra lo
 * escriben como `costo_unitario × (1 − bonificación)`). Precargar eso con
 * bonificación 0 daba el mismo costo final, pero la factura nueva quedaba mal
 * registrada: sin el neto de lista y sin la bonificación que dice el papel. Y
 * para cargarla bien había que retipear el neto de lista a mano.
 *
 * Por eso, si la última compra del producto tenía bonificación, se precarga lo
 * que decía esa factura: su neto de lista y su porcentaje. El costo final no
 * cambia —es el mismo neto bonificado—, pero la línea espeja la factura.
 *
 * Sólo cuando esa línea es la que dejó el costo vigente: su neto bonificado
 * tiene que coincidir con `costo_sin_iva`. Si no coincide, el costo se tocó
 * después (a mano en la ficha, otra compra más nueva de otra fecha) y lo que
 * vale es `costo_sin_iva` tal cual, sin bonificación.
 */

/** Lo que hace falta de la línea de la compra anterior. */
export interface LineaAnteriorPrecarga {
  /** `compra_items.costo_unitario`: el neto de lista, antes de bonificar. */
  costoUnitario?: number | null
  /** `compra_items.bonificacion`: porcentaje (mig 113). */
  bonificacion?: number | null
}

export interface PrecargaCosto {
  costoUnitario: number
  bonificacion: number
}

/** Medio centavo: `costo_sin_iva` puede venir redondeado a 2 decimales. */
const TOLERANCIA = 0.005

/**
 * La precarga con bonificación, o null si hay que dejar `costo_sin_iva` sin
 * bonificar (no hay anterior, no tenía bonificación, o no es la que dejó el
 * costo vigente).
 */
export function precargaConBonificacion(
  costoPrecargado: number,
  anterior: LineaAnteriorPrecarga | null | undefined,
): PrecargaCosto | null {
  if (!anterior) return null
  const lista = Number(anterior.costoUnitario)
  const bonificacion = Number(anterior.bonificacion)
  if (!Number.isFinite(lista) || lista <= 0) return null
  if (!Number.isFinite(bonificacion) || bonificacion <= 0 || bonificacion >= 100) return null
  if (!Number.isFinite(costoPrecargado) || costoPrecargado <= 0) return null
  const netoBonificado = lista * (1 - bonificacion / 100)
  if (Math.abs(netoBonificado - costoPrecargado) > TOLERANCIA) return null
  return { costoUnitario: lista, bonificacion }
}
