import { describe, it, expect } from 'vitest'
import { serieDeCombos, descuentoPorMes, ratio } from './combosReporte'
import type { ReporteCombos } from '../hooks/queries/useReporteGerencialQuery'

const mensual = [
  { mes: '2026-09', combo_id: 1, combos: 2, venta: 1000, descuento: 200, margen: 300 },
  { mes: '2026-09', combo_id: 2, combos: 1, venta: 500, descuento: 50, margen: 100 },
  { mes: '2026-10', combo_id: 1, combos: 3, venta: 1500, descuento: 300, margen: 450 },
]

describe('serieDeCombos', () => {
  it('suma todos los combos por período, ordenado', () => {
    expect(serieDeCombos(mensual, null)).toEqual([
      { periodo: '2026-09', combos: 3, venta: 1500, descuento: 250, margen: 400 },
      { periodo: '2026-10', combos: 3, venta: 1500, descuento: 300, margen: 450 },
    ])
  })
  it('filtra por combo', () => {
    expect(serieDeCombos(mensual, 2)).toEqual([
      { periodo: '2026-09', combos: 1, venta: 500, descuento: 50, margen: 100 },
    ])
  })
  it('agrupa por semana cuando no hay mes', () => {
    const r = serieDeCombos([{ semana: '2026-10-19', combo_id: 1, combos: 1, venta: 10, descuento: 1, margen: 2 }], null)
    expect(r[0].periodo).toBe('2026-10-19')
  })
  it('tolera valores numéricos como string (numeric de PostgREST)', () => {
    const r = serieDeCombos([{ mes: '2026-10', combo_id: 1, combos: 1, venta: '10.50' as unknown as number, descuento: 1, margen: 2 }], null)
    expect(r[0].venta).toBe(10.5)
  })
})

describe('descuentoPorMes', () => {
  it('indexa el descuento total por mes', () => {
    const m = descuentoPorMes({ mensual } as unknown as ReporteCombos)
    expect(m.get('2026-09')).toBe(250)
    expect(m.get('2026-10')).toBe(300)
  })
  it('sin datos devuelve un mapa vacío', () => {
    expect(descuentoPorMes(undefined).size).toBe(0)
  })
})

describe('ratio', () => {
  it('divide y protege el cero', () => {
    expect(ratio(1, 4)).toBe(0.25)
    expect(ratio(1, 0)).toBe(0)
  })
})
