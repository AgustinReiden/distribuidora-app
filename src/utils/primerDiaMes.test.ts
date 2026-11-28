import { describe, it, expect } from 'vitest'
import { primerDiaMesLocalISO } from './formatters'

describe('primerDiaMesLocalISO (Fr-B2)', () => {
  it('es el 1° del mes argentino, no el del reloj del dispositivo', () => {
    // 30/11 a las 22 h de Argentina ya es 1/12 en UTC: el mes es noviembre.
    expect(primerDiaMesLocalISO(new Date('2026-12-01T01:00:00Z'))).toBe('2026-11-01')
    expect(primerDiaMesLocalISO(new Date('2026-12-01T03:00:00Z'))).toBe('2026-12-01')
  })
})
