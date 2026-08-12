import { describe, it, expect } from 'vitest'
import { calcularTotalesNotaCredito } from './notaCredito'

// mig 177: hasta acá la NC liquidaba `subtotal * 0.21` fijo. Contra una factura
// mixta eso inventa crédito fiscal sobre líneas que el proveedor nunca gravó.

const factura = [
  { producto_id: '1', cantidad: 10, costo_unitario: 1000, porcentaje_iva: 21 },
  { producto_id: '2', cantidad: 10, costo_unitario: 500, porcentaje_iva: 10.5 },
  { producto_id: '3', cantidad: 4, costo_unitario: 250, porcentaje_iva: 0, condicion_iva: 'exento' as const },
  { producto_id: '4', cantidad: 2, costo_unitario: 300, porcentaje_iva: 0, condicion_iva: 'no_gravado' as const },
]

describe('calcularTotalesNotaCredito', () => {
  it('usa la alícuota de cada línea, no un 21% fijo', () => {
    const t = calcularTotalesNotaCredito(factura, { '1': 2, '2': 4 })
    expect(t.subtotal).toBeCloseTo(2 * 1000 + 4 * 500, 2) // 4000
    expect(t.iva).toBeCloseTo(2000 * 0.21 + 2000 * 0.105, 2) // 630, no 840
    expect(t.total).toBeCloseTo(4630, 2)
  })

  it('acreditar una línea exenta no genera IVA', () => {
    const t = calcularTotalesNotaCredito(factura, { '3': 4 })
    expect(t.subtotal).toBeCloseTo(1000, 2)
    expect(t.iva).toBe(0)
    expect(t.total).toBeCloseTo(1000, 2)
  })

  it('ni una no gravada', () => {
    const t = calcularTotalesNotaCredito(factura, { '4': 2 })
    expect(t.iva).toBe(0)
    expect(t.total).toBeCloseTo(600, 2)
  })

  it('mezcla gravado con no gravado en la misma nota', () => {
    const t = calcularTotalesNotaCredito(factura, { '1': 1, '3': 1 })
    expect(t.subtotal).toBeCloseTo(1250, 2)
    expect(t.iva).toBeCloseTo(1000 * 0.21, 2) // sólo la línea gravada
    expect(t.itemsConCantidad).toHaveLength(2)
  })

  it('sólo entran las líneas con cantidad > 0', () => {
    const t = calcularTotalesNotaCredito(factura, { '1': 0, '2': 3 })
    expect(t.itemsConCantidad).toHaveLength(1)
    expect(t.itemsConCantidad[0].productoId).toBe('2')
  })

  it('una línea vieja sin snapshot fiscal cae a 21% gravado (compat pre-mig 113)', () => {
    const t = calcularTotalesNotaCredito(
      [{ producto_id: '9', cantidad: 1, costo_unitario: 1000 }], { '9': 1 })
    expect(t.iva).toBeCloseTo(210, 2)
  })
})
