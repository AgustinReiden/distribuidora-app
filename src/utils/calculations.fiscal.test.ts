import { describe, it, expect } from 'vitest'
import { calcularCostoReal, calcularCostoFinanciero, calcularNetoVenta, calcularTotalesCompra, calcularMargenPorcentaje } from './calculations'

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

// Regresión (2026-07-30): ModalProducto calculaba el costo total con la fórmula
// FC aunque el producto fuera ZZ. Inflaba el denominador 21% → el % de margen
// bruto salía negativo con monto positivo, y persistía costo_con_iva inflado.
describe('margen bruto de la ficha según tipo de compra', () => {
  const margenesFicha = (neto: number, precio: number, ii: number, tipo: 'ZZ' | 'FC') => {
    const costoTotal = calcularCostoFinanciero(neto, 21, ii, tipo)
    const costoReal = calcularCostoReal(neto, ii, tipo)
    return {
      bruto: calcularMargenPorcentaje(precio, costoTotal),
      neto: calcularMargenPorcentaje(precio / 1.21, costoReal),
      costoTotal,
    }
  }

  it('ZZ sin II (azúcar 8800 → 10100): lo pagado es el costo total; bruto positivo', () => {
    const m = margenesFicha(8800, 10100, 0, 'ZZ')
    expect(m.costoTotal).toBe(8800) // no 10648
    expect(m.bruto).toBeCloseTo(14.77, 2) // antes daba -5.1
    expect(10100 - m.costoTotal).toBe(1300) // coincide con el monto que ya se mostraba
  })

  it('ZZ: el margen neto sigue negativo — es el escenario "compro en negro, facturo"', () => {
    const m = margenesFicha(8800, 10100, 0, 'ZZ')
    expect(m.neto).toBeCloseTo(-5.15, 2)
    // Y ahora bruto y neto NO coinciden: describen escenarios distintos.
    expect(m.bruto).not.toBeCloseTo(m.neto, 2)
  })

  it('ZZ con II (Manaos cola): el II tampoco se suma, lo pagado ya lo incluye', () => {
    expect(margenesFicha(5665.74, 7000, 8.6956, 'ZZ').costoTotal).toBe(5665.74)
  })

  it('FC sin II: bruto y neto coinciden — correcto, el IVA se cancela de ambos lados', () => {
    const m = margenesFicha(8800, 10100, 0, 'FC')
    expect(m.costoTotal).toBe(10648)
    expect(m.bruto).toBeCloseTo(m.neto, 6)
  })

  it('FC con II: bruto y neto difieren (denominadores distintos)', () => {
    const m = margenesFicha(1000, 1800, 8.6956, 'FC')
    expect(m.bruto).not.toBeCloseTo(m.neto, 2)
  })
})

describe('calcularNetoVenta (mig 123: terna neto / iva / ingreso real)', () => {
  it('FC: neto = precio/(1+IVA%); ingreso real = neto; el II se ignora (no somos agente)', () => {
    // Venta FC de una cola a $10.000 final: aunque el producto tenga II 8,6956%,
    // la factura de venta discrimina solo neto + IVA.
    const d = calcularNetoVenta(10000, 21, 8.6956, 'FC')
    expect(d.neto).toBeCloseTo(8264.46, 2)
    expect(d.iva).toBeCloseTo(1735.54, 2)
    expect(d.impuestosInternos).toBe(0)
    expect(d.ingresoReal).toBeCloseTo(8264.46, 2)
    // Reconstrucción: neto + iva = precio final
    expect(d.neto + d.iva).toBeCloseTo(10000, 2)
    // IVA es exactamente 21% del gravado
    expect(d.iva).toBeCloseTo(d.neto * 0.21, 2)
  })

  it('ZZ: ingreso real = precio final; neto teórico sin IVA; IVA discriminado 0', () => {
    const d = calcularNetoVenta(10000, 21, 8.6956, 'ZZ')
    expect(d.ingresoReal).toBe(10000)
    expect(d.neto).toBeCloseTo(8264.46, 2)
    expect(d.iva).toBe(0)
    expect(d.impuestosInternos).toBe(0)
  })
})

describe('calcularTotalesCompra (estructura de la factura A)', () => {
  const items = [
    // MANAOS COLA 3000cc: 240 packs, bonif 0,60%, II 8,6956%
    { cantidad: 240, costoUnitario: 5397.25, bonificacion: 0.6, porcentajeIva: 21, impuestosInternos: 8.6956 },
    // AGUA S/G 600: 120 packs, bonif 0,60%, II 4,1667%
    { cantidad: 120, costoUnitario: 2796.27, bonificacion: 0.6, porcentajeIva: 21, impuestosInternos: 4.1667 },
    // SODA SIFON: sin II
    { cantidad: 150, costoUnitario: 5123.97, bonificacion: 0.6, porcentajeIva: 21, impuestosInternos: 0 },
  ]

  it('FC: total = gravado + IVA + II + percepciones + no gravado', () => {
    const t = calcularTotalesCompra(items, 'FC', { percepcionIva: 1000, percepcionIibb: 500, noGravado: 2000 })
    const gravadoEsperado = 240 * 5397.25 * 0.994 + 120 * 2796.27 * 0.994 + 150 * 5123.97 * 0.994
    expect(t.subtotal).toBeCloseTo(gravadoEsperado, 2)
    expect(t.iva).toBeCloseTo(gravadoEsperado * 0.21, 0)
    expect(t.impuestosInternos).toBeCloseTo(
      240 * 5397.25 * 0.994 * 0.086956 + 120 * 2796.27 * 0.994 * 0.041667, 2)
    expect(t.total).toBeCloseTo(t.subtotal + t.iva + t.impuestosInternos + 1000 + 500 + 2000, 2)
  })

  it('ZZ: lo pagado es todo — sin IVA, II ni extras aunque vengan cargados', () => {
    const t = calcularTotalesCompra(items, 'ZZ', { percepcionIva: 1000, noGravado: 2000 })
    expect(t.iva).toBe(0)
    expect(t.impuestosInternos).toBe(0)
    expect(t.percepcionIva).toBe(0)
    expect(t.noGravado).toBe(0)
    expect(t.total).toBeCloseTo(t.subtotal, 2)
  })
})
