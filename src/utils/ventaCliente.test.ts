import { describe, it, expect } from 'vitest'
import { calcularVentaCliente, calcularRitmoCompra, type PedidoVentaCliente } from './ventaCliente'

const pedido = (p: Partial<PedidoVentaCliente> & { id: string }): PedidoVentaCliente => ({
  cliente_id: '1',
  estado: 'entregado',
  estado_pago: 'pendiente',
  canal: 'app',
  total: 0,
  fecha: '2026-10-01',
  created_at: '2026-10-01T15:00:00Z',
  ...p,
})

describe('calcularVentaCliente (venta de la mig 241: entregado, canal <> cambio)', () => {
  it('sin pedidos: todo en cero', () => {
    expect(calcularVentaCliente([])).toEqual({
      totalComprado: 0, cantidadCompras: 0, pedidosPagados: 0, pendienteEntrega: 0, pedidosPendientesEntrega: 0,
      consumoInterno: { monto: 0, cantidad: 0 },
    })
  })

  it('un pedido entregado es venta', () => {
    const r = calcularVentaCliente([pedido({ id: 'a', total: 1000 })])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
    expect(r.pendienteEntrega).toBe(0)
  })

  it('un pedido tomado y no entregado NO es venta: va a lo pendiente de entrega', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 1000 }),
      pedido({ id: 'b', total: 500, estado: 'pendiente' }),
      pedido({ id: 'c', total: 300, estado: 'asignado' }),
    ])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
    expect(r.pendienteEntrega).toBe(800)
    expect(r.pedidosPendientesEntrega).toBe(2)
  })

  it("un canje (canal 'cambio') sin entregar no suma a lo pendiente de entrega", () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 500, estado: 'pendiente' }),
      pedido({ id: 'b', total: 0, estado: 'pendiente', canal: 'cambio' }),
      pedido({ id: 'c', total: 0, estado: 'asignado', canal: 'cambio' }),
    ])
    expect(r.pendienteEntrega).toBe(500)
    expect(r.pedidosPendientesEntrega).toBe(1)
  })

  it('pedidosPagados usa la base de las compras: pagados entre las ventas, sin pendientes, canjes ni VB', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 100, estado_pago: 'pagado' }),
      pedido({ id: 'b', total: 100, estado_pago: 'pendiente' }),
      pedido({ id: 'c', total: 100, estado: 'pendiente', estado_pago: 'pagado' }),
      pedido({ id: 'd', total: 0, canal: 'cambio', estado_pago: 'pagado' }),
      pedido({ id: 'e', total: 100, tipo_factura: 'VB', estado_pago: 'pagado' }),
    ])
    expect(r.cantidadCompras).toBe(2)
    expect(r.pedidosPagados).toBe(1)
  })

  it('un pedido cancelado no es venta ni pendiente', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 1000 }),
      pedido({ id: 'b', total: 700, estado: 'cancelado' }),
    ])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
    expect(r.pendienteEntrega).toBe(0)
    expect(r.pedidosPendientesEntrega).toBe(0)
  })

  it("un pedido de canal 'cambio' entregado no cuenta como compra", () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 1000 }),
      pedido({ id: 'b', total: 0, canal: 'cambio' }),
    ])
    expect(r.totalComprado).toBe(1000)
    expect(r.cantidadCompras).toBe(1)
  })

  it('un pedido cargado de noche (created_at ya es el día siguiente en UTC) cuenta igual: la venta es por fecha, no por created_at', () => {
    // 22:30 en Argentina del 30/09 = 01:30 UTC del 01/10.
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 400, fecha: '2026-09-30', created_at: '2026-10-01T01:30:00Z' }),
    ])
    expect(r.totalComprado).toBe(400)
    expect(r.cantidadCompras).toBe(1)
  })

  it('un vale blanco (VB) no es venta: va aparte como consumo interno', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 1000, tipo_factura: 'ZZ' }),
      pedido({ id: 'b', total: 400, tipo_factura: 'FC' }),
      pedido({ id: 'c', total: 250, tipo_factura: 'VB' }),
      pedido({ id: 'd', total: 150, tipo_factura: 'VB' }),
    ])
    expect(r.totalComprado).toBe(1400)
    expect(r.cantidadCompras).toBe(2)
    expect(r.consumoInterno).toEqual({ monto: 400, cantidad: 2 })
  })

  it('un cliente sólo-VB: total comprado en cero y todo el movimiento en consumo interno', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 900, tipo_factura: 'VB' }),
    ])
    expect(r.totalComprado).toBe(0)
    expect(r.cantidadCompras).toBe(0)
    expect(r.consumoInterno).toEqual({ monto: 900, cantidad: 1 })
  })

  it('un VB cancelado (total 0) no suma al consumo interno', () => {
    const r = calcularVentaCliente([
      pedido({ id: 'a', total: 0, tipo_factura: 'VB', estado: 'cancelado' }),
    ])
    expect(r.consumoInterno).toEqual({ monto: 0, cantidad: 0 })
  })

  it('total null se toma como 0', () => {
    const r = calcularVentaCliente([pedido({ id: 'a', total: null })])
    expect(r.totalComprado).toBe(0)
    expect(r.cantidadCompras).toBe(1)
  })
})

