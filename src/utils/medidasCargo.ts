/**
 * Medidas para repartir cargos (mig 278): cuántas unidades de un producto entran
 * en un pallet, en un separador o en un lugar del flete.
 *
 * Es el dato que el que carga la factura tenía en la cabeza: en la compra 304
 * escribió "2" de peso para 240 u. de agua 600cc porque sabe que entran 120 por
 * pallet. Con la base de reparto 'medida' el peso sale solo:
 *
 *     peso de la línea = cantidad / unidades_por
 *
 * El motor de costos NO cambia: esto sólo precarga el vector de pesos, que sigue
 * siendo lo que se guarda (`compra_cargo_repartos.peso`) y lo que manda.
 *
 * De dónde sale `unidades_por`, en orden:
 *   1. lo tipeado en ESTA compra para esa medida;
 *   2. la ficha del producto (`producto_medidas`, por sucursal);
 *   3. lo mismo para la medida BASE (`cargo_medidas.medida_base_id`): "Lugar en el
 *      flete" cae a "Pallet" si el producto no tiene valor propio. Un solo nivel
 *      (lo garantiza un trigger de la mig 278).
 *
 * Puro y sin supabase: lo testea `medidasCargo.test.ts`.
 */
import { redondearSQL } from './calculations'
import { normalizarBusqueda } from './filtrarOpciones'

/** Una medida del catálogo global (`cargo_medidas`). Ids como string: son bigint. */
export interface MedidaCargo {
  id: string
  nombre: string
  /** "pallet", "separador", "lugar": para "2 pallets (120 u/pallet)". */
  unidadSingular: string
  /** Fallback de un nivel. */
  medidaBaseId: string | null
  activo: boolean
}

/** Un concepto del catálogo global (`cargo_conceptos`). */
export interface ConceptoCargo {
  id: string
  nombre: string
  /** Default del toggle +/-: -1 = bonificación. NO multiplica el monto. */
  signo: 1 | -1
  condicionIva: 'gravado' | 'exento' | 'no_gravado'
  enFactura: boolean
  prorrateaAlCosto: boolean
  baseProrrateo: 'monto' | 'cantidad' | 'unidades' | 'medida'
  medidaId: string | null
  activo: boolean
}

/** Lo tipeado en una compra para un producto y una medida. */
export interface ValorMedidaCompra {
  /** Sin redondear: 1000 u. en 3 pallets son 333,333... */
  unidadesPor: number
  /**
   * Si al guardar la compra el valor va a la ficha del producto. Arranca
   * marcado si la ficha no tenía valor, y DESMARCADO si tenía: un pallet
   * incompleto en una factura no tiene por qué reescribir la ficha.
   */
  guardarEnFicha: boolean
}

/** productoId → medidaId → valor. */
export type MedidasPorProducto<T> = Record<string, Record<string, T>>

/**
 * Todo lo que hace falta para resolver una medida: el catálogo (sólo el puente
 * medida → base), la ficha de la sucursal y lo tipeado en esta compra.
 */
export interface ContextoMedidas {
  /** medidaId → medidaBaseId. */
  bases: Record<string, string | null>
  /** De `producto_medidas` (sucursal activa). */
  ficha: MedidasPorProducto<number>
  /** Lo tipeado en esta compra. */
  compra: MedidasPorProducto<ValorMedidaCompra>
}

export const CONTEXTO_MEDIDAS_VACIO: ContextoMedidas = { bases: {}, ficha: {}, compra: {} }

export type OrigenMedida = 'compra' | 'ficha'

/** Cómo se resolvió la medida de una línea. */
export interface MedidaResuelta {
  unidadesPor: number
  /** La medida que dio el valor: la pedida o su base. */
  medidaId: string
  origen: OrigenMedida
  /** `true` si el valor vino de la medida base (fallback). */
  porBase: boolean
}

const valido = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n) && n > 0

function valorDirecto(
  productoId: string,
  medidaId: string,
  ctx: ContextoMedidas,
): { unidadesPor: number; origen: OrigenMedida } | null {
  const compra = ctx.compra[productoId]?.[medidaId]?.unidadesPor
  if (valido(compra)) return { unidadesPor: compra, origen: 'compra' }
  const ficha = ctx.ficha[productoId]?.[medidaId]
  if (valido(ficha)) return { unidadesPor: ficha, origen: 'ficha' }
  return null
}

/**
 * Las unidades por medida de un producto, o null si no hay de dónde sacarlas.
 *
 * La medida propia gana sobre la base aunque la base venga de esta compra: el
 * Placer 500cc tiene su "Lugar en el flete" en la ficha (2 pallets ocupan 1
 * lugar), y tipear sus u/pallet en el renglón de Pallets no tiene por qué
 * cambiar cuánto pesa en el flete.
 */
export function resolverMedida(
  productoId: string | number,
  medidaId: string | null | undefined,
  ctx: ContextoMedidas,
): MedidaResuelta | null {
  if (!medidaId) return null
  const producto = String(productoId)
  const propia = valorDirecto(producto, medidaId, ctx)
  if (propia) return { ...propia, medidaId, porBase: false }
  const base = ctx.bases[medidaId]
  if (!base || base === medidaId) return null
  const deBase = valorDirecto(producto, base, ctx)
  return deBase ? { ...deBase, medidaId: base, porBase: true } : null
}

/**
 * La medida que se EDITA desde una línea de la grilla: la que la resuelve hoy,
 * o —si no se resuelve— la base, si hay. Tipear "u por pallet" en el renglón
 * del flete carga el Pallet, que es lo que la persona tiene en la cabeza y lo
 * que también usa el renglón de Pallets.
 */
