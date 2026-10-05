import { describe, it, expect } from 'vitest'
import {
  elegirCostosAnteriores, variacionCosto, formatearVariacion, tooltipCostoAnterior,
} from './costoAnterior'
import type { FilaCostoAnterior, ReferenciaCostoAnterior } from './costoAnterior'

const fila = (
  productoId: number, compraId: number, fecha: string, costo: number | string | null,
  extra: Partial<NonNullable<FilaCostoAnterior['compra']>> = {},
): FilaCostoAnterior => ({
  producto_id: productoId,
  compra_id: compraId,
  costo_real_unitario: costo,
  compra: {
    id: compraId,
    fecha_compra: fecha,
    numero_factura: `0001-0000${compraId}00`,
    tipo_factura: 'FC',
    estado: 'recibida',
    ...extra,
  },
})

const ver = (compraId: string, fechaCompra: string, numeroFactura: string | null = '0009-99999999'): ReferenciaCostoAnterior =>
  ({ compraId, fechaCompra, numeroFactura })

describe('elegirCostosAnteriores', () => {
  it('se queda con la más reciente por (fecha, id), no por orden de llegada', () => {
    const r = elegirCostosAnteriores([
      fila(1, 10, '2026-08-01', 100),
      fila(1, 12, '2026-09-01', 120),
      fila(1, 11, '2026-09-01', 110),
    ], ver('50', '2026-10-01'))
    expect(r.get('1')).toMatchObject({ compraId: '12', costoRealUnitario: 120, fechaCompra: '2026-09-01' })
  })

  it('una compra cargada tarde con fecha vieja no es "la anterior" de las posteriores', () => {
    // La 60 tiene id mayor pero fecha de agosto: para una compra de septiembre,
    // la anterior es la de fecha mayor, no la de id mayor.
    const r = elegirCostosAnteriores([
      fila(1, 60, '2026-08-01', 90),
      fila(1, 40, '2026-08-20', 100),
    ], ver('70', '2026-09-01'))
    expect(r.get('1')?.compraId).toBe('40')
  })

  it('es estrictamente anterior: misma fecha con id mayor o igual no cuenta', () => {
    const filas = [fila(1, 30, '2026-09-10', 100), fila(1, 31, '2026-09-10', 200), fila(1, 29, '2026-09-10', 300)]
    expect(elegirCostosAnteriores(filas, ver('30', '2026-09-10')).get('1')?.compraId).toBe('29')
    // Y una posterior en fecha queda afuera aunque tenga id menor.
    expect(elegirCostosAnteriores([fila(1, 5, '2026-09-11', 1)], ver('30', '2026-09-10')).size).toBe(0)
  })

  it('en una compra nueva (sin id) todo lo del mismo día o antes es anterior', () => {
    const r = elegirCostosAnteriores(
      [fila(1, 900, '2026-10-03', 150), fila(1, 899, '2026-10-02', 140), fila(1, 901, '2026-10-04', 999)],
      { compraId: null, fechaCompra: '2026-10-03', numeroFactura: '' },
    )
    expect(r.get('1')?.compraId).toBe('900')
  })

  it('excluye canceladas, sin costo, la misma compra y la misma factura normalizada', () => {
    const r = elegirCostosAnteriores([
      fila(1, 20, '2026-09-20', 500, { estado: 'cancelada' }),
      fila(1, 19, '2026-09-19', null),
      fila(1, 50, '2026-09-18', 400),                                           // la misma compra
      fila(1, 18, '2026-09-17', 300, { numero_factura: 'A 5-467758' }),         // misma factura, escrita distinto
      fila(1, 17, '2026-09-16', 200),
    ], ver('50', '2026-09-30', 'A0005-00467758'))
    expect(r.get('1')?.compraId).toBe('17')
  })

  it('un número de factura basura (pocos dígitos) no excluye nada', () => {
    const r = elegirCostosAnteriores(
      [fila(1, 18, '2026-09-17', 300, { numero_factura: '0006' })],
      ver('50', '2026-09-30', '6'),
    )
    expect(r.get('1')?.compraId).toBe('18')
  })

  it('separa por producto y acepta costos que llegan como texto (numeric de PostgREST)', () => {
    const r = elegirCostosAnteriores([fila(1, 10, '2026-09-01', '1028.6324'), fila(2, 10, '2026-09-01', 7)], ver('50', '2026-10-01'))
    expect(r.get('1')?.costoRealUnitario).toBeCloseTo(1028.6324, 6)
    expect(r.get('2')?.costoRealUnitario).toBe(7)
    expect(r.has('3')).toBe(false)
  })

  it('guarda el tipo de comprobante de la anterior', () => {
    const r = elegirCostosAnteriores([fila(1, 10, '2026-09-01', 100, { tipo_factura: 'ZZ' })], ver('50', '2026-10-01'))
    expect(r.get('1')?.tipoFactura).toBe('ZZ')
  })
})

describe('variacionCosto y formatearVariacion', () => {
  it('sube en rojo con signo +, baja con el menos tipográfico', () => {
    expect(formatearVariacion(variacionCosto(112.3, 100)!)).toEqual({ texto: '+12,3%', tono: 'sube' })
    expect(formatearVariacion(variacionCosto(95.9, 100)!)).toEqual({ texto: '−4,1%', tono: 'baja' })
  })

  it('lo que redondea a 0,0% no lleva signo ni color', () => {
    expect(formatearVariacion(variacionCosto(100.04, 100)!)).toEqual({ texto: '0,0%', tono: 'igual' })
    expect(formatearVariacion(variacionCosto(99.96, 100)!)).toEqual({ texto: '0,0%', tono: 'igual' })
  })

  it('sin anterior, con anterior en 0 o con datos no finitos no hay variación', () => {
    expect(variacionCosto(100, null)).toBeNull()
    expect(variacionCosto(null, 100)).toBeNull()
    expect(variacionCosto(100, 0)).toBeNull()
    // Línea 100% bonificada (neto 0): no es una baja del 100%, no se muestra nada.
    expect(variacionCosto(0, 100)).toBeNull()
    expect(variacionCosto(NaN, 100)).toBeNull()
  })

  it('redondea a un decimal', () => {
    expect(formatearVariacion(0.12345).texto).toBe('+12,3%')
    expect(formatearVariacion(2).texto).toBe('+200,0%')
  })
})

describe('tooltipCostoAnterior', () => {
  const anterior = { compraId: '304', fechaCompra: '2026-09-12', costoRealUnitario: 1, tipoFactura: 'FC' as const }
  it('nombra la compra y la fecha corta', () => {
    expect(tooltipCostoAnterior(anterior, 'FC', '2026-10-03')).toBe('compra anterior #304 del 12/09')
  })
  it('avisa cuando la anterior es del otro tipo de comprobante', () => {
    expect(tooltipCostoAnterior(anterior, 'ZZ', '2026-10-03')).toBe('compra anterior #304 del 12/09 (en FC)')
    expect(tooltipCostoAnterior({ ...anterior, tipoFactura: 'ZZ' }, 'FC', '2026-10-03'))
      .toBe('compra anterior #304 del 12/09 (en ZZ)')
  })
})
