import { describe, it, expect } from 'vitest'
import { saldoDePedido, armarCuentasPorCobrar } from './cuentasPorCobrar'

const HOY = new Date('2026-09-07T12:00:00Z')

function pedido(over: Record<string, unknown> = {}) {
  return {
    id: 'p1',
    cliente_id: 'c1',
    total: 1000,
    monto_pagado: 0,
    estado: 'entregado',
    fecha: '2026-09-01',
    fecha_entrega: '2026-09-01',
    created_at: '2026-09-01T10:00:00Z',
    ...over,
  }
}

const cliente = { id: 'c1', nombre_fantasia: 'Kiosco Luna', dias_credito: 30, limite_credito: 5000 }

describe('saldoDePedido', () => {
  it('es lo que falta cobrar de ese pedido', () => {
    expect(saldoDePedido(pedido({ total: 1000, monto_pagado: 300 }))).toBe(700)
  })

  it('un pedido sobrepagado no genera saldo negativo', () => {
    // El aging ya salteaba estos pedidos; el saldo tiene que hacer lo mismo o
    // los dos números de la misma fila no coinciden.
    expect(saldoDePedido(pedido({ total: 1000, monto_pagado: 1200 }))).toBe(0)
  })

  it('sin monto_pagado el saldo es el total', () => {
    expect(saldoDePedido(pedido({ total: 1000, monto_pagado: null }))).toBe(1000)
  })

  it('tolera total nulo', () => {
    expect(saldoDePedido(pedido({ total: null, monto_pagado: null }))).toBe(0)
  })
})