export function medidaEditable(
  productoId: string | number,
  medidaId: string,
  ctx: ContextoMedidas,
): string {
  const resuelta = resolverMedida(productoId, medidaId, ctx)
  if (resuelta) return resuelta.medidaId
  return ctx.bases[medidaId] ?? medidaId
}

/**
 * Peso de la línea: cantidad / unidades_por, a 4 decimales (la precisión de
 * `compra_cargo_repartos.peso`).
 *
 * Con `unidades_por` guardado SIN redondear, los pallets tipeados vuelven
 * exactos: 1000 u. en 3 pallets dan 333,333... u/pallet y 1000 / 333,333... a 4
 * decimales es 3, no el 3,0003 que saldría de redondear las u/pallet a 333,33.
 */
export function pesoPorMedida(cantidad: number, unidadesPor: number): number {
  if (!valido(unidadesPor) || !(cantidad > 0)) return 0
  return redondearSQL(cantidad / unidadesPor, 4)
}

/** Pallets tipeados → u/pallet, sin redondear. null si no se puede derivar. */
export function unidadesPorDesdeCantidadDeMedidas(cantidad: number, medidas: number): number | null {
  if (!(cantidad > 0) || !valido(medidas)) return null
  return cantidad / medidas
}

/** El default del check "guardar en la ficha": marcado sólo si la ficha no tenía valor. */
export function guardarEnFichaPorDefecto(fichaTeniaValor: boolean): boolean {
  return !fichaTeniaValor
}

/** ¿La ficha tiene valor PROPIO para esta medida? (no cuenta el de la base) */
export function fichaTieneValor(productoId: string | number, medidaId: string, ctx: ContextoMedidas): boolean {
  return valido(ctx.ficha[String(productoId)]?.[medidaId])
}

/**
 * El contexto con un valor tipeado en esta compra. `null` lo borra (vuelve a la
 * ficha). El check "guardar en la ficha" se conserva si ya existía; si no,
 * arranca con el default.
 */
export function conValorDeCompra(
  ctx: ContextoMedidas,
  productoId: string | number,
  medidaId: string,
  unidadesPor: number | null,
): ContextoMedidas {
  const producto = String(productoId)
  const delProducto = { ...(ctx.compra[producto] ?? {}) }
  if (unidadesPor === null || !valido(unidadesPor)) {
    delete delProducto[medidaId]
  } else {
    const previo = delProducto[medidaId]
    delProducto[medidaId] = {
      unidadesPor,
      guardarEnFicha: previo?.guardarEnFicha ?? guardarEnFichaPorDefecto(fichaTieneValor(producto, medidaId, ctx)),
    }
  }
  const compra = { ...ctx.compra }
  if (Object.keys(delProducto).length === 0) delete compra[producto]
  else compra[producto] = delProducto
  return { ...ctx, compra }
}

/** Una medida para `guardar_producto_medidas`. */
export interface MedidaFichaInput {
  productoId: string
  medidaId: string
  unidadesPor: number
}

/**
 * Lo que va a la ficha al guardar la compra: lo tipeado con el check marcado,
 * sólo de productos que siguen en la compra, y sólo si cambia algo respecto de
 * la ficha (reescribir el mismo número no aporta y deja un updated_at mentiroso).
 */
export function medidasParaFicha(
  ctx: ContextoMedidas,
  productosEnCompra: Array<string | number>,
): MedidaFichaInput[] {
  const vigentes = new Set(productosEnCompra.map(String))
  const salida: MedidaFichaInput[] = []
  for (const [productoId, porMedida] of Object.entries(ctx.compra)) {
    if (!vigentes.has(productoId)) continue
    for (const [medidaId, valor] of Object.entries(porMedida)) {
      if (!valor.guardarEnFicha || !valido(valor.unidadesPor)) continue
      if (ctx.ficha[productoId]?.[medidaId] === valor.unidadesPor) continue
      salida.push({ productoId, medidaId, unidadesPor: valor.unidadesPor })
    }
  }
  return salida
}

/**
 * La normalización de un nombre de concepto: la misma de la mig 278
 * (`normalizar_nombre_concepto`) y la misma que usa el combobox para buscar.
 * Minúsculas, sin tildes, espacios colapsados.
 */
export function normalizarNombreConcepto(nombre: string | null | undefined): string {
  return normalizarBusqueda(nombre)
}

/** El concepto del catálogo con ese nombre (normalizado), si hay. */
export function conceptoPorNombre(
  conceptos: ConceptoCargo[],
  nombre: string | null | undefined,
): ConceptoCargo | undefined {
  const clave = normalizarNombreConcepto(nombre)
  if (!clave) return undefined
  return conceptos.find(c => normalizarNombreConcepto(c.nombre) === clave)
}

/** "pallet" → "pallets". Español, para las tres medidas que existen y las que vengan. */
export function pluralMedida(unidad: string, cantidad: number): string {
  if (cantidad === 1) return unidad
  // "pallet" es préstamo y se pluraliza con -s, como las terminadas en vocal.
  if (/[aeiouáéót]$/i.test(unidad)) return `${unidad}s`
  if (/z$/i.test(unidad)) return `${unidad.slice(0, -1)}ces`
  return `${unidad}es`
}

/** "2 pallets (120 u/pallet)". Los números con coma decimal, como el resto del modal. */
export function textoMedidaLinea(peso: number, unidadesPor: number, unidad: string): string {
  const n = (v: number, dec: number) => String(redondearSQL(v, dec)).replace('.', ',')
  return `${n(peso, 4)} ${pluralMedida(unidad, peso)} (${n(unidadesPor, 2)} u/${unidad})`
}
