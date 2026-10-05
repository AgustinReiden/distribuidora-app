/**
 * Bonificación que el proveedor no descontó en la factura (#908).
 *
 * Algunos proveedores liquidan una promo ("$Y por bulto de tal grupo de
 * productos") y no la descuentan en la factura: la acreditan después. Si quien
 * carga la compra no agrega el cargo negativo "Bonificación" con su alcance, el
 * costo queda inflado sin ningún aviso. Esto compara la factura contra las
 * promos declaradas del proveedor (`promociones_proveedor`) y devuelve lo que
 * habría que SUGERIR. Nunca aplica nada: el modal muestra la sugerencia y quien
 * carga la acepta o la descarta.
 *
 * Lógica pura y sin supabase: la consume el modal de compra y la prueban los
 * tests con fixtures sintéticos.
 *
 * ── Qué se espera de cada promo ────────────────────────────────────────────
 * Sólo promos activas y vigentes a la fecha de la factura (extremos inclusive,
 * cualquiera de los dos puede faltar). El alcance son las líneas cuyo producto
 * está en la promo; una línea de otro producto no entra nunca.
 *   - 'monto_por_unidad': cantidad de la línea × monto (SIN IVA, como un cargo).
 *   - 'porcentaje': % × neto de la línea (cantidad × costo, ya bonificado por
 *     el % de la línea). Es el mismo neto que usa la base 'monto' del reparto.
 *
 * ── Criterio anti doble descuento (conservador: ante la duda, no sugerir) ──
 * 1. Bonificación % de la línea. Si lo que la línea YA descuenta por su % es
 *    al menos lo que la promo pide para esa línea, la línea se da por
 *    cubierta (la factura aplicó la promo como %) y sale del alcance. Si
 *    descuenta menos, se toma como el descuento habitual del proveedor y la
 *    promo se espera entera sobre esa línea. Consecuencia buscada: una promo
 *    que el proveedor acumula ENCIMA de un % de línea mayor no se detecta; se
 *    prefiere eso a sugerir un doble descuento.
 * 2. Cargos negativos ya cargados. Cada uno descuenta, sobre el alcance, la
 *    parte de su monto proporcional a sus pesos en las líneas del alcance
 *    (Σ pesos en el alcance / Σ pesos totales). Un cargo que cae entero en el
 *    alcance cubre todo su monto; uno que reparte mitad adentro y mitad
 *    afuera, la mitad. Todos los negativos cuentan, vengan de donde vengan.
 * 3. Se sugiere sólo si lo que falta supera la tolerancia: el mayor entre
 *    $1 y el 0,5 % de lo esperado. Por debajo es redondeo, no una promo
 *    olvidada.
 * 4. Una promo que ya tiene un cargo con su marca (aplicado desde una
 *    sugerencia) o que se descartó en esta sesión no se vuelve a sugerir.
 */
import { redondearSQL } from './calculations'

export type TipoPromocionProveedor = 'monto_por_unidad' | 'porcentaje'

/** Promo declarada del proveedor, ya con su alcance. */
export interface PromocionProveedor {
  id: string
  nombre: string
  tipo: TipoPromocionProveedor
  /** SIN IVA, por unidad de la línea. Sólo tipo 'monto_por_unidad'. */
  montoPorUnidad: number | null
  /** 0–100. Sólo tipo 'porcentaje'. */
  porcentaje: number | null
  /** 'YYYY-MM-DD' o null (sin límite). */
  vigenteDesde: string | null
  vigenteHasta: string | null
  activo: boolean
  productoIds: string[]
}

/** Lo que hace falta de una línea de la factura. */
export interface LineaParaSugerencia {
  lineaId: number
  productoId: string
  cantidad: number
  costoUnitario: number
  /** % de bonificación de la línea. */
  bonificacion: number
}

/** Lo que hace falta de un cargo ya cargado. */
export interface CargoParaSugerencia {
  /** SIN IVA. Negativo = bonificación. */
  monto: number
  /** lineaId → peso. */
  pesos: Record<number, number>
  /** La promo de la que salió, si se aplicó desde una sugerencia. */
  sugerencia?: { promoId: string } | null
}

export interface SugerenciaBonificacion {
  promoId: string
  nombre: string
  /** Negativo, redondeado a 2 decimales. */
  monto: number
  /** 'cantidad' para monto por unidad, 'monto' para porcentaje. */
  base: 'cantidad' | 'monto'
  /** lineaId → peso, para TODAS las líneas (0 fuera del alcance). */
  pesos: Record<number, number>
  /** Las líneas que llevan la bonificación (alcance menos las ya cubiertas por su %). */
  lineasAlcance: number[]
  /** Productos de esas líneas: el alcance del cargo para líneas que lleguen después. */
  productoIds: string[]
  /** Lo que la promo pide sobre esas líneas. */
  esperado: number
  /** Lo que ya descuentan los cargos negativos cargados. */
  yaDescontado: number
  explicacion: string
}

export interface EntradaSugerencias {
  lineas: LineaParaSugerencia[]
  cargos: CargoParaSugerencia[]
  promos: PromocionProveedor[]
  /** 'YYYY-MM-DD' de la factura. */
  fechaCompra: string
  /** Promos descartadas en esta sesión. */
  descartadas?: readonly string[]
}

