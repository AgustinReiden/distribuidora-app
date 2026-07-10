/**
 * Helpers puros para las métricas del Dashboard.
 *
 * Separados de useMetricasQuery para poder testearlos sin TanStack Query.
 * Todas las fechas son strings 'YYYY-MM-DD' en huso Argentina (fechaLocalISO).
 * OJO: nunca construir `new Date('YYYY-MM-DD')` — parsea a medianoche UTC y
 * en UTC-3 cae en el día anterior (así se perdía el último día del rango
 * personalizado). Acá las fechas se arman siempre por partes.
 */
import type {
  ClienteActivo,
  PedidosPorEstado,
  ProductoVendido,
  VentaPorDia,
} from '../types'

export interface VentanaPeriodo {
  desde: string | null
  hasta: string | null
}

/** Suma (o resta) días a una fecha 'YYYY-MM-DD' con aritmética de calendario. */
export function addDiasISO(fechaISO: string, dias: number): string {
  const [y, m, d] = fechaISO.split('-').map(Number)
  const fecha = new Date(y, m - 1, d + dias)
  const mm = String(fecha.getMonth() + 1).padStart(2, '0')
  const dd = String(fecha.getDate()).padStart(2, '0')
  return `${fecha.getFullYear()}-${mm}-${dd}`
}

/** Días entre dos fechas ISO (hasta − desde), sin efectos de huso/DST. */
export function diffDiasISO(desdeISO: string, hastaISO: string): number {
  const [y1, m1, d1] = desdeISO.split('-').map(Number)
  const [y2, m2, d2] = hastaISO.split('-').map(Number)
  return Math.round((Date.UTC(y2, m2 - 1, d2) - Date.UTC(y1, m1 - 1, d1)) / 86400000)
}

/**
 * Ventana [desde, hasta] inclusive del período elegido, para filtrar por
 * `pedidos.fecha` en el server. hasta=null ⇒ sin tope superior (los períodos
 * relativos llegan hasta hoy e incluyen pedidos re-fechados a futuro dentro
 * del mes/año, como siempre). Solo 'hoy' y 'personalizado' acotan arriba.
 */
export function ventanaPeriodoDashboard(
  periodo: string,
  hoyISO: string,
  fechaDesde?: string | null,
  fechaHasta?: string | null,
): VentanaPeriodo {
  switch (periodo) {
    case 'hoy':
      return { desde: hoyISO, hasta: hoyISO }
    case 'semana':
      return { desde: addDiasISO(hoyISO, -7), hasta: null }
    case 'mes':
      return { desde: `${hoyISO.slice(0, 7)}-01`, hasta: null }
    case 'anio':
      return { desde: `${hoyISO.slice(0, 4)}-01-01`, hasta: null }
    case 'personalizado':
      return { desde: fechaDesde || null, hasta: fechaHasta || null }
    case 'historico':
    default:
      return { desde: null, hasta: null }
  }
}

/**
 * Ventana anterior de igual duración que termina el día antes de `desde`
 * (misma convención que el comparativo del RPC reporte_gerencial).
 */
export function ventanaAnterior(desde: string, hasta: string): { desde: string; hasta: string } {
  const prevHasta = addDiasISO(desde, -1)
  const duracion = diffDiasISO(desde, hasta)
  return { desde: addDiasISO(prevHasta, -duracion), hasta: prevHasta }
}

export interface PedidoMetricaRow {
  cliente_id: string
  estado: string
  total: number | null
  cliente?: { nombre_fantasia?: string } | null
  items?: Array<{ producto_id: string; cantidad: number; producto?: { nombre?: string } | null }>
}

export interface MetricasPeriodo {
  ventasPeriodo: number
  ventasEnCurso: number
  pedidosPeriodo: number
  pedidosEntregados: number
  pedidosEnCurso: number
  pedidosPorEstado: PedidosPorEstado
  productosMasVendidos: ProductoVendido[]
  clientesMasActivos: ClienteActivo[]
}

