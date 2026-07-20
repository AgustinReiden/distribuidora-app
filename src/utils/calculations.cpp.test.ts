import { describe, it, expect } from 'vitest'
import { calcularCostoPromedioPonderado, calcularCostoReal } from './calculations'

// Espejo TS de la fórmula CPP de registrar_compra_completa (mig 128).
// Caso guía del negocio: compra ZZ de 100u a $121 (total = costo), se venden
// 20, quedan 80; luego compra FC a $100 neto. Con "último costo" las 80u
// viejas se revaluaban a 100 (margen inflado); con CPP quedan a 109,33.

describe('calcularCostoPromedioPonderado (espejo SQL mig 128)', () => {
  it('caso 121/100 del negocio: 80u a 121 + 100u a 100 → 109,3333', () => {
    const costoZZ = calcularCostoReal(121, 0, 'ZZ') // 121: total pagado = costo
    expect(costoZZ).toBe(121)
    const cpp = calcularCostoPromedioPonderado(80, costoZZ, 100, 100)
    expect(cpp).toBeCloseTo(109.3333, 4)
  })

  it('caso E2E del plan: stock 100 a CPP 100 + compra 100u a 121 → 110,5', () => {
    expect(calcularCostoPromedioPonderado(100, 100, 100, 121)).toBe(110.5)
  })

  it('stock 0 o negativo: el promedio se resetea al costo de la compra', () => {
    expect(calcularCostoPromedioPonderado(0, 121, 50, 100)).toBe(100)
    expect(calcularCostoPromedioPonderado(-30, 121, 50, 100)).toBe(100)
  })

  it('CPP nulo o 0 (producto sin historial): toma el costo de la compra', () => {
    expect(calcularCostoPromedioPonderado(80, null, 100, 100)).toBe(100)
    expect(calcularCostoPromedioPonderado(80, undefined, 100, 100)).toBe(100)
    expect(calcularCostoPromedioPonderado(80, 0, 100, 100)).toBe(100)
  })

  it('dos líneas del mismo producto en una compra promedian igual en cualquier orden', () => {
    // stock 100 @ 100, líneas de 50 @ 120 y 50 @ 124 → (100×100+50×120+50×124)/200 = 111
    const ordenA = calcularCostoPromedioPonderado(
      150, calcularCostoPromedioPonderado(100, 100, 50, 120), 50, 124)
    const ordenB = calcularCostoPromedioPonderado(
      150, calcularCostoPromedioPonderado(100, 100, 50, 124), 50, 120)
    expect(ordenA).toBeCloseTo(111, 4)
    expect(ordenB).toBeCloseTo(111, 4)
  })

  it('cantidad 0 (regalo / línea sin costo): el CPP no cambia', () => {
    expect(calcularCostoPromedioPonderado(80, 121, 0, 0)).toBe(121)
  })

  it('el costo que sube también promedia (simetría, sin sesgo)', () => {
    // stock 100 @ 100, compra 100 @ 140 → 120
    expect(calcularCostoPromedioPonderado(100, 100, 100, 140)).toBe(120)
  })

  it('redondea a 4 decimales como el SQL', () => {
    // (3×10 + 1×11)/4 = 10.25; (1×10.3333 + 2×11)/3 = 10.7778
    expect(calcularCostoPromedioPonderado(3, 10, 1, 11)).toBe(10.25)
    expect(calcularCostoPromedioPonderado(1, 10.3333, 2, 11)).toBe(10.7778)
  })
})
