import { describe, it, expect } from 'vitest'
import { calcularTotalesNotaCredito, costosAcreditablesPorProducto } from './notaCredito'

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
 * precios—. Las cantidades siguen indexadas por línea (con `producto_id` las dos
 * filas leían la misma cantidad y se acreditaba el doble), pero desde #1471 el
 * producto se acredita al costo neto PROMEDIO de sus renglones: la base no sabe
 * de qué renglón sale cada unidad (decisión del dueño, 05/11).
 */
describe('calcularTotalesNotaCredito · dos líneas del mismo producto', () => {
  const dosLineas = [
    { id: '101', producto_id: '7', cantidad: 6, costo_unitario: 1000, porcentaje_iva: 21 },
    { id: '102', producto_id: '7', cantidad: 4, costo_unitario: 1500, porcentaje_iva: 21 },
  ]

  it('acredita sólo lo pedido, no las dos líneas', () => {
    const t = calcularTotalesNotaCredito(dosLineas, { '101': 3 })
    expect(t.itemsConCantidad).toHaveLength(1)
    // promedio: (6·1000 + 4·1500) / 10 = 1200
    expect(t.subtotal).toBeCloseTo(3600, 2)
    expect(t.iva).toBeCloseTo(756, 2)
  })

  it('las dos filas son un solo item del producto, al costo promedio', () => {
    const t = calcularTotalesNotaCredito(dosLineas, { '101': 2, '102': 2 })
    expect(t.itemsConCantidad).toEqual([{ productoId: '7', cantidad: 4, costoUnitario: 1200, subtotal: 4800 }])
  })

  it('devolver todo acredita lo que se pagó', () => {
    const t = calcularTotalesNotaCredito(dosLineas, { '101': 6, '102': 4 })
    expect(t.subtotal).toBeCloseTo(12000, 2)
  })
})

/**
 * #1471 (STK-F-3): la nota acreditaba el costo ANTES de la bonificación, y un
 * regalo al 100 % se acreditaba a precio lleno.
 */
describe('calcularTotalesNotaCredito · bonificación', () => {
  it('un renglón bonificado se acredita neto', () => {
    const t = calcularTotalesNotaCredito(
      [{ id: '1', producto_id: '5', cantidad: 10, costo_unitario: 1000, bonificacion: 10, porcentaje_iva: 21 }],
      { '1': 2 })
    expect(t.subtotal).toBeCloseTo(1800, 2)
    expect(t.iva).toBeCloseTo(378, 2)
  })

  it('un regalo al 100 % no acredita nada', () => {
    const t = calcularTotalesNotaCredito(
      [{ id: '1', producto_id: '5', cantidad: 3, costo_unitario: 800, bonificacion: 100, porcentaje_iva: 21 }],
      { '1': 3 })
    expect(t.subtotal).toBe(0)
    expect(t.iva).toBe(0)
    expect(t.itemsConCantidad).toEqual([{ productoId: '5', cantidad: 3, costoUnitario: 0, subtotal: 0 }])
  })

  it('10 pagos y 2 de regalo: cada unidad vale el promedio, y todo da lo pagado', () => {
    const lineas = [
      { id: '1', producto_id: '5', cantidad: 10, costo_unitario: 100, porcentaje_iva: 21 },
      { id: '2', producto_id: '5', cantidad: 2, costo_unitario: 100, bonificacion: 100, porcentaje_iva: 21 },
    ]
    expect(costosAcreditablesPorProducto(lineas)['5'].costo).toBeCloseTo(1000 / 12, 6)
    expect(calcularTotalesNotaCredito(lineas, { '1': 6 }).subtotal).toBe(500)
    expect(calcularTotalesNotaCredito(lineas, { '1': 10, '2': 2 }).subtotal).toBe(1000)
  })

  it('redondea por producto a 2 decimales, como la base', () => {
    const t = calcularTotalesNotaCredito(
      [{ id: '1', producto_id: '5', cantidad: 3, costo_unitario: 100, bonificacion: 0, porcentaje_iva: 21 },
       { id: '2', producto_id: '5', cantidad: 3, costo_unitario: 100, bonificacion: 100, porcentaje_iva: 21 }],
      { '1': 1 })
    expect(t.subtotal).toBe(50)
    expect(t.iva).toBe(10.5)
  })

  it('la bonificación llega como texto desde PostgREST y vale igual', () => {
    const t = calcularTotalesNotaCredito(
      [{ id: '1', producto_id: '5', cantidad: 4, costo_unitario: 250, bonificacion: '50', porcentaje_iva: 21 }],
      { '1': 4 })
    expect(t.subtotal).toBe(500)
  })
})