describe('calcularRitmoCompra (días sin comprar y frecuencia: sólo ventas, por pedidos.fecha)', () => {
  const HOY = '2026-10-10'

  it('sin ventas: días null y frecuencia 0', () => {
    expect(calcularRitmoCompra([], HOY)).toEqual({ diasDesdeUltimaCompra: null, frecuenciaCompra: 0 })
  })

  // `pedidos.fecha` es editable: una venta entregada re-fechada a futuro no
  // puede dejar "Días sin Comprar" en negativo.
  it('una venta con fecha futura da 0 días, no negativo', () => {
    const r = calcularRitmoCompra([pedido({ id: 'a', fecha: '2026-10-15' })], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(0)
  })

  it('días = hoy menos la fecha de la última venta', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-09-01' }),
      pedido({ id: 'b', fecha: '2026-10-05' }),
    ], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(5)
  })

  it('un pendiente tomado ayer NO resetea los días', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-10-01' }),
      pedido({ id: 'b', fecha: '2026-10-09', estado: 'pendiente' }),
      pedido({ id: 'c', fecha: '2026-10-09', estado: 'asignado' }),
    ], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(9)
  })

  it('un canje entregado tampoco resetea los días', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-10-01' }),
      pedido({ id: 'b', fecha: '2026-10-09', canal: 'cambio', total: 0 }),
    ], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(9)
  })

  it('un vale blanco entregado tampoco resetea los días', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-10-01' }),
      pedido({ id: 'b', fecha: '2026-10-09', tipo_factura: 'VB' }),
    ], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(9)
  })

  it('un cancelado tampoco resetea los días', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-10-01' }),
      pedido({ id: 'b', fecha: '2026-10-09', estado: 'cancelado' }),
    ], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(9)
  })

  it('un cliente sólo con pendientes, canjes y VB: sin días y sin frecuencia', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', estado: 'pendiente' }),
      pedido({ id: 'b', canal: 'cambio' }),
      pedido({ id: 'c', tipo_factura: 'VB' }),
    ], HOY)
    expect(r).toEqual({ diasDesdeUltimaCompra: null, frecuenciaCompra: 0 })
  })

  it('un pedido cargado a las 22hs argentinas cuenta por su fecha, no por el created_at en UTC', () => {
    // 22:30 del 09/10 en Argentina = 01:30 UTC del 10/10. Hoy es 10/10: pasó 1 día, no 0.
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-10-09', created_at: '2026-10-10T01:30:00Z' }),
    ], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(1)
  })

  it('una venta sin fecha cae a la fecha argentina de su created_at', () => {
    // 01:30 UTC del 10/10 = 22:30 del 09/10 en Argentina.
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: null, created_at: '2026-10-10T01:30:00Z' }),
    ], HOY)
    expect(r.diasDesdeUltimaCompra).toBe(1)
  })

  it('frecuencia = ventas / meses entre la primera y la última (meses de 30 días)', () => {
    // 90 días = 3 meses; 6 ventas => 2 por mes.
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-07-01' }),
      pedido({ id: 'b', fecha: '2026-08-01' }),
      pedido({ id: 'c', fecha: '2026-08-15' }),
      pedido({ id: 'd', fecha: '2026-09-01' }),
      pedido({ id: 'e', fecha: '2026-09-15' }),
      pedido({ id: 'f', fecha: '2026-09-29' }),
    ], HOY)
    expect(r.frecuenciaCompra).toBe(2)
  })

  it('frecuencia con 2 ventas muy juntas usa 1 mes como piso', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-10-01' }),
      pedido({ id: 'b', fecha: '2026-10-02' }),
    ], HOY)
    expect(r.frecuenciaCompra).toBe(2)
  })

  it('frecuencia: con una sola venta es 0', () => {
    expect(calcularRitmoCompra([pedido({ id: 'a' })], HOY).frecuenciaCompra).toBe(0)
  })

  it('frecuencia ignora pendientes, canjes, VB y cancelados', () => {
    const r = calcularRitmoCompra([
      pedido({ id: 'a', fecha: '2026-07-01' }),
      pedido({ id: 'b', fecha: '2026-09-29' }),
      pedido({ id: 'c', fecha: '2026-10-05', estado: 'pendiente' }),
      pedido({ id: 'd', fecha: '2026-10-05', canal: 'cambio' }),
      pedido({ id: 'e', fecha: '2026-10-05', tipo_factura: 'VB' }),
      pedido({ id: 'f', fecha: '2026-06-01', estado: 'cancelado' }),
    ], HOY)
    // 2 ventas en 90 días (3 meses).
    expect(r.frecuenciaCompra).toBeCloseTo(2 / 3, 10)
  })

  it('no depende del orden en que llegan las filas', () => {
    const filas = [
      pedido({ id: 'a', fecha: '2026-09-29' }),
      pedido({ id: 'b', fecha: '2026-07-01' }),
    ]
    expect(calcularRitmoCompra(filas, HOY)).toEqual(calcularRitmoCompra([...filas].reverse(), HOY))
  })
})
