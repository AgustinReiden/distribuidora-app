import { esTipoVB } from './valeBlanco'

/**
 * Lo que falta cobrar de una ruta (el «Pendiente» de /recorridos).
 *
 * Rut-B11 (ola 3, T3 de #1677): `recorridos.total_cobrado` pasó a ser sólo la plata que
 * entró por las boletas (sin el saldo a favor ni la nota de crédito aplicados), así que
 * «facturado − cobrado» ya no es lo que se debe: una boleta de 1.000 pagada 700 en efectivo y
 * 300 con saldo a favor daba «Pendiente 300» y el cliente no debe nada. Lo pendiente se mide
 * contra lo pagado de la boleta (`monto_pagado`, que incluye el crédito aplicado), con el
 * mismo corte que usaba la ruta antes: las paradas vivas (pendiente o entregado) de pedidos
 * entregados, sin los vales blancos (que no se facturan). El facturado es el de la ruta.
 */
export interface ParadaParaPendiente {
  estado_entrega?: string | null
  pedido?: { estado?: string | null; monto_pagado?: number | string | null; tipo_factura?: string | null } | null
}

export function pendienteDeRuta(totalFacturado: number | null | undefined, paradas: readonly ParadaParaPendiente[]): number {
  let pagado = 0
  for (const p of paradas) {
    if (p.estado_entrega !== 'pendiente' && p.estado_entrega !== 'entregado') continue
    if (p.pedido?.estado !== 'entregado' || esTipoVB(p.pedido.tipo_factura)) continue
    pagado += Number(p.pedido.monto_pagado) || 0
  }
  return Math.round(((Number(totalFacturado) || 0) - pagado) * 100) / 100
}
