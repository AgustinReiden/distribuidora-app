import { describe, it, expect } from 'vitest'
import { rendimientoKmPorLitro, costoPorKm, armarFichaVehiculo, type LecturaKm } from './vehiculos'
import { mesDe } from './gastos'
import type { Gasto } from '../types/gastos'

describe('rendimientoKmPorLitro', () => {
  it('tanque lleno: km de la última menos la primera, sobre los litros de las demás', () => {
    // (185030 − 184230) / (40 + 42) = 800 / 82 = 9,756…
    expect(rendimientoKmPorLitro([
      { fecha: '2026-10-01', km: 184230, litros: 38.5 },
      { fecha: '2026-10-10', km: 184630, litros: 40 },
      { fecha: '2026-10-20', km: 185030, litros: 42 },
    ])).toBe(9.8)
  })

  it('no depende del orden en que vienen las cargas', () => {
    expect(rendimientoKmPorLitro([
      { fecha: '2026-10-20', km: 185030, litros: 42 },
      { fecha: '2026-10-01', km: 184230, litros: 38.5 },
      { fecha: '2026-10-10', km: 184630, litros: 40 },
    ])).toBe(9.8)
  })

  it('con una sola carga, o ninguna, no hay rendimiento', () => {
    expect(rendimientoKmPorLitro([{ fecha: '2026-10-01', km: 184230, litros: 38.5 }])).toBeNull()
    expect(rendimientoKmPorLitro([])).toBeNull()
  })

  it('dos cargas con el mismo km no dan un rendimiento inventado', () => {
    expect(rendimientoKmPorLitro([
      { fecha: '2026-10-01', km: 100, litros: 10 },
      { fecha: '2026-10-02', km: 100, litros: 10 },
    ])).toBeNull()
  })
})

describe('costoPorKm', () => {
  it('divide el costo por los km', () => {
    expect(costoPorKm(80000, 800)).toBe(100)
    expect(costoPorKm(1000, 300)).toBe(3.33)
  })

  it('sin km no hay costo por km', () => {
    expect(costoPorKm(1, 0)).toBeNull()
    expect(costoPorKm(1, -5)).toBeNull()
  })
})

describe('armarFichaVehiculo', () => {
  const g = (p: Partial<Gasto> & Pick<Gasto, 'id' | 'fecha' | 'costo'>): Gasto => ({
    sucursal_id: 1, compartido: false, rubro_id: 1, monto_total: p.costo, comprobante: 'ticket',
    comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0, percepcion_iibb: 0,
    otros_impuestos: 0, neto: p.costo, vehiculo_id: 7, litros: null, mes_imputado: mesDe(p.fecha),
    repartir_meses: 1, mes_fin: mesDe(p.fecha), origen_pago: 'oficina', observacion: null,
    creado_por: 'u', anulado_at: null, created_at: p.fecha,
    rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' }, ...p,
  })

  const MES = '2026-10-01'
  const combustible = [
    g({ id: 1, fecha: '2026-10-01', costo: 40000, litros: 38.5 }),
    g({ id: 2, fecha: '2026-10-10', costo: 42000, litros: 40 }),
    g({ id: 3, fecha: '2026-10-20', costo: 44000, litros: 42 }),
  ]
  const lecturas: LecturaKm[] = [
    { fecha: '2026-10-01', km: 184230, origen: 'carga', gasto_id: 1 },
    { fecha: '2026-10-10', km: 184630, origen: 'carga', gasto_id: 2 },
    { fecha: '2026-10-20', km: 185030, origen: 'carga', gasto_id: 3 },
  ]
  const seguro = g({
    id: 4, fecha: '2026-10-05', costo: 1320000, repartir_meses: 12, mes_fin: '2027-09-01',
    rubro: { id: 2, nombre: 'Seguro', grupo: 'vehiculos' },
  })

  it('gasto del mes y de los últimos 12 meses, con cuotas', () => {
    const ficha = armarFichaVehiculo([...combustible, seguro], lecturas, MES)
    expect(ficha.gastoMes).toBe(126000 + 110000)
    // El seguro sólo aporta desde octubre: 1 cuota dentro de la ventana.
    expect(ficha.gasto12Meses).toBe(126000 + 110000)
  })

  it('km por litro y costo por km sólo con datos', () => {
    const con = armarFichaVehiculo(combustible, lecturas, MES)
    expect(con.kmPorLitro).toBe(9.8)
    expect(con.cargas.map(c => c.km)).toEqual([185030, 184630, 184230])
    expect(con.costoKm).toBe(Math.round((126000 / 800) * 100) / 100)

    const sin = armarFichaVehiculo(combustible, [], MES)
    expect(sin.kmPorLitro).toBeNull()
    expect(sin.costoKm).toBeNull()
    expect(sin.cargas.every(c => c.km === null)).toBe(true)
  })

  it('los últimos 6 meses por rubro, del más viejo al más nuevo', () => {
    const ficha = armarFichaVehiculo([...combustible, seguro], lecturas, MES)
    expect(ficha.meses).toEqual(['2026-05-01', '2026-06-01', '2026-07-01', '2026-08-01', '2026-09-01', '2026-10-01'])
    expect(ficha.porRubro.map(r => r.rubro)).toEqual(['Combustible', 'Seguro'])
    expect(ficha.porRubro[0].porMes).toEqual([0, 0, 0, 0, 0, 126000])
  })
})