describe('armarCuentasPorCobrar', () => {
  describe('el bug que arregla: los dos lados de la resta, el mismo universo', () => {
    it('no le resta a la deuda los pagos de pedidos ya saldados', () => {
      // Éste es el bug de #521. El cliente pagó $190.000 en su vida y hoy debe
      // $1.000. La versión vieja hacía 1.000 − 190.000 y daba −189.000, y como
      // filtraba saldo > 0, el cliente DESAPARECÍA de la lista.
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ id: 'viejo', total: 190000, monto_pagado: 190000 }),
         pedido({ id: 'nuevo', total: 1000, monto_pagado: 0 })],
        HOY,
      )

      expect(filas).toHaveLength(1)
      expect(filas[0].saldoPendiente).toBe(1000)
    })

    it('totalDeuda y totalPagado salen de los MISMOS pedidos', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ id: 'a', total: 1000, monto_pagado: 400 }),
         pedido({ id: 'b', total: 500, monto_pagado: 0 })],
        HOY,
      )

      expect(filas[0].totalDeuda).toBe(1500)
      expect(filas[0].totalPagado).toBe(400)
      expect(filas[0].saldoPendiente).toBe(1100)
    })

    it('el saldo es exactamente deuda menos pagado', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ total: 1000, monto_pagado: 250 })],
        HOY,
      )
      const f = filas[0]
      expect(f.saldoPendiente).toBe(f.totalDeuda - f.totalPagado)
    })
  })

  // La otra inconsistencia silenciosa de la versión vieja: el saldo de la fila
  // y la suma de sus propios tramos de aging eran dos números distintos.
  describe('el saldo cuadra con su propio aging', () => {
    it('saldo == corriente + 30 + 60 + 90, siempre', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [
          pedido({ id: 'a', total: 1000, fecha_entrega: '2026-09-05' }),   // corriente
          pedido({ id: 'b', total: 2000, fecha_entrega: '2026-07-20' }),   // 1-30
          pedido({ id: 'c', total: 3000, fecha_entrega: '2026-06-20' }),   // 31-60
          pedido({ id: 'd', total: 4000, fecha_entrega: '2026-01-10' }),   // +60
        ],
        HOY,
      )
      const f = filas[0]
      const sumaAging = f.aging.corriente + f.aging.vencido30 + f.aging.vencido60 + f.aging.vencido90
      expect(f.saldoPendiente).toBe(sumaAging)
      expect(f.saldoPendiente).toBe(10000)
    })

    it('cuadra también con pedidos parcialmente pagados', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ id: 'a', total: 1000, monto_pagado: 600, fecha_entrega: '2026-09-05' }),
         pedido({ id: 'b', total: 2000, monto_pagado: 500, fecha_entrega: '2026-07-20' })],
        HOY,
      )
      const f = filas[0]
      expect(f.saldoPendiente).toBe(400 + 1500)
      expect(f.aging.corriente + f.aging.vencido30).toBe(f.saldoPendiente)
    })
  })

  describe('los tramos del aging', () => {
    it('un pedido no entregado va a corriente aunque sea viejo', () => {
      // Todavía no recibió la mercadería: no hay mora que contar.
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ estado: 'pendiente', fecha: '2026-01-01', fecha_entrega: null })],
        HOY,
      )
      expect(filas[0].aging.corriente).toBe(1000)
      expect(filas[0].aging.vencido90).toBe(0)
    })

    it('la mora se cuenta desde la entrega, no desde el alta', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ fecha: '2026-01-01', fecha_entrega: '2026-09-01' })],
        HOY,
      )
      expect(filas[0].aging.corriente).toBe(1000)
    })

    it('usa los días de crédito del cliente', () => {
      // Entregado 40 días antes de HOY. Con 60 días de crédito todavía no
      // vence; con 0 días lleva 40 de mora, que es el tramo 31-60 — no el de
      // 1-30, que se cuenta desde el VENCIMIENTO y no desde la entrega.
      const entregaHace40Dias = '2026-07-29'
      const conCredito = armarCuentasPorCobrar(
        [{ ...cliente, dias_credito: 60 }],
        [pedido({ fecha_entrega: entregaHace40Dias })],
        HOY,
      )
      const sinCredito = armarCuentasPorCobrar(
        [{ ...cliente, dias_credito: 0 }],
        [pedido({ fecha_entrega: entregaHace40Dias })],
        HOY,
      )
      expect(conCredito[0].aging.corriente).toBe(1000)
      expect(sinCredito[0].aging.vencido60).toBe(1000)
      expect(sinCredito[0].aging.vencido30).toBe(0)
    })

    it('sin dias_credito asume 30', () => {
      const filas = armarCuentasPorCobrar(
        [{ ...cliente, dias_credito: null }],
        [pedido({ fecha_entrega: '2026-08-20' })],
        HOY,
      )
      expect(filas[0].aging.corriente).toBe(1000)
    })
  })

  describe('quién aparece en la lista', () => {
    it('un cliente sin deuda no aparece', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ total: 1000, monto_pagado: 1000 })],
        HOY,
      )
      expect(filas).toHaveLength(0)
    })

    it('un cliente sin pedidos no aparece', () => {
      expect(armarCuentasPorCobrar([cliente], [], HOY)).toHaveLength(0)
    })

    it('un cliente que sobrepagó no aparece, pero tampoco arrastra a otros', () => {
      const filas = armarCuentasPorCobrar(
        [cliente, { ...cliente, id: 'c2', nombre_fantasia: 'Otro' }],
        [pedido({ cliente_id: 'c1', total: 1000, monto_pagado: 5000 }),
         pedido({ cliente_id: 'c2', total: 800, monto_pagado: 0 })],
        HOY,
      )
      expect(filas.map(f => f.cliente.id)).toEqual(['c2'])
    })

    it('ordena por saldo descendente: primero el que más debe', () => {
      const filas = armarCuentasPorCobrar(
        [{ ...cliente, id: 'c1' }, { ...cliente, id: 'c2' }, { ...cliente, id: 'c3' }],
        [pedido({ cliente_id: 'c1', total: 100 }),
         pedido({ cliente_id: 'c2', total: 9000 }),
         pedido({ cliente_id: 'c3', total: 500 })],
        HOY,
      )
      expect(filas.map(f => f.cliente.id)).toEqual(['c2', 'c3', 'c1'])
    })

    it('los pedidos cancelados no cuentan como deuda', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ estado: 'cancelado', total: 0, monto_pagado: 0 })],
        HOY,
      )
      expect(filas).toHaveLength(0)
    })
  })

  describe('crédito disponible', () => {
    it('sale del saldo arreglado, no del roto', () => {
      const filas = armarCuentasPorCobrar(
        [{ ...cliente, limite_credito: 5000 }],
        [pedido({ total: 190000, monto_pagado: 190000 }), pedido({ id: 'n', total: 2000 })],
        HOY,
      )
      // Con el saldo viejo (−188.000) el disponible daba $193.000.
      expect(filas[0].creditoDisponible).toBe(3000)
    })

    it('sin límite cargado el disponible es negativo, no infinito', () => {
      const filas = armarCuentasPorCobrar(
        [{ ...cliente, limite_credito: null }],
        [pedido({ total: 2000 })],
        HOY,
      )
      expect(filas[0].creditoDisponible).toBe(-2000)
    })
  })

  describe('pedidosPendientes cuenta los que tienen saldo', () => {
    it('no cuenta los que ya están saldados', () => {
      const filas = armarCuentasPorCobrar(
        [cliente],
        [pedido({ id: 'a', total: 1000, monto_pagado: 1000 }),
         pedido({ id: 'b', total: 1000, monto_pagado: 0 }),
         pedido({ id: 'c', total: 500, monto_pagado: 100 })],
        HOY,
      )
      expect(filas[0].pedidosPendientes).toBe(2)
    })
  })
})
