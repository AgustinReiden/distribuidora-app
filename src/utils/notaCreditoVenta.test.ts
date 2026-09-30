import { describe, expect, it } from 'vitest'
import {
  itemsNotaCreditoParaRPC,
  lineasAcreditables,
  motivoNCVentaLabel,
  totalNotaCreditoVenta,
  totalNotasCreditoVigentes,
  validarNotaCreditoVenta,
} from './notaCreditoVenta'

// Pedido 6510 de prod (el del ensayo de la mig 276), con un renglón duplicado de
// producto para cubrir que la clave es la línea y no el producto.
const items = [
  { id: 23807, producto_id: 10, cantidad: 1, precio_unitario: 11100, es_bonificacion: false, producto: { nombre: 'Fideos' } },
  { id: 23808, producto_id: 11, cantidad: 1, precio_unitario: '5600', es_bonificacion: false, producto: { nombre: 'Arroz' } },
  { id: 23809, producto_id: 10, cantidad: 3, precio_unitario: 6000, es_bonificacion: false, producto: { nombre: 'Fideos' } },
  { id: 23811, producto_id: 12, cantidad: 2, precio_unitario: 0, es_bonificacion: true, producto: { nombre: 'Regalo' } },
]

describe('lineasAcreditables', () => {
  it('deja afuera los regalos y descuenta lo acreditado en NCs vigentes, por línea', () => {
    const lineas = lineasAcreditables(items, [
      { anulada: false, items: [{ pedido_item_id: 23809, cantidad: 2 }] },
      { anulada: true, items: [{ pedido_item_id: 23807, cantidad: 1 }] }, // anulada: no cuenta
      { anulada: false, items: [{ pedido_item_id: null, cantidad: 5 }] },   // renglón recreado: no se atribuye
    ])
    expect(lineas.map(l => l.pedidoItemId)).toEqual(['23807', '23808', '23809'])
    const porId = Object.fromEntries(lineas.map(l => [l.pedidoItemId, l]))
    expect(porId['23807']).toMatchObject({ entregada: 1, yaAcreditada: 0, disponible: 1 })
    expect(porId['23809']).toMatchObject({ entregada: 3, yaAcreditada: 2, disponible: 1 })
    expect(porId['23808'].precioUnitario).toBe(5600)
  })
})

describe('totalNotaCreditoVenta', () => {
  const lineas = lineasAcreditables(items)

  it('suma cantidad × precio del pedido (NC#2 del ensayo de la 276: 11.100 + 5.600 = 16.700)', () => {
    expect(totalNotaCreditoVenta(lineas, { '23807': 1, '23808': 1 })).toBe(16700)
    expect(totalNotaCreditoVenta(lineas, { '23807': 1, '23809': 2 })).toBe(23100)
  })

  it('ignora cantidades en cero o negativas y redondea a centavos', () => {
    const l = lineasAcreditables([{ id: 1, producto_id: 1, cantidad: 3, precio_unitario: 0.105 }])
    expect(totalNotaCreditoVenta(l, { '1': 3 })).toBe(0.32)
    expect(totalNotaCreditoVenta(lineas, { '23807': 0, '23808': -1 })).toBe(0)
  })
})

describe('validarNotaCreditoVenta', () => {
  const lineas = lineasAcreditables(items, [{ anulada: false, items: [{ pedido_item_id: 23809, cantidad: 2 }] }])

  it('exige al menos una línea', () => {
    expect(validarNotaCreditoVenta(lineas, {})).toMatch(/al menos un producto/)
  })

  it('no deja pasar de lo entregado menos lo ya acreditado', () => {
    expect(validarNotaCreditoVenta(lineas, { '23809': 2 })).toMatch(/hasta 1 \(entregadas 3, ya acreditadas 2\)/)
    expect(validarNotaCreditoVenta(lineas, { '23809': 1 })).toBeNull()
  })

  it('rechaza fracciones', () => {
    expect(validarNotaCreditoVenta(lineas, { '23807': 0.5 })).toMatch(/Cantidad inválida/)
  })
})

describe('itemsNotaCreditoParaRPC', () => {
  it('manda sólo las líneas con cantidad, con ids numéricos', () => {
    const lineas = lineasAcreditables(items)
    expect(itemsNotaCreditoParaRPC(lineas, { '23807': 1, '23808': 0 })).toEqual([
      { pedido_item_id: 23807, cantidad: 1 },
    ])
  })
})

describe('resumen', () => {
  it('total de NCs vigentes ignora las anuladas', () => {
    expect(totalNotasCreditoVigentes([
      { total: 20100, anulada: true },
      { total: '16700', anulada: false },
    ])).toBe(16700)
  })

  it('etiqueta del motivo', () => {
    expect(motivoNCVentaLabel('producto_vencido')).toBe('Producto vencido')
    expect(motivoNCVentaLabel('raro')).toBe('raro')
  })
})
