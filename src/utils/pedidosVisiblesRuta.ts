/**
 * Lista de pedidos que muestra "Armar ruta del día".
 *
 * Modo dividir: todo el pool disponible. Modo un chofer: las paradas de su ruta
 * (si existe) más los disponibles, sin duplicar (las paradas ganan).
 *
 * Las paradas ya entregadas NO se listan: no se pueden volver a rutear
 * (aplicar_orden_ruta las devolvía a 'asignado') y mezclarlas con lo que falta
 * armar inflaba el conteo "seleccionados/visibles". Siguen en la ruta: la RPC
 * solo reemplaza las paradas pendientes.
 */
import { pedidoEnRangoDeFechas, type TipoFiltroFecha, type PedidoConFechas } from './filtroFechaPedidos'

/**
 * El filtro de fechas también acota lo que se VE de las paradas ya armadas:
 * antes filtraba solo los disponibles, y filtrando "29/9" sobre la ruta del
 * 30/9 seguían apareciendo las paradas del 30/9. Es sólo vista: las ocultas
 * siguen seleccionadas y en la ruta (sacarlas de la selección las borraría al
 * re-armar), por eso se devuelven aparte para avisar cuántas son.
 */
export function separarPorFiltroFecha<T extends PedidoConFechas>(
  lista: T[],
  filtro: { activo: boolean; tipo: TipoFiltroFecha; desde: string; hasta: string },
): { visibles: T[]; ocultas: T[] } {
  if (!filtro.activo) return { visibles: lista, ocultas: [] }
  const visibles: T[] = []
  const ocultas: T[] = []
  for (const p of lista) {
    if (pedidoEnRangoDeFechas(p, filtro.tipo, filtro.desde, filtro.hasta)) visibles.push(p)
    else ocultas.push(p)
  }
  return { visibles, ocultas }
}

export interface PedidoRuteable {
  id: string
  estado?: string | null
  orden_entrega?: number | null
}

export function pedidosVisiblesRuta<T extends PedidoRuteable>(opts: {
  modoDividir: boolean
  hayTransportista: boolean
  paradasExistentes: T[]
  disponibles: T[]
}): T[] {
  const porOrden = (a: T, b: T): number => (a.orden_entrega || 999) - (b.orden_entrega || 999)
  if (opts.modoDividir) return [...opts.disponibles].sort(porOrden)
  if (!opts.hayTransportista) return []
  const map = new Map<string, T>()
  for (const p of opts.paradasExistentes) {
    if (p.estado !== 'entregado') map.set(p.id, p)
  }
  for (const p of opts.disponibles) {
    if (!map.has(p.id) && p.estado !== 'entregado') map.set(p.id, p)
  }
  return Array.from(map.values()).sort(porOrden)
}
