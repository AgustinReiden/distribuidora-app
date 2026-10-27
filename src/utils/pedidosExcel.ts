import { getFormaPagoDisplay } from './formatters'
import { esTipoVB } from './valeBlanco'
import { cargoEfectivoDePedido } from './montoMinimo'

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
}

/**
 * Hoja 1 del Excel de pedidos. Un vale blanco no tiene forma de pago ni plata cobrada (está
 * saldado por naturaleza): se exporta como consumo interno y con 0 cobrado, para que sumar
 * "Monto Pagado" siga dando cobranza real. La columna `Envío` sólo aparece si algún pedido
 * exportado cobró envío; `Total` no cambia (incluye el envío).
 */
export function filasPedidosExcel(pedidos: PedidoExcel[]): Record<string, unknown>[] {
  const hayEnvio = pedidos.some(p => cargoEfectivoDePedido(p) > 0)
  return pedidos.map(p => ({
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
  }))
}