/**
 * Agregación del dataset del período. Venta = SOLO entregados (convención de
 * negocio: igual que reporte_gerencial y el bot); pendiente+asignado se expone
 * aparte como "en curso". Top productos/clientes siguen contando toda la
 * actividad no cancelada del período.
 */
export function agregarMetricasPeriodo(pedidos: PedidoMetricaRow[]): MetricasPeriodo {
  // La query ya excluye cancelados server-side; el filtro queda como defensa.
  const activos = pedidos.filter(p => p.estado !== 'cancelado')

  let ventasPeriodo = 0
  let ventasEnCurso = 0
  let pedidosEntregados = 0
  let pedidosEnCurso = 0
  const pedidosPorEstado: PedidosPorEstado = { pendiente: 0, asignado: 0, entregado: 0 }
  const productosVendidos: Record<string, ProductoVendido> = {}
  const clientesActivos: Record<string, ClienteActivo> = {}

  for (const p of activos) {
    const total = p.total || 0
    if (p.estado === 'entregado') {
      ventasPeriodo += total
      pedidosEntregados += 1
      pedidosPorEstado.entregado += 1
    } else {
      // Todo lo no entregado (ni cancelado) es venta en curso: pendiente,
      // asignado y también en_preparacion (raro pero el flujo puede setearlo);
      // en las cards, en_preparacion se agrupa con pendientes (pre-reparto).
      ventasEnCurso += total
      pedidosEnCurso += 1
      if (p.estado === 'asignado') pedidosPorEstado.asignado += 1
      else pedidosPorEstado.pendiente += 1
    }

    p.items?.forEach(i => {
      const id = i.producto_id
      if (!productosVendidos[id]) {
        productosVendidos[id] = { id, nombre: i.producto?.nombre || 'N/A', cantidad: 0 }
      }
      productosVendidos[id].cantidad += i.cantidad
    })

    const clienteId = p.cliente_id
    if (!clientesActivos[clienteId]) {
      clientesActivos[clienteId] = {
        id: clienteId,
        nombre: p.cliente?.nombre_fantasia || 'N/A',
        total: 0,
        pedidos: 0,
      }
    }
    clientesActivos[clienteId].total += total
    clientesActivos[clienteId].pedidos += 1
  }

  return {
    ventasPeriodo,
    ventasEnCurso,
    pedidosPeriodo: activos.length,
    pedidosEntregados,
    pedidosEnCurso,
    pedidosPorEstado,
    productosMasVendidos: Object.values(productosVendidos)
      .sort((a, b) => b.cantidad - a.cantidad)
      .slice(0, 5),
    clientesMasActivos: Object.values(clientesActivos)
      .sort((a, b) => b.total - a.total)
      .slice(0, 5),
  }
}

/**
 * Serie fija de los últimos 7 días calendario terminando en hoyISO, con los
 * días sin ventas en 0. Independiente del período elegido en el filtro.
 */
export function serieVentas7Dias(
  rows: Array<{ fecha?: string | null; total: number | null }>,
  hoyISO: string,
): VentaPorDia[] {
  const porFecha = new Map<string, { ventas: number; pedidos: number }>()
  for (const r of rows) {
    if (!r.fecha) continue
    const acc = porFecha.get(r.fecha) ?? { ventas: 0, pedidos: 0 }
    acc.ventas += r.total || 0
    acc.pedidos += 1
    porFecha.set(r.fecha, acc)
  }

  const serie: VentaPorDia[] = []
  for (let i = 6; i >= 0; i--) {
    const fechaISO = addDiasISO(hoyISO, -i)
    const [y, m, d] = fechaISO.split('-').map(Number)
    const acc = porFecha.get(fechaISO)
    serie.push({
      dia: new Date(y, m - 1, d).toLocaleDateString('es-AR', { weekday: 'short' }),
      ventas: acc?.ventas ?? 0,
      pedidos: acc?.pedidos ?? 0,
    })
  }
  return serie
}
