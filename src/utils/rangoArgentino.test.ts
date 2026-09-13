import { describe, it, expect } from 'vitest'
import { rangoArgentino } from './rangoArgentino'

describe('rangoArgentino', () => {
  it('sin filtros devuelve los dos extremos en null', () => {
    expect(rangoArgentino()).toEqual({ desde: null, hasta: null })
    expect(rangoArgentino({})).toEqual({ desde: null, hasta: null })
  })

  it('arma el rango con el offset fijo -03:00', () => {
    const r = rangoArgentino({ desde: '2026-01-01', hasta: '2026-01-01' })
    expect(r.desde).toBe('2026-01-01T00:00:00-03:00')
    expect(r.hasta).toBe('2026-01-01T23:59:59.999999-03:00')
  })

  it('desde y hasta se resuelven de forma independiente', () => {
    expect(rangoArgentino({ desde: '2026-01-01', hasta: null })).toEqual({
      desde: '2026-01-01T00:00:00-03:00',
      hasta: null,
    })
    expect(rangoArgentino({ desde: null, hasta: '2026-01-31' })).toEqual({
      desde: null,
      hasta: '2026-01-31T23:59:59.999999-03:00',
    })
  })

  // El bug que esto reemplaza: un corte armado sin offset (`${hasta}T23:59:59`)
  // se compara contra timestamptz en UTC, así que un registro cargado a las
  // 22:00 hora Argentina (ya es 01:00 UTC del día siguiente) quedaba afuera
  // del "hoy" aunque para el usuario todavía era hoy.
  it('un movimiento cargado a las 22:00 hora Argentina cae dentro del mismo día', () => {
    const r = rangoArgentino({ desde: '2026-01-01', hasta: '2026-01-01' })

    // 22:00 en Argentina (UTC-03:00) es 01:00 UTC del 2 de enero.
    const cargadoA_22 = new Date('2026-01-02T01:00:00.000Z')

    expect(cargadoA_22.getTime()).toBeGreaterThanOrEqual(new Date(r.desde!).getTime())
    expect(cargadoA_22.getTime()).toBeLessThanOrEqual(new Date(r.hasta!).getTime())

    // El corte del bug (`${hasta}T23:59:59.999999`, sin offset) llega a
    // Postgres y se interpreta en UTC: dos horas antes que el corte correcto
    // en Argentina. Con ese corte el registro de las 22:00 quedaba afuera.
    const cortSinOffsetInterpretadoComoUTC = new Date('2026-01-01T23:59:59.999999Z')
    expect(cargadoA_22.getTime()).toBeGreaterThan(cortSinOffsetInterpretadoComoUTC.getTime())
  })
})
