import { describe, it, expect } from 'vitest'
import { primerDiaDelMesEnCurso, rotuloPeriodo } from './periodoMesEnCurso'

describe('primerDiaDelMesEnCurso (día argentino)', () => {
  it('a mitad de mes da el 1 del mes', () => {
    expect(primerDiaDelMesEnCurso(new Date('2026-11-27T15:00:00Z'))).toBe('2026-11-01')
  })
  it('a las 22 h argentinas del último día del mes (ya es el mes siguiente en UTC) sigue en el mes', () => {
    // 2026-11-30 22:00 AR = 2026-12-01 01:00 UTC
    expect(primerDiaDelMesEnCurso(new Date('2026-12-01T01:00:00Z'))).toBe('2026-11-01')
  })
  it('a las 00:30 del día 1 argentino ya es el mes nuevo', () => {
    expect(primerDiaDelMesEnCurso(new Date('2026-12-01T03:30:00Z'))).toBe('2026-12-01')
  })
  it('el último día del año a las 22 h no salta de año', () => {
    expect(primerDiaDelMesEnCurso(new Date('2027-01-01T01:00:00Z'))).toBe('2026-12-01')
  })
})

describe('rotuloPeriodo', () => {
  it('mes en curso: «Noviembre · del 1 al 27»', () => {
    expect(rotuloPeriodo('2026-11-01', null, '2026-11-27')).toBe('Noviembre · del 1 al 27')
  })
  it('con hasta explícito dentro del mes', () => {
    expect(rotuloPeriodo('2026-11-05', '2026-11-12', '2026-11-27')).toBe('Noviembre · del 5 al 12')
  })
  it('un solo día', () => {
    expect(rotuloPeriodo('2026-11-27', '2026-11-27', '2026-11-27')).toBe('Noviembre · el 27')
  })
  it('el día 1 del mes, sólo ese día', () => {
    expect(rotuloPeriodo('2026-11-01', null, '2026-11-01')).toBe('Noviembre · el 1')
  })
  it('cruza de mes: dice las dos fechas (los 30 días de antes)', () => {
    expect(rotuloPeriodo('2026-10-28', null, '2026-11-27')).toBe('Del 28 de octubre al 27 de noviembre')
  })
  it('cruza de año', () => {
    expect(rotuloPeriodo('2026-12-20', '2027-01-03', '2027-01-10')).toBe('Del 20 de diciembre al 3 de enero')
  })
  it('sin límites: todo el historial', () => {
    expect(rotuloPeriodo(null, null, '2026-11-27')).toBe('Todo el historial')
  })
  it('sólo hasta', () => {
    expect(rotuloPeriodo(null, '2026-11-10', '2026-11-27')).toBe('Hasta el 10 de noviembre')
  })
})
