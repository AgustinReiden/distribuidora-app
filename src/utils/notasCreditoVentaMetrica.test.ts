import { describe, it, expect } from 'vitest'
import {
  notaRestaDeLaVenta,
  notasDelVendedor,
  notasEnVentana,
  totalNotasQueRestan,
  type NotaCreditoVentaMetricaRow,
} from './notasCreditoVentaMetrica'
import { agregarMetricasPeriodo, resumenPeriodoAnterior, serieVentas7Dias } from './metricasDashboard'
import { calcularVentaCliente } from './ventaCliente'

const nota = (total: number, over: Partial<NotaCreditoVentaMetricaRow> = {}, pedido: Record<string, unknown> = {}): NotaCreditoVentaMetricaRow => ({
  fecha: '2026-11-10', cliente_id: 1, total, anulada: false,
  pedido: { estado: 'entregado', canal: 'app', tipo_factura: 'ZZ', usuario_id: 'u1', ...pedido },
  ...over,
})

describe('qué nota resta de la venta (REP-1)', () => {
  it('la vigente de una boleta entregada, común, sí', () => {
    expect(notaRestaDeLaVenta(nota(100))).toBe(true)
  })

  it('la anulada, la de un VB, la de un canje, la de un pedido sin entregar y la sin boleta no', () => {
    expect(notaRestaDeLaVenta(nota(100, { anulada: true }))).toBe(false)
    expect(notaRestaDeLaVenta(nota(100, {}, { tipo_factura: 'VB' }))).toBe(false)
    expect(notaRestaDeLaVenta(nota(100, {}, { canal: 'cambio' }))).toBe(false)
    expect(notaRestaDeLaVenta(nota(100, {}, { estado: 'asignado' }))).toBe(false)
    expect(notaRestaDeLaVenta(nota(100, { pedido: null }))).toBe(false)
  })

  it('un tipo_factura nulo es un comprobante común, no un vale', () => {
    expect(notaRestaDeLaVenta(nota(100, {}, { tipo_factura: null }))).toBe(true)
  })

  it('el total llega como número o como texto; uno ilegible o cero no resta', () => {
    expect(totalNotasQueRestan([nota(100), nota(0), { ...nota(1), total: '50.5' }, { ...nota(1), total: 'NaN' }])).toBe(150.5)
  })

  it('se recortan por día (inclusive) y por vendedor', () => {
    const notas = [nota(1, { fecha: '2026-11-01' }), nota(2, { fecha: '2026-11-10' }, { usuario_id: 'u2' }), nota(4, { fecha: '2026-11-20' })]
    expect(notasEnVentana(notas, '2026-11-01', '2026-11-10').map(n => n.total)).toEqual([1, 2])
    expect(notasEnVentana(notas, '2026-11-10', null).map(n => n.total)).toEqual([2, 4])
    expect(notasEnVentana(notas, null, null)).toHaveLength(3)
    expect(notasDelVendedor(notas, 'u2').map(n => n.total)).toEqual([2])
  })
})

describe('las cifras netas (REP-1)', () => {
  const pedidos = [
    { cliente_id: '1', estado: 'entregado', total: 900, cliente: { nombre_fantasia: 'Uno' } },
    { cliente_id: '2', estado: 'entregado', total: 150, cliente: { nombre_fantasia: 'Dos' } },
    { cliente_id: '2', estado: 'pendiente', total: 40, cliente: { nombre_fantasia: 'Dos' } },
  ]

  it('agregarMetricasPeriodo: la venta y el cliente son netos, los pedidos no cambian', () => {
    const r = agregarMetricasPeriodo(pedidos, [nota(300, { cliente_id: 1 }), nota(50, { cliente_id: 2 })])
    expect(r.ventasPeriodo).toBe(1050 - 350)
    expect(r.ventasEnCurso).toBe(40)
    expect(r.pedidosEntregados).toBe(2)
    expect(r.clientesMasActivos.map(c => [c.id, c.total, c.pedidos])).toEqual([['1', 600, 1], ['2', 140, 2]])
  })

  it('el ranking se ordena por lo neto: una nota grande baja al primero', () => {
    const r = agregarMetricasPeriodo(pedidos, [nota(800, { cliente_id: 1 })])
    expect(r.clientesMasActivos.map(c => c.id)).toEqual(['2', '1'])
  })

  it('sin notas es lo de siempre', () => {
    expect(agregarMetricasPeriodo(pedidos).ventasPeriodo).toBe(1050)
    expect(agregarMetricasPeriodo(pedidos, []).ventasPeriodo).toBe(1050)
  })

  it('resumenPeriodoAnterior y serieVentas7Dias restan las suyas', () => {
    expect(resumenPeriodoAnterior([{ total: 500, estado: 'entregado' }], [nota(120)]).ventas).toBe(380)
    const serie = serieVentas7Dias([{ fecha: '2026-11-10', total: 500 }], '2026-11-10', [nota(120, { fecha: '2026-11-10' })])
    expect(serie[serie.length - 1]).toMatchObject({ ventas: 380, pedidos: 1 })
  })

  it('calcularVentaCliente: el total comprado es neto y las compras no cambian', () => {
    const v = calcularVentaCliente(
      [{ id: '1', cliente_id: '1', estado: 'entregado', total: 1050 }],
      [nota(350)],
    )
    expect(v.totalComprado).toBe(700)
    expect(v.cantidadCompras).toBe(1)
  })
})
