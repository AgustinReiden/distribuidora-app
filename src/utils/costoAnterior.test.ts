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

/**
 * #1333: el orden es (fecha_compra, created_at, id), el de
 * `_reposicion_desde_ultima_compra`. El caso es el clon de
 * `cambiar_proveedor_compra`: X (id 100) se carga a las 9 e Y (id 101) a las 12,
 * las dos del 10/10. Al cambiarle el proveedor a X nace X' con el id 102 y la
 * hora del alta de X, y X se cancela. Por id, X' parecería posterior a Y.
 */
describe('elegirCostosAnteriores · el orden de las compras de un mismo día', () => {
  const FECHA = '2026-10-10'
  const A_LAS_9 = '2026-10-10T09:00:00.123456+00:00'
  const A_LAS_12 = '2026-10-10T12:00:00+00:00'
  const clon = (costo = 300) => fila(1, 102, FECHA, costo, { created_at: A_LAS_9 })
  const y = (costo = 200) => fila(1, 101, FECHA, costo, { created_at: A_LAS_12 })
  const delDiaAnterior = fila(1, 90, '2026-10-09', 100, { created_at: '2026-10-09T09:00:00+00:00' })

  it('el clon, con id mayor, sigue siendo anterior a la compra que se cargó después de la original', () => {
    const r = elegirCostosAnteriores(
      [clon(), delDiaAnterior],
      { compraId: '101', createdAt: A_LAS_12, fechaCompra: FECHA, numeroFactura: null },
    )
    expect(r.get('1')?.compraId).toBe('102')
  })

  it('para el clon, la compra de id menor cargada después no es anterior', () => {
    const r = elegirCostosAnteriores(
      [y(), delDiaAnterior],
      { compraId: '102', createdAt: A_LAS_9, fechaCompra: FECHA, numeroFactura: null },
    )
    expect(r.get('1')?.compraId).toBe('90')
  })

  it('entre candidatas gana la última cargada, no la de id mayor', () => {
    const r = elegirCostosAnteriores([clon(), y()], ver('200', '2026-10-11'))
    expect(r.get('1')).toMatchObject({ compraId: '101', costoRealUnitario: 200 })
  })

  it('compara instantes: la hora puede venir con otro huso', () => {
    const r = elegirCostosAnteriores(
      [
        fila(1, 101, FECHA, 200, { created_at: '2026-10-10T06:00:00-03:00' }), // las 9 UTC
        fila(1, 102, FECHA, 300, { created_at: '2026-10-10T08:00:00+00:00' }),
      ],
      ver('200', '2026-10-11'),
    )
    // Como texto "06:00" va antes que "08:00", y por id ganaría la 102.
    expect(r.get('1')?.compraId).toBe('101')
  })

  it('con la misma hora desempata el id', () => {
    const r = elegirCostosAnteriores(
      [fila(1, 101, FECHA, 200, { created_at: A_LAS_9 }), fila(1, 102, FECHA, 300, { created_at: A_LAS_9 })],
      ver('200', '2026-10-11'),
    )
    expect(r.get('1')?.compraId).toBe('102')
  })

  it('sin la hora de la referencia desempata el id, como antes', () => {
    const r = elegirCostosAnteriores([clon(), y()], { compraId: '102', fechaCompra: FECHA, numeroFactura: null })
    expect(r.get('1')?.compraId).toBe('101')
  })
})

describe('elegirCostosAnteriores · sin regalos, como _reposicion_desde_ultima_compra', () => {
  const regalo = (compraId: number, fecha: string, extra: Partial<FilaCostoAnterior>): FilaCostoAnterior =>
    ({ ...fila(1, compraId, fecha, 0), ...extra })

  it('una línea bonificada al 100% no es "la anterior": se compara contra la que fijó el costo', () => {
    const r = elegirCostosAnteriores([
      regalo(20, '2026-09-20', { costo_unitario: 1000, bonificacion: 100 }),
      { ...fila(1, 19, '2026-09-10', 950), costo_unitario: 1000, bonificacion: 5 },
    ], ver('50', '2026-09-30'))
    expect(r.get('1')).toMatchObject({ compraId: '19', costoRealUnitario: 950 })
  })

  it('una línea a costo 0 tampoco, aunque los cargos le dejen un costo final', () => {
    const r = elegirCostosAnteriores([
      regalo(20, '2026-09-20', { costo_unitario: 0, bonificacion: 0, costo_real_unitario: 12 }),
      { ...fila(1, 19, '2026-09-10', 950), costo_unitario: 1000, bonificacion: 0 },
    ], ver('50', '2026-09-30'))
    expect(r.get('1')?.compraId).toBe('19')
  })

  it('si sólo hubo regalos, no hay contra qué comparar', () => {
    const r = elegirCostosAnteriores(
      [regalo(20, '2026-09-20', { costo_unitario: 1000, bonificacion: 100 })],
      ver('50', '2026-09-30'),
    )
    expect(r.has('1')).toBe(false)
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
    // Una FC sin letra (anterior a la mig 293) es A.
    expect(tooltipCostoAnterior(anterior, 'ZZ', '2026-10-03')).toBe('compra anterior #304 del 12/09 (en FC A)')
    expect(tooltipCostoAnterior({ ...anterior, tipoFactura: 'ZZ' }, 'FC', '2026-10-03'))
      .toBe('compra anterior #304 del 12/09 (en ZZ)')
  })
  it('mig 293: la letra cuenta — una B contra una A se avisa, A contra A (o sin letra) no', () => {
    expect(tooltipCostoAnterior({ ...anterior, letraComprobante: 'B' }, 'FC', '2026-10-03', 'A'))
      .toBe('compra anterior #304 del 12/09 (en FC B)')
    expect(tooltipCostoAnterior(anterior, 'FC', '2026-10-03', 'B'))
      .toBe('compra anterior #304 del 12/09 (en FC A)')
    expect(tooltipCostoAnterior({ ...anterior, letraComprobante: 'A' }, 'FC', '2026-10-03', null))
      .toBe('compra anterior #304 del 12/09')
  })
})
