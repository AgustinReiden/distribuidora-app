/**
 * Armado del reporte de cuentas por cobrar.
 *
 * EL BUG QUE ARREGLA (#521): LA RESTA MEZCLABA DOS UNIVERSOS
 * ----------------------------------------------------------
 * La versión anterior hacía:
 *
 *     totalDeuda  = suma de los pedidos NO pagados
 *     totalPagado = suma de TODOS los pagos históricos del cliente
 *     saldo       = totalDeuda - totalPagado
 *
 * Los pedidos venían filtrados por `estado_pago <> 'pagado'`, pero los pagos no
 * se filtraban por nada: se le restaba a la deuda de los impagos toda la plata
 * que el cliente pagó en su vida, incluida la de los pedidos ya saldados. En
 * prod eso eran $10,4M de deuda contra $193,5M de pagos.
 *
 * El saldo salía masivamente negativo, y como al final había un
 * `filter(saldo > 0)`, el cliente no aparecía en rojo: DESAPARECÍA de la lista.
 * O sea que el reporte no exageraba la deuda — se comía deudores.
 *
 * LA REGLA: el saldo se arma pedido por pedido, con `total - monto_pagado`, que
 * es la columna del propio pedido. Es lo que el aging ya venía haciendo bien, y
 * lo que hace que los dos lados de la resta cubran el mismo conjunto.
 *
 * INVARIANTE: saldoPendiente == corriente + vencido30 + vencido60 + vencido90.
 * En la versión anterior eran dos números distintos en la misma fila.
 */

export interface AgingDeuda {
  corriente: number
  vencido30: number
  vencido60: number
  vencido90: number
}

/** Lo que se necesita de un pedido para saber cuánto falta cobrarle. */
export interface PedidoParaCobrar {
  id?: string | number
  cliente_id?: string | number | null
  total?: number | null
  monto_pagado?: number | null
  estado?: string | null
  fecha?: string | null
  fecha_entrega?: string | null
  created_at?: string | null
}

export interface ClienteParaCobrar {
  id: string | number
  dias_credito?: number | null
  limite_credito?: number | null
}

export interface FilaCuentaPorCobrar<C extends ClienteParaCobrar = ClienteParaCobrar> {
  cliente: C
  /** Total facturado de los pedidos que TODAVÍA tienen saldo. */
  totalDeuda: number
  /** Lo ya cobrado DE ESOS MISMOS pedidos, no del histórico del cliente. */
  totalPagado: number
  saldoPendiente: number
  limiteCredito: number
  creditoDisponible: number
  aging: AgingDeuda
  /** Cuántos pedidos tienen saldo. */
  pedidosPendientes: number
}

const num = (v: unknown): number => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

/**
 * Lo que falta cobrar de un pedido. Nunca negativo: un pedido sobrepagado
 * aporta 0 y no le tapa la deuda a los otros pedidos del mismo cliente. Es lo
 * que el aging ya hacía al saltear los pedidos con saldo <= 0; si el saldo no
 * hiciera lo mismo, los dos números de la fila no coincidirían.
 */
export function saldoDePedido(p: PedidoParaCobrar): number {
  return Math.max(0, num(p.total) - num(p.monto_pagado))
}

const DIAS_CREDITO_POR_DEFECTO = 30
const MS_POR_DIA = 1000 * 60 * 60 * 24

function tramoAging(
  p: PedidoParaCobrar,
  diasCredito: number,
  hoy: Date,
): keyof AgingDeuda {
  // Un pedido con saldo pero NO entregado todavía no genera mora: el cliente
  // aún no recibió la mercadería.
  if (p.estado !== 'entregado') return 'corriente'

  // La antigüedad se cuenta desde la ENTREGA. Para entregados sin
  // `fecha_entrega` (datos viejos) se cae a la fecha del pedido.
  const base = p.fecha_entrega || p.fecha || p.created_at
  if (!base) return 'corriente'

  const vencimiento = new Date(base)
  vencimiento.setDate(vencimiento.getDate() + diasCredito)
  const diasVencido = Math.floor((hoy.getTime() - vencimiento.getTime()) / MS_POR_DIA)

  if (diasVencido <= 0) return 'corriente'
  if (diasVencido <= 30) return 'vencido30'
  if (diasVencido <= 60) return 'vencido60'
  return 'vencido90'
}

/**
 * @param clientes - Todos los clientes, incluidos los inactivos: un informe de
 *   deuda que esconde al que debe y ya no opera no sirve para cobrarle.
 * @param pedidos - Los pedidos a considerar. Se ignoran los cancelados y los
 *   que ya no tienen saldo.
 */
export function armarCuentasPorCobrar<C extends ClienteParaCobrar>(
  clientes: readonly C[],
  pedidos: readonly PedidoParaCobrar[],
  hoy: Date = new Date(),
): FilaCuentaPorCobrar<C>[] {
  const porCliente = new Map<string, PedidoParaCobrar[]>()
  for (const p of pedidos) {
    if (p.estado === 'cancelado') continue
    if (saldoDePedido(p) <= 0) continue
    const clave = String(p.cliente_id)
    const acc = porCliente.get(clave)
    if (acc) acc.push(p)
    else porCliente.set(clave, [p])
  }

  const filas: FilaCuentaPorCobrar<C>[] = []

  for (const cliente of clientes) {
    const suyos = porCliente.get(String(cliente.id))
    if (!suyos || suyos.length === 0) continue

    const diasCredito = cliente.dias_credito ?? DIAS_CREDITO_POR_DEFECTO
    const aging: AgingDeuda = { corriente: 0, vencido30: 0, vencido60: 0, vencido90: 0 }

    let totalDeuda = 0
    let totalPagado = 0

    for (const p of suyos) {
      totalDeuda += num(p.total)
      totalPagado += num(p.monto_pagado)
      aging[tramoAging(p, diasCredito, hoy)] += saldoDePedido(p)
    }

    const saldoPendiente = aging.corriente + aging.vencido30 + aging.vencido60 + aging.vencido90
    const limiteCredito = num(cliente.limite_credito)

    filas.push({
      cliente,
      totalDeuda,
      totalPagado,
      saldoPendiente,
      limiteCredito,
      creditoDisponible: limiteCredito - saldoPendiente,
      aging,
      pedidosPendientes: suyos.length,
    })
  }

  return filas.sort((a, b) => b.saldoPendiente - a.saldoPendiente)
}
