/**
 * Reporte de bonificaciones: lo puro de la pantalla. Los totales y los cortes
 * los calcula el RPC `reporte_bonificaciones`; acá sólo se filtra el detalle y
 * se resume lo filtrado, que nunca mueve los totales de arriba.
 */
import type { LineaBonificacion } from '../hooks/queries/useBonificacionesReporteQuery'

/** Clave de filtro de lo que no tiene promoción o vendedor. */
export const SIN_DATO = '__sin__'

export interface FiltrosDetalleBonificaciones {
  /** promocion_id como string, SIN_DATO o '' (todas). */
  promocion: string
  /** usuario_id, SIN_DATO o '' (todos). */
  vendedor: string
  busqueda: string
}

export const FILTROS_BONIF_VACIOS: FiltrosDetalleBonificaciones = { promocion: '', vendedor: '', busqueda: '' }

const normalizar = (s: string): string =>
  s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim()

export function filtrarDetalleBonificaciones(
  lineas: LineaBonificacion[],
  filtros: FiltrosDetalleBonificaciones,
): LineaBonificacion[] {
  const q = normalizar(filtros.busqueda)
  return lineas.filter((l) => {
    if (filtros.promocion && (l.promocion_id == null ? SIN_DATO : String(l.promocion_id)) !== filtros.promocion) return false
    if (filtros.vendedor && (l.usuario_id ?? SIN_DATO) !== filtros.vendedor) return false
    if (!q) return true
    return [l.cliente_nombre, l.producto_nombre, l.producto_codigo, String(l.pedido_id)]
      .some((v) => v != null && normalizar(v).includes(q))
  })
}

export interface ResumenBonificaciones {
  lineas: number
  pedidos: number
  bultos: number
  costo: number
  valor_venta: number
}

export function resumirBonificaciones(lineas: LineaBonificacion[]): ResumenBonificaciones {
  const pedidos = new Set<number>()
  let bultos = 0
  let costo = 0
  let valor = 0
  for (const l of lineas) {
    pedidos.add(l.pedido_id)
    bultos += Number(l.bultos) || 0
    costo += Number(l.costo) || 0
    valor += Number(l.valor_venta) || 0
  }
  return { lineas: lineas.length, pedidos: pedidos.size, bultos, costo, valor_venta: valor }
}

/** Lo regalado sobre lo vendido, a costo. Null si no hubo venta (no es 0 %). */
export function pctSobreVenta(costo: number, venta: number): number | null {
  return venta > 0 ? costo / venta : null
}

export function formatPct(pct: number | null): string {
  return pct == null ? '—' : `${(pct * 100).toLocaleString('es-AR', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} %`
}

/** Bultos con hasta dos decimales: 2 botellas de un fardo de 6 son 0,33. */
export function formatBultos(n: number): string {
  return Number(n ?? 0).toLocaleString('es-AR', { maximumFractionDigits: 2 })
}
