/**
 * Tests de los descuentos por cliente (general + por categoría).
 *
 * La regla que más cuesta ver leyendo el código: una categoría configurada
 * PREVALECE sobre el general aunque esté en 0%. Ese 0% es la forma de excluir
 * una categoría del descuento general, no un "sin dato".
 */
import { describe, it, expect } from 'vitest'
import {
  aplicarDescuentoClienteItems,
  esDescuentoDeCategoria,
  resolverDescuentoPctCliente,
  type ClienteConDescuentos,
  type ItemDescuentable,
  type ProductoConCategoria,
} from './descuentoCliente'

const PRODUCTOS: ProductoConCategoria[] = [
  { id: '1', categoria: 'GASEOSAS' },
  { id: '2', categoria: 'Aguas' },
  { id: '3', categoria: null },
]

const cliente10: ClienteConDescuentos = { descuento_porcentaje: 10 }

const clienteMixto: ClienteConDescuentos = {
  descuento_porcentaje: 10,
  descuentos_categoria: [
    { categoria: ' gaseosas ', descuento_porcentaje: 25 },
    { categoria: 'AGUAS', descuento_porcentaje: 0 },
  ],
}

describe('resolverDescuentoPctCliente', () => {
  it('sin cliente da 0', () => {
    expect(resolverDescuentoPctCliente(null, 'GASEOSAS')).toBe(0)
  })

  it('sólo general: aplica a cualquier categoría', () => {
    expect(resolverDescuentoPctCliente(cliente10, 'GASEOSAS')).toBe(10)
    expect(resolverDescuentoPctCliente(cliente10, null)).toBe(10)
  })

  it('la categoría prevalece sobre el general (match normalizado: trim + mayúsculas)', () => {
    expect(resolverDescuentoPctCliente(clienteMixto, 'GASEOSAS')).toBe(25)
    expect(resolverDescuentoPctCliente(clienteMixto, ' Gaseosas')).toBe(25)
  })

  it('una categoría en 0% excluye del general, no cae al general', () => {
    expect(resolverDescuentoPctCliente(clienteMixto, 'Aguas')).toBe(0)
  })

  it('una categoría sin regla usa el general', () => {
    expect(resolverDescuentoPctCliente(clienteMixto, 'VINOS')).toBe(10)
  })
})

describe('esDescuentoDeCategoria', () => {
  it('true sólo si hay una regla por categoría que matchea', () => {
    expect(esDescuentoDeCategoria(clienteMixto, 'GASEOSAS')).toBe(true)
    expect(esDescuentoDeCategoria(clienteMixto, 'Aguas')).toBe(true)
    expect(esDescuentoDeCategoria(clienteMixto, 'VINOS')).toBe(false)
    expect(esDescuentoDeCategoria(cliente10, 'GASEOSAS')).toBe(false)
    expect(esDescuentoDeCategoria(clienteMixto, null)).toBe(false)
  })
})

describe('aplicarDescuentoClienteItems', () => {
  const items: ItemDescuentable[] = [
    { productoId: '1', cantidad: 2, precioUnitario: 100 },
    { productoId: '2', cantidad: 1, precioUnitario: 50 },
  ]

  it('cliente sin descuentos: devuelve los items tal cual', () => {
    const r = aplicarDescuentoClienteItems(items, PRODUCTOS, null)
    expect(r.total).toBe(250)
    expect(r.ahorro).toBe(0)
    expect(r.hayDescuento).toBe(false)
    expect(r.items).toEqual(items)
  })

  it('descuento general: baja todos los precios', () => {
    const r = aplicarDescuentoClienteItems(items, PRODUCTOS, cliente10)
    expect(r.items[0].precioUnitario).toBe(90)
    expect(r.items[1].precioUnitario).toBe(45)
    expect(r.total).toBe(225)
    expect(r.ahorro).toBe(25)
    expect(r.hayDescuento).toBe(true)
  })

  it('la categoría prevalece y la que está en 0% queda sin descuento', () => {
    const r = aplicarDescuentoClienteItems(items, PRODUCTOS, clienteMixto)
    expect(r.items[0].precioUnitario).toBe(75) // 100 − 25% (GASEOSAS)
    expect(r.items[1].precioUnitario).toBe(50) // AGUAS en 0%
    expect(r.total).toBe(200)
    expect(r.ahorro).toBe(50)
  })

  it('un producto sin categoría cae al general', () => {
    const r = aplicarDescuentoClienteItems(
      [{ productoId: '3', cantidad: 1, precioUnitario: 100 }],
      PRODUCTOS,
      clienteMixto,
    )
    expect(r.items[0].precioUnitario).toBe(90)
  })

  it('bonificaciones y precioOverride quedan intactos y las bonificaciones no suman al total', () => {
    const r = aplicarDescuentoClienteItems(
      [
        { productoId: '1', cantidad: 1, precioUnitario: 100, precioOverride: true },
        { productoId: '1', cantidad: 2, precioUnitario: 0, esBonificacion: true },
        { productoId: '2', cantidad: 1, precioUnitario: 50 },
      ],
      PRODUCTOS,
      cliente10,
    )
    expect(r.items[0].precioUnitario).toBe(100) // precio tipeado a mano
    expect(r.items[1].precioUnitario).toBe(0) // regalo
    expect(r.items[2].precioUnitario).toBe(45)
    expect(r.total).toBe(145)
    expect(r.ahorro).toBe(5)
  })

  it('un precio en 0 sin ser bonificación tampoco se toca', () => {
    const r = aplicarDescuentoClienteItems(
      [{ productoId: '1', cantidad: 1, precioUnitario: 0 }],
      PRODUCTOS,
      cliente10,
    )
    expect(r.items[0].precioUnitario).toBe(0)
    expect(r.hayDescuento).toBe(false)
  })

  it('redondea el precio unitario a 2 decimales', () => {
    const r = aplicarDescuentoClienteItems(
      [{ productoId: '1', cantidad: 3, precioUnitario: 33.33 }],
      PRODUCTOS,
      { descuento_porcentaje: 15 },
    )
    // 33.33 − 15% = 28.3305 → 28.33
    expect(r.items[0].precioUnitario).toBe(28.33)
    expect(Math.round(r.total * 100) / 100).toBe(84.99)
  })

  it('acepta items con producto_id (snake_case) además de productoId', () => {
    const r = aplicarDescuentoClienteItems(
      [{ producto_id: 1, cantidad: 1, precioUnitario: 100 }],
      PRODUCTOS,
      clienteMixto,
    )
    expect(r.items[0].precioUnitario).toBe(75)
  })
})
