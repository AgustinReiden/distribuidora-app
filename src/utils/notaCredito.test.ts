import { describe, it, expect } from 'vitest'
import { calcularTotalesNotaCredito } from './notaCredito'

// mig 177: hasta acá la NC liquidaba `subtotal * 0.21` fijo. Contra una factura
// mixta eso inventa crédito fiscal sobre líneas que el proveedor nunca gravó.

// Las cantidades se indexan por `compra_items.id`, no por producto: ver abajo.
const factura = [
  { id: '91', producto_id: '1', cantidad: 10, costo_unitario: 1000, porcentaje_iva: 21 },
  { id: '92', producto_id: '2', cantidad: 10, costo_unitario: 500, porcentaje_iva: 10.5 },
  { id: '93', producto_id: '3', cantidad: 4, costo_unitario: 250, porcentaje_iva: 0, condicion_iva: 'exento' as const },
  { id: '94', producto_id: '4', cantidad: 2, costo_unitario: 300, porcentaje_iva: 0, condicion_iva: 'no_gravado' as const },
]

describe('calcularTotalesNotaCredito', () => {
  it('usa la alícuota de cada línea, no un 21% fijo', () => {
    const t = calcularTotalesNotaCredito(factura, { '91': 2, '92': 4 })
    expect(t.subtotal).toBeCloseTo(2 * 1000 + 4 * 500, 2) // 4000
    expect(t.iva).toBeCloseTo(2000 * 0.21 + 2000 * 0.105, 2) // 630, no 840
    expect(t.total).toBeCloseTo(4630, 2)
  })

  it('acreditar una línea exenta no genera IVA', () => {
    const t = calcularTotalesNotaCredito(factura, { '93': 4 })
    expect(t.subtotal).toBeCloseTo(1000, 2)
    expect(t.iva).toBe(0)
    expect(t.total).toBeCloseTo(1000, 2)
  })

  it('ni una no gravada', () => {
    const t = calcularTotalesNotaCredito(factura, { '94': 2 })
    expect(t.iva).toBe(0)
    expect(t.total).toBeCloseTo(600, 2)
  })

  it('mezcla gravado con no gravado en la misma nota', () => {
    const t = calcularTotalesNotaCredito(factura, { '91': 1, '93': 1 })
    expect(t.subtotal).toBeCloseTo(1250, 2)
    expect(t.iva).toBeCloseTo(1000 * 0.21, 2) // sólo la línea gravada
    expect(t.itemsConCantidad).toHaveLength(2)
  })

  it('sólo entran las líneas con cantidad > 0', () => {
    const t = calcularTotalesNotaCredito(factura, { '91': 0, '92': 3 })
    expect(t.itemsConCantidad).toHaveLength(1)
    expect(t.itemsConCantidad[0].productoId).toBe('2')
  })

  it('una línea vieja sin snapshot fiscal cae a 21% gravado (compat pre-mig 113)', () => {
    const t = calcularTotalesNotaCredito(
      [{ id: '99', producto_id: '9', cantidad: 1, costo_unitario: 1000 }], { '99': 1 })
    expect(t.iva).toBeCloseTo(210, 2)
  })
})

/**
 * Dos renglones del mismo producto en la misma factura.
 *
 * Se llega igual por tres caminos —el import de Excel apilaba sin deduplicar, el
 * escaneo también, y una factura real puede traer el mismo producto a dos
 * precios— y con `producto_id` como clave las dos líneas leían la MISMA cantidad
 * del mapa: el subtotal y el IVA salían al doble y se guardaban dos items.
 */
describe('calcularTotalesNotaCredito · dos líneas del mismo producto', () => {
  const dosLineas = [
    { id: '101', producto_id: '7', cantidad: 6, costo_unitario: 1000, porcentaje_iva: 21 },
    { id: '102', producto_id: '7', cantidad: 4, costo_unitario: 1500, porcentaje_iva: 21 },
  ]

  it('acredita sólo la línea pedida, no las dos', () => {
    const t = calcularTotalesNotaCredito(dosLineas, { '101': 3 })
    expect(t.itemsConCantidad).toHaveLength(1)
    expect(t.subtotal).toBeCloseTo(3000, 2)
    expect(t.iva).toBeCloseTo(630, 2)
  })

  it('cada línea acredita a SU costo', () => {
    const t = calcularTotalesNotaCredito(dosLineas, { '101': 1, '102': 1 })
    expect(t.itemsConCantidad).toHaveLength(2)
    expect(t.itemsConCantidad.map((i) => i.costoUnitario)).toEqual([1000, 1500])
    expect(t.subtotal).toBeCloseTo(2500, 2)
    expect(t.iva).toBeCloseTo(525, 2)
  })

  it('las dos filas apuntan al mismo producto en el payload', () => {
    const t = calcularTotalesNotaCredito(dosLineas, { '101': 2, '102': 2 })
    expect(t.itemsConCantidad.map((i) => i.productoId)).toEqual(['7', '7'])
    expect(t.itemsConCantidad.map((i) => i.subtotal)).toEqual([2000, 3000])
  })
})
