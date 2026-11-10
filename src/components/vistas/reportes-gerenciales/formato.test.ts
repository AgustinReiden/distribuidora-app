import { describe, it, expect } from 'vitest'
import { margenNetoMesPct, etiquetaDiaSerie, serieCruzaAnios } from './formato'

describe('margenNetoMesPct', () => {
  it('venta − CMV − bonif. sobre la venta', () => {
    expect(margenNetoMesPct({ venta: 100000, cmv: 60000, bonif: 5000 })).toBeCloseTo(0.35, 6)
  })

  it('los descuentos de proveedores (mig 280) suman al margen, como en los kpis', () => {
    expect(margenNetoMesPct({ venta: 100000, cmv: 60000, bonif: 5000, descuentos_proveedores: 2000 })).toBeCloseTo(0.37, 6)
  })

  it('un mes sin venta da 0, no NaN', () => {
    expect(margenNetoMesPct({ venta: 0, cmv: 0, bonif: 0, descuentos_proveedores: 500 })).toBe(0)
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
