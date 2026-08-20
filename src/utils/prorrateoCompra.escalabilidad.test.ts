// Garantia de que el motor no asume gaseosas: sirve para cualquier rubro, con o
// sin impuesto interno, con cualquier alicuota de IVA. Sin cargos el costo se
// reduce a neto x (1 + II%), que es la formula de siempre.

import { describe, it, expect } from 'vitest'
import { calcularCostosCompra, type LineaCompra } from './prorrateoCompra'
const L = (o: Partial<LineaCompra> = {}): LineaCompra => ({
  id: 1, cantidad: 10, costoUnitario: 100, bonificacion: 0,
  impuestosInternos: 0, porcentajeIva: 21, condicionIva: 'gravado', ...o })

describe('escalabilidad fuera de gaseosas', () => {
  it('sin impuesto interno y sin cargos: costo = neto', () => {
    const r = calcularCostosCompra([L()], [], {})
    expect(r.lineas[0].costoRealUnitario).toBe(100)
  })
  it('con impuesto interno y sin cargos: costo = neto x (1 + II%)', () => {
    const r = calcularCostosCompra([L({ impuestosInternos: 8.6956 })], [], {})
    expect(r.lineas[0].costoRealUnitario).toBeCloseTo(108.6956, 4)
  })
  it('con bonificacion de linea: el neto ya viene bonificado', () => {
    const r = calcularCostosCompra([L({ bonificacion: 10, impuestosInternos: 4.1667 })], [], {})
    expect(r.lineas[0].costoNetoUnitario).toBe(90)
    expect(r.lineas[0].costoRealUnitario).toBeCloseTo(90 * 1.041667, 4)
  })
  it('rubro no gravado (exento) y sin II: costo = neto, IVA 0', () => {
    const r = calcularCostosCompra([L({ condicionIva: 'exento', porcentajeIva: 0 })], [], {})
    expect(r.lineas[0].costoRealUnitario).toBe(100)
    expect(r.lineas[0].ivaUnitario).toBe(0)
  })
  it('alicuota de II arbitraria (no de gaseosas): 17,3913%', () => {
    const r = calcularCostosCompra([L({ impuestosInternos: 17.3913 })], [], {})
    expect(r.lineas[0].costoRealUnitario).toBeCloseTo(117.3913, 4)
  })
  it('IVA 10,5% (rubro alimentos): el II no se toca', () => {
    const r = calcularCostosCompra([L({ porcentajeIva: 10.5, impuestosInternos: 0 })], [], {})
    expect(r.lineas[0].ivaUnitario).toBe(10.5)
    expect(r.lineas[0].costoRealUnitario).toBe(100)
  })
})
