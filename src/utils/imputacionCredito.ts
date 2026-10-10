/**
 * Imputar un crédito a favor del cliente a un pedido ELEGIDO.
 *
 * Un "crédito" es una fila de `pagos` sin pedido (`pedido_id IS NULL`): el
 * sobrante de un pago a cuenta, un anticipo o la nota de crédito de venta
 * (`nota_credito_id`, mig 276). La RPC `imputar_credito_a_pedido` le pone el
 * pedido a ese crédito por LEAST(crédito, faltante del pedido, monto pedido) y
 * deja el resto como una fila nueva, otra vez sin pedido.
 *
 * Esto es la cuenta que ve la UI antes de confirmar; la que vale es la de la
 * RPC, que la rehace con el `monto_pagado` del momento. Las reglas son las mismas:
 *   - el pedido no está cancelado y le falta plata (> medio centavo);
 *   - una NC no se imputa al pedido del que salió (sería devolverle al pedido
 *     lo que se le acreditó por vencidos: el crédito es para OTRA compra);
 *   - lo imputado nunca pasa ni el crédito ni lo que le falta al pedido.
 */
import { esPedidoDeBaja } from './pedidoDeBaja'

/** Medio centavo: lo mismo que usan las RPCs de pagos para "no queda nada". */
export const TOLERANCIA_CENTAVOS = 0.005

export function redondear2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100
}

function num(v: number | string | null | undefined): number {
  const n = typeof v === 'string' ? parseFloat(v) : (v ?? 0)
  return Number.isFinite(n) ? n : 0
}

/** Lo mínimo de un pedido que hace falta para decidir si se le puede imputar. */
export interface PedidoParaImputar {
  id: string | number
  fecha?: string | null
  created_at?: string | null
  total: number | string | null
  monto_pagado?: number | string | null
  estado: string
}

export interface PedidoImputable {
  id: string
  /** YYYY-MM-DD (o el `created_at` si el pedido no tiene `fecha`). */
  fecha: string | null
  total: number
  montoPagado: number
  /** Lo que le falta cobrar: total − pagado, redondeado a centavos. */
  faltante: number
}

/** Lo que le falta cobrar a un pedido (nunca negativo). */
export function faltantePedido(p: Pick<PedidoParaImputar, 'total' | 'monto_pagado'>): number {
  return Math.max(0, redondear2(num(p.total) - num(p.monto_pagado)))
}

/**
 * Pedidos a los que se puede imputar un crédito: no cancelados, con faltante, y
 * sin el pedido de origen de la NC. Ordenados del más viejo al más nuevo (el
 * mismo orden que usa la imputación FIFO), con el faltante ya calculado.
 */
export function pedidosImputables(
  pedidos: ReadonlyArray<PedidoParaImputar>,
  { pedidoOrigenId }: { pedidoOrigenId?: string | number | null } = {},
): PedidoImputable[] {
  const origen = pedidoOrigenId == null ? null : String(pedidoOrigenId)
  return pedidos
    // Cancelado o anulado (#1080): imputar_credito_a_pedido_impl rechaza los dos.
    .filter(p => !esPedidoDeBaja(p.estado))
    .filter(p => origen === null || String(p.id) !== origen)
    .map(p => ({
      id: String(p.id),
      fecha: p.fecha ?? p.created_at ?? null,
      total: num(p.total),
      montoPagado: num(p.monto_pagado),
      faltante: faltantePedido(p),
    }))
    .filter(p => p.faltante > TOLERANCIA_CENTAVOS)
    .sort((a, b) => {
      const fa = a.fecha ?? ''
      const fb = b.fecha ?? ''
      if (fa !== fb) return fa < fb ? -1 : 1
      return Number(a.id) - Number(b.id)
    })
}

/**
 * Cuánto se imputa y cuánto queda a favor. Sin `montoPedido` se imputa todo lo
 * posible: el mínimo entre el crédito y el faltante.
 */
export function calcularImputacion(
  credito: number,
  faltante: number,
  montoPedido?: number | null,
): { monto: number; resto: number } {
  const tope = Math.min(credito, faltante, montoPedido ?? Number.POSITIVE_INFINITY)
  const monto = Math.max(0, redondear2(tope))
  return { monto, resto: Math.max(0, redondear2(credito - monto)) }
}

/** `null` si el monto es válido; si no, el mensaje para el usuario. */
export function validarMontoImputacion(monto: number, credito: number, faltante: number): string | null {
  if (!Number.isFinite(monto) || monto <= 0) return 'El monto a imputar tiene que ser mayor a $0'
  const maximo = redondear2(Math.min(credito, faltante))
  if (redondear2(monto) - maximo > TOLERANCIA_CENTAVOS) {
    return monto > credito + TOLERANCIA_CENTAVOS
      ? 'El monto no puede superar el crédito disponible'
      : 'El monto no puede superar lo que le falta al pedido'
  }
  return null
}

/** Lo mínimo de un pago para leer el estado del crédito de una NC. */
export interface PagoDeCredito {
  id: string | number
  monto: number | string
  pedido_id?: string | number | null
  nota_credito_id?: string | number | null
}

export interface EstadoCreditoNC {
  /** Lo que sigue a favor (pagos de la NC sin pedido). */
  disponible: number
  /** Lo ya imputado a pedidos. Con algo acá la NC ya no se puede anular. */
  aplicado: number
  /**
   * El pedazo libre más grande, que es el que se ofrece imputar. Normalmente
   * hay uno solo: cada imputación deja el resto en una única fila nueva.
   */
  pagoLibre: { id: string; monto: number } | null
}

/** Estado del crédito de una NC a partir de los pagos del cliente. */
export function estadoCreditoNotaCredito(
  pagos: ReadonlyArray<PagoDeCredito>,
  notaCreditoId: string | number,
): EstadoCreditoNC {
  const nc = String(notaCreditoId)
  let disponible = 0
  let aplicado = 0
  let pagoLibre: EstadoCreditoNC['pagoLibre'] = null
  for (const p of pagos) {
    if (p.nota_credito_id == null || String(p.nota_credito_id) !== nc) continue
    const monto = num(p.monto)
    if (p.pedido_id == null) {
      disponible += monto
      if (!pagoLibre || monto > pagoLibre.monto) pagoLibre = { id: String(p.id), monto }
    } else {
      aplicado += monto
    }
  }
  return { disponible: redondear2(disponible), aplicado: redondear2(aplicado), pagoLibre }
}