/** Piso absoluto de la tolerancia, en pesos. */
export const TOLERANCIA_SUGERENCIA_PESOS = 1
/** Tolerancia relativa sobre lo esperado. */
export const TOLERANCIA_SUGERENCIA_RELATIVA = 0.005

const fmt = (n: number): string =>
  n.toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export function promoVigente(promo: PromocionProveedor, fecha: string): boolean {
  if (!promo.activo) return false
  if (promo.vigenteDesde && fecha < promo.vigenteDesde) return false
  if (promo.vigenteHasta && fecha > promo.vigenteHasta) return false
  return true
}

const bruto = (l: LineaParaSugerencia): number => (l.cantidad || 0) * (l.costoUnitario || 0)
const descuentoLinea = (l: LineaParaSugerencia): number => bruto(l) * ((l.bonificacion || 0) / 100)
const netoLinea = (l: LineaParaSugerencia): number => bruto(l) - descuentoLinea(l)

/** Lo que la promo pide para una línea. null si la promo está mal cargada. */
function esperadoLinea(promo: PromocionProveedor, l: LineaParaSugerencia): number | null {
  if (promo.tipo === 'monto_por_unidad') {
    const m = Number(promo.montoPorUnidad)
    return Number.isFinite(m) && m > 0 ? (l.cantidad || 0) * m : null
  }
  const p = Number(promo.porcentaje)
  return Number.isFinite(p) && p > 0 ? netoLinea(l) * (p / 100) : null
}

/** Parte de un cargo negativo que cae sobre las líneas dadas, en positivo. */
function descontadoSobre(cargo: CargoParaSugerencia, lineas: ReadonlySet<number>): number {
  if (!(cargo.monto < 0)) return 0
  let total = 0
  let adentro = 0
  for (const [id, peso] of Object.entries(cargo.pesos)) {
    const p = Number(peso)
    if (!Number.isFinite(p) || p <= 0) continue
    total += p
    if (lineas.has(Number(id))) adentro += p
  }
  return total > 0 ? Math.abs(cargo.monto) * (adentro / total) : 0
}

export function sugerirBonificaciones(entrada: EntradaSugerencias): SugerenciaBonificacion[] {
  const { lineas, cargos, promos, fechaCompra, descartadas = [] } = entrada
  const marcadas = new Set(cargos.flatMap(c => (c.sugerencia?.promoId ? [String(c.sugerencia.promoId)] : [])))
  const descartadasSet = new Set(descartadas.map(String))
  const salida: SugerenciaBonificacion[] = []

  for (const promo of promos) {
    const promoId = String(promo.id)
    if (marcadas.has(promoId) || descartadasSet.has(promoId)) continue
    if (!promoVigente(promo, fechaCompra)) continue
    const productos = new Set(promo.productoIds.map(String))
    if (productos.size === 0) continue

    // 1. Alcance y lo que pide la promo, sin las líneas que ya cubre su %.
    const alcance: LineaParaSugerencia[] = []
    let esperado = 0
    let malCargada = false
    for (const l of lineas) {
      if (!productos.has(String(l.productoId)) || !((l.cantidad || 0) > 0)) continue
      const e = esperadoLinea(promo, l)
      if (e === null) { malCargada = true; break }
      if (e <= 0) continue
      if (descuentoLinea(l) >= e) continue
      alcance.push(l)
      esperado += e
    }
    if (malCargada || alcance.length === 0) continue

    // 2. Lo que ya descuentan los cargos negativos sobre esas líneas.
    const ids = new Set(alcance.map(l => l.lineaId))
    const yaDescontado = cargos.reduce((acc, c) => acc + descontadoSobre(c, ids), 0)
    const falta = esperado - yaDescontado

    // 3. Tolerancia.
    const tolerancia = Math.max(TOLERANCIA_SUGERENCIA_PESOS, esperado * TOLERANCIA_SUGERENCIA_RELATIVA)
    if (!(falta > tolerancia)) continue

    const base: SugerenciaBonificacion['base'] = promo.tipo === 'monto_por_unidad' ? 'cantidad' : 'monto'
    const pesos: Record<number, number> = {}
    for (const l of lineas) {
      pesos[l.lineaId] = ids.has(l.lineaId)
        ? (base === 'cantidad' ? l.cantidad : redondearSQL(netoLinea(l), 4))
        : 0
    }
    const unidades = alcance.reduce((acc, l) => acc + (l.cantidad || 0), 0)
    const regla = promo.tipo === 'monto_por_unidad'
      ? `${unidades} u. × $${fmt(Number(promo.montoPorUnidad))}`
      : `${Number(promo.porcentaje)} % del neto`
    salida.push({
      promoId,
      nombre: promo.nombre,
      monto: -redondearSQL(falta, 2),
      base,
      pesos,
      lineasAlcance: alcance.map(l => l.lineaId),
      productoIds: [...new Set(alcance.map(l => String(l.productoId)))],
      esperado: redondearSQL(esperado, 2),
      yaDescontado: redondearSQL(yaDescontado, 2),
      explicacion: `${regla} = $${fmt(esperado)}` +
        (yaDescontado > 0 ? `; ya descontado en cargos $${fmt(yaDescontado)}` : '') +
        ` (${alcance.length} ${alcance.length === 1 ? 'línea' : 'líneas'})`,
    })
  }
  return salida
}
