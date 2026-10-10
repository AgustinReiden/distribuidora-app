import { describe, it, expect } from 'vitest'
import {
  calcularImputacion,
  estadoCreditoNotaCredito,
  faltantePedido,
  pedidosImputables,
  validarMontoImputacion,
} from './imputacionCredito'

describe('pedidosImputables', () => {
  const pedidos = [
    { id: 30, fecha: '2026-09-20', total: 1000, monto_pagado: 0, estado: 'entregado' },
    { id: 10, fecha: '2026-09-01', total: 500, monto_pagado: 200, estado: 'entregado' },
    { id: 20, fecha: '2026-09-10', total: 800, monto_pagado: 800, estado: 'entregado' },
    { id: 40, fecha: '2026-09-02', total: 900, monto_pagado: 0, estado: 'cancelado' },
    { id: 50, fecha: '2026-09-01', total: '300.50', monto_pagado: '0', estado: 'pendiente' },
    { id: 60, fecha: '2026-09-03', total: 100, monto_pagado: 99.996, estado: 'entregado' },
  ]

  it('deja sólo los no cancelados con faltante, del más viejo al más nuevo', () => {
    const r = pedidosImputables(pedidos)
    expect(r.map(p => p.id)).toEqual(['10', '50', '30'])
    expect(r[0]).toMatchObject({ faltante: 300, total: 500, montoPagado: 200 })
    expect(r[1].faltante).toBe(300.5)
  })

  it('un pedido anulado no recibe crédito, igual que uno cancelado (#1080)', () => {
    // imputar_credito_a_pedido_impl rechaza los dos estados.
    const r = pedidosImputables([
      ...pedidos,
      { id: 70, fecha: '2026-09-01', total: 700, monto_pagado: 0, estado: 'anulado' },
    ])
    expect(r.map(p => p.id)).toEqual(['10', '50', '30'])
  })

  it('excluye el pedido de origen de la NC', () => {
    expect(pedidosImputables(pedidos, { pedidoOrigenId: '10' }).map(p => p.id)).toEqual(['50', '30'])
    expect(pedidosImputables(pedidos, { pedidoOrigenId: 30 }).map(p => p.id)).toEqual(['10', '50'])
  })

  it('usa created_at cuando el pedido no tiene fecha', () => {
    const r = pedidosImputables([
      { id: 2, created_at: '2026-09-05T10:00:00Z', total: 10, estado: 'entregado' },
      { id: 1, fecha: '2026-09-06', total: 10, estado: 'entregado' },
    ])
    expect(r.map(p => p.id)).toEqual(['2', '1'])
  })
})

describe('faltantePedido', () => {
  it('nunca da negativo', () => {
    expect(faltantePedido({ total: 100, monto_pagado: 150 })).toBe(0)
    expect(faltantePedido({ total: 100, monto_pagado: null })).toBe(100)
  })
})

describe('calcularImputacion', () => {
  it('imputa el mínimo entre crédito y faltante', () => {
    expect(calcularImputacion(16700, 10000)).toEqual({ monto: 10000, resto: 6700 })
    expect(calcularImputacion(5000, 10000)).toEqual({ monto: 5000, resto: 0 })
  })

  it('respeta un monto menor pedido por el usuario', () => {
    expect(calcularImputacion(16700, 10000, 2500)).toEqual({ monto: 2500, resto: 14200 })
  })

  it('no deja pasar un monto mayor al tope', () => {
    expect(calcularImputacion(100, 50, 80)).toEqual({ monto: 50, resto: 50 })
  })

  it('redondea a centavos', () => {
    expect(calcularImputacion(0.3, 0.1 + 0.2)).toEqual({ monto: 0.3, resto: 0 })
    expect(calcularImputacion(100, 33.333)).toEqual({ monto: 33.33, resto: 66.67 })
  })
})

describe('validarMontoImputacion', () => {
  it('rechaza cero, negativos y NaN', () => {
    expect(validarMontoImputacion(0, 100, 100)).toMatch(/mayor a \$0/)
    expect(validarMontoImputacion(-1, 100, 100)).toMatch(/mayor a \$0/)
    expect(validarMontoImputacion(NaN, 100, 100)).toMatch(/mayor a \$0/)
  })

  it('rechaza pasarse del crédito o del faltante', () => {
    expect(validarMontoImputacion(150, 100, 200)).toMatch(/crédito disponible/)
    expect(validarMontoImputacion(150, 200, 100)).toMatch(/le falta al pedido/)
  })

  it('acepta hasta el mínimo, con tolerancia de medio centavo', () => {
    expect(validarMontoImputacion(100, 100, 200)).toBeNull()
    expect(validarMontoImputacion(100.004, 100, 200)).toBeNull()
    expect(validarMontoImputacion(0.01, 100, 200)).toBeNull()
  })
})

describe('estadoCreditoNotaCredito', () => {
  const pagos = [
    { id: 1, monto: 6000, pedido_id: 77, nota_credito_id: 5 },
    { id: 2, monto: 4000, pedido_id: null, nota_credito_id: 5 },
    { id: 3, monto: 900, pedido_id: null, nota_credito_id: null },
    { id: 4, monto: 1000, pedido_id: null, nota_credito_id: '6' },
  ]

  it('separa lo disponible de lo ya aplicado', () => {
    expect(estadoCreditoNotaCredito(pagos, '5')).toEqual({
      disponible: 4000,
      aplicado: 6000,
      pagoLibre: { id: '2', monto: 4000 },
    })
  })

  it('NC sin imputar: todo disponible, nada aplicado', () => {
    expect(estadoCreditoNotaCredito(pagos, 6)).toEqual({
      disponible: 1000,
      aplicado: 0,
      pagoLibre: { id: '4', monto: 1000 },
    })
  })

  it('NC ya consumida entera: sin pedazo libre', () => {
    expect(estadoCreditoNotaCredito([{ id: 1, monto: 10, pedido_id: 3, nota_credito_id: 9 }], 9))
      .toEqual({ disponible: 0, aplicado: 10, pagoLibre: null })
  })
})
