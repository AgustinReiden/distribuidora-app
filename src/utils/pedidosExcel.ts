import { getFormaPagoDisplay } from './formatters'
import { esTipoVB } from './valeBlanco'
import { cargoEfectivoDePedido } from './montoMinimo'
import { entregaMarcada } from './entregaMarcada'

interface PedidoExcel {
  id: number | string
  estado: string
  estado_pago?: string | null
  tipo_factura?: string | null
  total: number
  cargo_envio?: number | null
  monto_pagado?: number | null
  notas?: string | null
  fecha?: string | null
  created_at?: string | null
  cliente?: unknown
  transportista?: unknown
  usuario?: unknown
  entregado_at?: string | null
  entregado_por_perfil?: { nombre?: string | null } | null
}

/**
 * Hoja 1 del Excel de pedidos. Un vale blanco no tiene forma de pago ni plata cobrada (está
 * saldado por naturaleza): se exporta como consumo interno y con 0 cobrado, para que sumar
 * "Monto Pagado" siga dando cobranza real. La columna `Envío` sólo aparece si algún pedido
 * exportado cobró envío; `Total` no cambia (incluye el envío).
 */
export function filasPedidosExcel(pedidos: PedidoExcel[]): Record<string, unknown>[] {
  const hayEnvio = pedidos.some(p => cargoEfectivoDePedido(p) > 0)
  return pedidos.map(p => {
    const entrega = entregaMarcada(p)
    return {
      ID: p.id,
      Cliente: (p.cliente as { nombre_fantasia?: string })?.nombre_fantasia || '',
      Direccion: (p.cliente as { direccion?: string })?.direccion || '',
      Telefono: (p.cliente as { telefono?: string })?.telefono || '',
      Estado: p.estado,
      'Forma Pago': esTipoVB(p.tipo_factura)
        ? 'Vale blanco (consumo interno)'
        : getFormaPagoDisplay(p as { forma_pago?: string | null; pagos?: Array<{ forma_pago: string }> }),
      'Estado Pago': esTipoVB(p.tipo_factura) ? 'consumo_interno' : (p.estado_pago || ''),
      Total: p.total,
      ...(hayEnvio ? { 'Envío': cargoEfectivoDePedido(p) } : {}),
      'Monto Pagado': esTipoVB(p.tipo_factura) ? 0 : (p.monto_pagado || 0),
      Transportista: (p.transportista as { nombre?: string })?.nombre || '',
      Preventista: (p.usuario as { nombre?: string })?.nombre || '',
      Notas: p.notas || '',
      Fecha: p.fecha || p.created_at || '',
      'Entrega marcada por': entrega?.quien ?? '',
      'Entrega marcada el': entrega?.cuando ?? '',
    }
  })
}

/**
 * Hoja 4 del Excel de pedidos ("Resumen Pagos"), 1598-b3. Un vale blanco está saldado por
 * naturaleza (`estado_pago = 'pagado'`, cero pagos) y su total es a costo: contarlo como
 * «pagado» inflaba la cobranza. Va en su propia fila, `consumo_interno`, igual que en la hoja 1.
 */
export function resumenPagosExcel(pedidos: PedidoExcel[]): { 'Estado Pago': string; Cantidad: number; 'Total $': number }[] {
  const conteo: Record<string, { cantidad: number; total: number }> = {}
  for (const p of pedidos) {
    const clave = esTipoVB(p.tipo_factura) ? 'consumo_interno' : (p.estado_pago || 'pendiente')
    if (!conteo[clave]) conteo[clave] = { cantidad: 0, total: 0 }
    conteo[clave].cantidad++
    conteo[clave].total += p.total
  }
  return Object.entries(conteo).map(([estado, info]) => ({
    'Estado Pago': estado,
    Cantidad: info.cantidad,
    'Total $': info.total,
  }))
}
