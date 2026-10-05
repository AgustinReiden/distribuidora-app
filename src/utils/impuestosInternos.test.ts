import { describe, it, expect } from 'vitest'
import {
  alicuotaVigente,
  alicuotasProgramadas,
  efectivaDesdeNominal,
  tasaEfectivaEncuadre,
  formatearNominal,
  type AlicuotaII,
} from './impuestosInternos'

// Mismo seed que la mig 277.
const ALICUOTAS: AlicuotaII[] = [
  { id: '1', encuadre_id: '1', tasa_nominal: 0.08, vigente_desde: '2000-01-01', vigente_hasta: null },
  { id: '2', encuadre_id: '2', tasa_nominal: 0.04, vigente_desde: '2000-01-01', vigente_hasta: null },
  { id: '3', encuadre_id: '3', tasa_nominal: 0, vigente_desde: '2000-01-01', vigente_hasta: null },
]

describe('tasaEfectivaEncuadre — espejo de derivar_ii_producto (mig 277)', () => {
  it('General 8% nominal da 8,6957 sobre el neto, como round(8/92*100, 4) en Postgres', () => {
    // El 8,6956 que había en las fichas estaba TRUNCADO: 8,695652... redondea a 8,6957.
    expect(tasaEfectivaEncuadre('1', '2026-10-01', ALICUOTAS)).toBe(8.6957)
  })

  it('Reducida 4% nominal da 4,1667', () => {
    expect(tasaEfectivaEncuadre('2', '2026-10-01', ALICUOTAS)).toBe(4.1667)
  })

  it('un encuadre al 0% da 0', () => {
    expect(tasaEfectivaEncuadre('3', '2026-10-01', ALICUOTAS)).toBe(0)
  })

  it('una alícuota inventada (10%) funciona igual: N alícuotas sin tocar código', () => {
    const conDiez: AlicuotaII[] = [
      ...ALICUOTAS,
      { id: '9', encuadre_id: '9', tasa_nominal: 0.1, vigente_desde: '2000-01-01', vigente_hasta: null },
    ]
    expect(tasaEfectivaEncuadre('9', '2026-10-01', conDiez)).toBe(11.1111)
  })

  it('sin encuadre devuelve null: la base conserva el valor heredado', () => {
    expect(tasaEfectivaEncuadre(null, '2026-10-01', ALICUOTAS)).toBeNull()
    expect(tasaEfectivaEncuadre('', '2026-10-01', ALICUOTAS)).toBeNull()
  })

  it('encuadre sin alícuota vigente a esa fecha da 0, como el COALESCE de la base', () => {
    expect(tasaEfectivaEncuadre('77', '2026-10-01', ALICUOTAS)).toBe(0)
  })

  it('acepta el id como número (los bigint llegan como number)', () => {
    expect(tasaEfectivaEncuadre(1, '2026-10-01', ALICUOTAS)).toBe(8.6957)
  })
})

describe('alicuotaVigente — vigencias', () => {
  const historia: AlicuotaII[] = [
    { id: '1', encuadre_id: '1', tasa_nominal: 0.08, vigente_desde: '2000-01-01', vigente_hasta: '2026-06-30' },
    { id: '2', encuadre_id: '1', tasa_nominal: 0.1, vigente_desde: '2026-07-01', vigente_hasta: null },
  ]

  it('una factura anterior al cambio usa la tasa vieja', () => {
    expect(alicuotaVigente('1', '2026-06-15', historia)?.tasa_nominal).toBe(0.08)
    expect(tasaEfectivaEncuadre('1', '2026-06-15', historia)).toBe(8.6957)
  })

  it('el último día de la vieja todavía es la vieja, el primero de la nueva es la nueva', () => {
    expect(alicuotaVigente('1', '2026-06-30', historia)?.tasa_nominal).toBe(0.08)
    expect(alicuotaVigente('1', '2026-07-01', historia)?.tasa_nominal).toBe(0.1)
  })

  it('una fecha anterior a toda vigencia no tiene alícuota', () => {
    expect(alicuotaVigente('1', '1999-12-31', historia)).toBeNull()
  })
})

describe('vigencia futura (mig 282)', () => {
  // Hoy = 2026-10-05. La vigente quedó cerrada el día antes de la programada,
  // que es lo que hace cambiar_alicuota_ii con una fecha futura.
  const conFutura: AlicuotaII[] = [
    { id: '1', encuadre_id: '1', tasa_nominal: 0.08, vigente_desde: '2000-01-01', vigente_hasta: '2026-10-31' },
    { id: '7', encuadre_id: '1', tasa_nominal: 0.1, vigente_desde: '2026-11-01', vigente_hasta: null },
    { id: '8', encuadre_id: '1', tasa_nominal: 0.12, vigente_desde: '2026-12-01', vigente_hasta: null },
    { id: '9', encuadre_id: '2', tasa_nominal: 0.05, vigente_desde: '2026-11-01', vigente_hasta: null },
  ]

  it('hoy la ficha sigue con la vigente: la futura no se aplica antes de tiempo', () => {
    expect(alicuotaVigente('1', '2026-10-05', conFutura)?.id).toBe('1')
    expect(tasaEfectivaEncuadre('1', '2026-10-05', conFutura)).toBe(8.6957)
  })

  it('el día que empieza, la efectiva es la nueva (lo que escribe el refresco diario)', () => {
    expect(tasaEfectivaEncuadre('1', '2026-10-31', conFutura)).toBe(8.6957)
    expect(tasaEfectivaEncuadre('1', '2026-11-01', conFutura)).toBe(11.1111)
  })

  it('alicuotasProgramadas lista las que todavía no rigen, de la más próxima a la más lejana', () => {
    expect(alicuotasProgramadas('1', '2026-10-05', conFutura).map(a => a.id)).toEqual(['7', '8'])
    expect(alicuotasProgramadas(1, '2026-11-15', conFutura).map(a => a.id)).toEqual(['8'])
    expect(alicuotasProgramadas('2', '2026-10-05', conFutura).map(a => a.id)).toEqual(['9'])
  })

  it('sin encuadre o sin futuras no hay programadas', () => {
    expect(alicuotasProgramadas(null, '2026-10-05', conFutura)).toEqual([])
    expect(alicuotasProgramadas('', '2026-10-05', conFutura)).toEqual([])
    expect(alicuotasProgramadas('1', '2027-01-01', conFutura)).toEqual([])
    expect(alicuotasProgramadas('3', '2026-10-05', ALICUOTAS)).toEqual([])
  })
})

describe('efectivaDesdeNominal / formatearNominal', () => {
  it('el impuesto por dentro: n/(1-n)', () => {
    expect(efectivaDesdeNominal(0.08)).toBeCloseTo(8.695652, 6)
    expect(efectivaDesdeNominal(0.04)).toBeCloseTo(4.166667, 6)
  })

  it('formatea la nominal sin ceros de más', () => {
    expect(formatearNominal(0.08)).toBe('8%')
    expect(formatearNominal(0.045)).toBe('4,5%')
    expect(formatearNominal(0)).toBe('0%')
  })
})
