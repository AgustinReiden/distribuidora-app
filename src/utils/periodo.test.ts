/**
 * `formatDiaLargo` con fechas fijas: el constructor `new Date(a, m, d)` arma la
 * fecha en hora LOCAL, así que el resultado no depende del huso donde corra la
 * suite (un `new Date('2026-04-21')` sí: eso es medianoche UTC y en Argentina
 * cae el 20).
 */
import { describe, it, expect } from 'vitest'
import { DIAS_SEMANA, MESES, formatDiaLargo } from './periodo'

describe('DIAS_SEMANA / MESES', () => {
  it('los días están en el orden de Date#getDay (0 = domingo)', () => {
    expect(DIAS_SEMANA).toHaveLength(7)
    expect(DIAS_SEMANA[0]).toBe('DOMINGO')
    expect(DIAS_SEMANA[6]).toBe('SÁBADO')
  })

  it('los meses están en el orden de Date#getMonth (0 = enero)', () => {
    expect(MESES).toHaveLength(12)
    expect(MESES[0]).toBe('ENERO')
    expect(MESES[11]).toBe('DICIEMBRE')
  })
})

describe('formatDiaLargo', () => {
  it('martes 21 de abril de 2026 → "MARTES 21 DE ABRIL"', () => {
    expect(formatDiaLargo(new Date(2026, 3, 21, 10, 0, 0))).toBe('MARTES 21 DE ABRIL')
  })

  it('domingo (getDay = 0) y enero (getMonth = 0)', () => {
    expect(formatDiaLargo(new Date(2026, 0, 4))).toBe('DOMINGO 4 DE ENERO')
  })

  it('sábado y diciembre: los dos extremos de las listas', () => {
    expect(formatDiaLargo(new Date(2026, 11, 26))).toBe('SÁBADO 26 DE DICIEMBRE')
  })

  it('el día NO se rellena con cero a la izquierda', () => {
    expect(formatDiaLargo(new Date(2026, 8, 1))).toBe('MARTES 1 DE SEPTIEMBRE')
  })

  it('la hora del día no cambia el resultado', () => {
    expect(formatDiaLargo(new Date(2026, 3, 21, 23, 59, 59)))
      .toBe(formatDiaLargo(new Date(2026, 3, 21, 0, 0, 0)))
  })
})
