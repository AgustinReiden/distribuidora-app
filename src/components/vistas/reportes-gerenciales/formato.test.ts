import { describe, it, expect } from 'vitest'
import { margenNetoMesPct, etiquetaDiaSerie, serieCruzaAnios, pct, pctSobre } from './formato'

describe('margenNetoMesPct', () => {
  it('venta − CMV − bonif. sobre la venta', () => {
    expect(margenNetoMesPct({ venta: 100000, cmv: 60000, bonif: 5000 })).toBeCloseTo(0.35, 6)
  })

  it('los descuentos de proveedores (mig 280) suman al margen, como en los kpis', () => {
    expect(margenNetoMesPct({ venta: 100000, cmv: 60000, bonif: 5000, descuentos_proveedores: 2000 })).toBeCloseTo(0.37, 6)
  })

  it('un mes sin venta no tiene margen: null (la tabla muestra «—»), no 0 ni NaN', () => {
    expect(margenNetoMesPct({ venta: 0, cmv: 0, bonif: 0, descuentos_proveedores: 500 })).toBeNull()
  })

  it('un mes de venta negativa (notas de crédito de otro mes) tampoco: null, no un % al revés (H4)', () => {
    expect(margenNetoMesPct({ venta: -1000, cmv: 0, bonif: 0 })).toBeNull()
  })

  it('H4: la venta sin costo no es margen ni cuenta en la base, igual que la card del período', () => {
    // Venta 100.000 con 10.000 sin costo, CMV 54.000 (de lo que sí tiene costo), bonif 5.000:
    // margen neto = 100.000 − 10.000 − 54.000 − 5.000 = 31.000 sobre 90.000 = 34,4 %.
    // Sin separar lo sin costo daría (100.000 − 54.000 − 5.000) / 100.000 = 41 %.
    expect(margenNetoMesPct({ venta: 100000, cmv: 54000, bonif: 5000 }, 10000)).toBeCloseTo(31000 / 90000, 6)
    expect(margenNetoMesPct({ venta: 100000, cmv: 54000, bonif: 5000 })).toBeCloseTo(0.41, 6)
  })

  it('con todo el mes sin costo (base 0) devuelve null', () => {
    expect(margenNetoMesPct({ venta: 10000, cmv: 0, bonif: 0 }, 10000)).toBeNull()
  })
})

describe('etiquetaDiaSerie (REP-10)', () => {
  it('un día ISO se lee DD/MM', () => {
    expect(etiquetaDiaSerie('2026-10-31', false)).toBe('31/10')
  })

  it('con más de un año suma el año de dos dígitos', () => {
    expect(etiquetaDiaSerie('2026-12-31', true)).toBe('31/12/26')
    expect(etiquetaDiaSerie('2027-01-05', true)).toBe('05/01/27')
  })

  it('el formato viejo DD/MM (caché, PWA viejo) vuelve tal cual', () => {
    expect(etiquetaDiaSerie('31/10', false)).toBe('31/10')
    expect(etiquetaDiaSerie('31/10', true)).toBe('31/10')
  })

  it('serieCruzaAnios sólo mira los días ISO', () => {
    expect(serieCruzaAnios(['2026-12-30', '2027-01-02'])).toBe(true)
    expect(serieCruzaAnios(['2026-01-30', '2026-12-02'])).toBe(false)
    expect(serieCruzaAnios(['30/12', '02/01'])).toBe(false)
  })
})

describe('pct (1544-b8)', () => {
  it('un ratio común se lee con una coma y un decimal', () => {
    expect(pct(0.31)).toBe('31,0%')
    expect(pct(-0.052)).toBe('-5,2%')
  })

  it('bonificaciones sobre venta 0 (ratio infinito) no dice «Infinity%»', () => {
    expect(pct(5000 / 0)).toBe('—')
    expect(pct(-5000 / 0)).toBe('—')
  })

  it('0, NaN y undefined siguen dando 0,0%', () => {
    expect(pct(0)).toBe('0,0%')
    expect(pct(0 / 0)).toBe('0,0%')
    expect(pct(undefined as unknown as number)).toBe('0,0%')
  })
})

describe('pctSobre — la base 0 o negativa no da un porcentaje', () => {
  it('con base positiva es el porcentaje de siempre', () => {
    expect(pctSobre(31, 100)).toBe('31,0%')
    expect(pctSobre(-5, 100)).toBe('-5,0%')
  })

  it('con venta 0 muestra «—», no «Infinity%» ni «0,0%»', () => {
    expect(pctSobre(5000, 0)).toBe('—')
    expect(pctSobre(0, 0)).toBe('—')
  })

  it('con venta negativa (neta de notas de crédito) muestra «—», no un 175,8 % al revés', () => {
    // margen −1.758 sobre venta −1.000: dividir negativo con negativo daría +175,8 %.
    expect(pctSobre(-1758, -1000)).toBe('—')
    expect(pctSobre(300, -1000)).toBe('—')
  })

  it('con una base que no es un número muestra «—»', () => {
    expect(pctSobre(5, Number.NaN)).toBe('—')
    expect(pctSobre(5, undefined as unknown as number)).toBe('—')
  })
})
