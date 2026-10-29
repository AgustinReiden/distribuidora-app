/**
 * Reglas puras de gastos: desglose de la factura A, cuotas del reparto y mes
 * sugerido. El server no las recalcula, sólo valida sumas y coherencia.
 *
 * `cuotaDeGasto` replica `_gasto_cuota` de la migración `gastos_1` (los mismos
 * ejemplos están en su ensayo; no hay gate de paridad).
 */
import type { ComprobanteGasto, Gasto, GrupoGasto, RubroGasto } from '../types/gastos'

export const GRUPOS_GASTO: ReadonlyArray<{ valor: GrupoGasto; etiqueta: string }> = [
  { valor: 'vehiculos', etiqueta: 'Vehículos' },
  { valor: 'inmueble', etiqueta: 'Inmueble' },
  { valor: 'impuestos', etiqueta: 'Impuestos' },
  { valor: 'administracion', etiqueta: 'Administración' },
  { valor: 'bienes_de_uso', etiqueta: 'Bienes de uso' },
  { valor: 'otros', etiqueta: 'Otros' },
]

/** Los seis botones. La letra M se elige aparte, dentro del bloque de la A. */
export const COMPROBANTES_GASTO: ReadonlyArray<{
  valor: Exclude<ComprobanteGasto, 'factura_m'>
  etiqueta: string
}> = [
  { valor: 'factura_a', etiqueta: 'Factura A' },
  { valor: 'factura_b', etiqueta: 'Factura B' },
  { valor: 'factura_c', etiqueta: 'Factura C' },
  { valor: 'recibo', etiqueta: 'Recibo' },
  { valor: 'ticket', etiqueta: 'Ticket' },
  { valor: 'ninguno', etiqueta: 'Sin comprobante' },
]

export const ALICUOTAS_IVA_GASTO = [21, 10.5, 27] as const

const MESES = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
]

const round2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100

const ETIQUETAS_COMPROBANTE: Record<ComprobanteGasto, string> = {
  factura_a: 'Factura A',
  factura_m: 'Factura M',
  factura_b: 'Factura B',
  factura_c: 'Factura C',
  recibo: 'Recibo',
  ticket: 'Ticket',
  ninguno: 'Sin comprobante',
}

export function etiquetaComprobante(c: ComprobanteGasto): string {
  return ETIQUETAS_COMPROBANTE[c]
}

export function etiquetaGrupo(grupo: GrupoGasto): string {
  return GRUPOS_GASTO.find(g => g.valor === grupo)?.etiqueta ?? grupo
}

export function daCreditoFiscal(c: ComprobanteGasto): boolean {
  return c === 'factura_a' || c === 'factura_m'
}

/** IVA contenido en lo que queda del total después de percepciones y otros impuestos. */
export function ivaSugerido(total: number, alicuota: number, percepciones: number, otros: number): number {
  return round2(((total - percepciones - otros) * alicuota) / (100 + alicuota))
}

/** Lo que va al resultado: el IVA y las percepciones son crédito, no costo. */
export function costoDeGasto(g: {
  monto_total: number
  iva: number
  percepcion_iva: number
  percepcion_iibb: number
}): number {
  return round2(g.monto_total - g.iva - g.percepcion_iva - g.percepcion_iibb)
}

export function netoDeGasto(g: {
  monto_total: number
  iva: number
  percepcion_iva: number
  percepcion_iibb: number
  otros_impuestos: number
}): number {
  return round2(costoDeGasto(g) - g.otros_impuestos)
}

/** Primer día del mes de una fecha ISO (`YYYY-MM-DD`). */
export function mesDe(fechaISO: string): string {
  return `${fechaISO.slice(0, 7)}-01`
}

export function sumarMeses(mesISO: string, n: number): string {
  const anio = Number(mesISO.slice(0, 4))
  const mes = Number(mesISO.slice(5, 7)) - 1
  const total = anio * 12 + mes + n
  const a = Math.floor(total / 12)
  const m = total - a * 12 + 1
  return `${String(a).padStart(4, '0')}-${String(m).padStart(2, '0')}-01`
}

export function etiquetaMes(mesISO: string): string {
  return `${MESES[Number(mesISO.slice(5, 7)) - 1]} ${mesISO.slice(0, 4)}`
}

export function mesSugerido(fechaISO: string, rubro: Pick<RubroGasto, 'sugiere_mes_anterior'>): string {
  const mes = mesDe(fechaISO)
  return rubro.sugiere_mes_anterior ? sumarMeses(mes, -1) : mes
}

/**
 * Cuota k de n: las primeras n−1 valen costo/n redondeado al centavo y la última
 * absorbe el redondeo. Se calcula en centavos enteros para dar el mismo centavo que
 * `_gasto_cuota` en el server: en punto flotante, 20,15 en 2 cuotas daba 10,07 + 10,08
 * y el server 10,08 + 10,07.
 */
export function cuotaDeGasto(costo: number, n: number, k: number): number {
  const centavos = Math.round(costo * 100)
  const base = Math.round(centavos / n)
  return (k >= n ? centavos - base * (n - 1) : base) / 100
}

export function cuotaDelMes(
  g: Pick<Gasto, 'costo' | 'mes_imputado' | 'repartir_meses'>,
  mesISO: string,
): { k: number; n: number; monto: number } | null {
  const diff = (Number(mesISO.slice(0, 4)) - Number(g.mes_imputado.slice(0, 4))) * 12
    + (Number(mesISO.slice(5, 7)) - Number(g.mes_imputado.slice(5, 7)))
  const k = diff + 1
  if (k < 1 || k > g.repartir_meses) return null
  return { k, n: g.repartir_meses, monto: cuotaDeGasto(g.costo, g.repartir_meses, k) }
}

export function normalizarPatente(s: string): string {
  return s.toUpperCase().replace(/[^A-Z0-9]/g, '')
}

/** Mensaje de error del desglose o `null` si es coherente. Mismos textos que el server. */
export function errorDeDesglose(g: {
  comprobante: ComprobanteGasto
  monto_total: number
  iva: number
  percepcion_iva: number
  percepcion_iibb: number
  otros_impuestos: number
}): string | null {
  const importes = [g.monto_total, g.iva, g.percepcion_iva, g.percepcion_iibb, g.otros_impuestos]
  if (importes.some(i => i < 0)) return 'Ningún importe puede ser negativo'
  if (daCreditoFiscal(g.comprobante)) {
    if (netoDeGasto(g) <= 0) return 'Con factura A o M el neto tiene que ser mayor a cero'
    return null
  }
  if (g.iva > 0 || g.percepcion_iva > 0 || g.percepcion_iibb > 0 || g.otros_impuestos > 0) {
    return 'Sólo la factura A o M lleva IVA y percepciones'
  }
  return null
}
