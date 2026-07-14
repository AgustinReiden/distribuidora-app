import { describe, it, expect } from 'vitest'
import { calcularCostoReal, calcularCostoFinanciero, calcularNetoVenta } from './calculations'

// Fixture: factura A 0005-00455160 de Refres Now (Manaos) → T.P. Export,
// 16/06/2026. Tasas efectivas de imp. internos sobre el neto:
//   8,6956% colas/granadina/manzana/pomelo · 4,1667% cítricos/aguas/Placer · 0% soda.

describe('calcularCostoReal (canónico, espejo de costo_real_unitario SQL)', () => {
  it('FC: neto + impuestos internos (IVA es crédito, no costo)', () => {
    expect(calcularCostoReal(1000, 8.6956, 'FC')).toBe(1086.956)
    expect(calcularCostoReal(1000, 4.1667, 'FC')).toBe(1041.667)
    expect(calcularCostoReal(1000, 0, 'FC')).toBe(1000)
  })

  it('FC: MANAOS COLA 3000cc de la factura → neto bonif 5364.8665 × 1.086956', () => {
    // precio pack 5397.25 − bonif 0.60% = 5364.8665
    const netoBonif = 5397.25 * (1 - 0.006)
    expect(calcularCostoReal(netoBonif, 8.6956, 'FC')).toBeCloseTo(5831.37, 2)
  })

  it('ZZ: lo pagado tal cual, sin add-on de II', () => {
    expect(calcularCostoReal(1000, 8.6956, 'ZZ')).toBe(1000)
    expect(calcularCostoReal(1500.5, 4.1667, 'ZZ')).toBe(1500.5)
  })

  it('tolera strings y vacíos', () => {
    expect(calcularCostoReal('1000', '4.1667', 'FC')).toBe(1041.667)
    expect(calcularCostoReal('', '', 'FC')).toBe(0)
  })
})

describe('calcularCostoFinanciero (desembolso por unidad, sin percepciones)', () => {
  it('FC: neto × (1 + IVA + II)', () => {
    expect(calcularCostoFinanciero(1000, 21, 8.6956, 'FC')).toBe(1296.956)
    expect(calcularCostoFinanciero(1000, 21, 0, 'FC')).toBe(1210)
  })

  it('ZZ: lo pagado', () => {
    expect(calcularCostoFinanciero(1000, 21, 8.6956, 'ZZ')).toBe(1000)
  })
})

describe('calcularNetoVenta con impuestos internos (estructura de la factura)', () => {
  it('FC: precio final = neto × (1 + IVA + II); IVA = 21% exacto del neto', () => {
    // Venta FC de una cola a $10.000 final
    const d = calcularNetoVenta(10000, 21, 8.6956, 'FC')
    expect(d.neto).toBeCloseTo(7710.36, 2)
    expect(d.iva).toBeCloseTo(1619.18, 2)
    expect(d.impuestosInternos).toBeCloseTo(670.46, 2)
    // Reconstrucción: neto + iva + ii = precio final
    expect(d.neto + d.iva + d.impuestosInternos).toBeCloseTo(10000, 2)
    // Propiedad de la factura real: IVA es exactamente 21% del gravado
    expect(d.iva).toBeCloseTo(d.neto * 0.21, 2)
  })

  it('ZZ: todo el precio final es ingreso neto', () => {
    expect(calcularNetoVenta(10000, 21, 8.6956, 'ZZ')).toEqual({
      neto: 10000, iva: 0, impuestosInternos: 0,
    })
  })
})
