import { describe, expect, it } from 'vitest'
import {
  mensajeCancelacion,
  renglonMovioStock,
  tieneRegaloConPromo,
  unidadesQueNoVuelvenAlStock,
} from './cancelacionFaltaStock'
import type { PedidoItemDB } from '../types'

const item = (over: Partial<PedidoItemDB>): PedidoItemDB => ({
  id: 'i',
  pedido_id: 'p',
  producto_id: '1',
  cantidad: 1,
  precio_unitario: 100,
  ...over,
}) as PedidoItemDB

describe('renglonMovioStock', () => {
  it('un renglón normal siempre movió stock', () => {
    expect(renglonMovioStock(item({}))).toBe(true)
  })

  it('un regalo sólo si la promo tiene regalo_mueve_stock', () => {
    expect(renglonMovioStock(item({ es_bonificacion: true, promocion: { regalo_mueve_stock: true } }))).toBe(true)
    expect(renglonMovioStock(item({ es_bonificacion: true, promocion: { regalo_mueve_stock: false } }))).toBe(false)
    expect(renglonMovioStock(item({ es_bonificacion: true, promocion: null }))).toBe(false)
    expect(renglonMovioStock(item({ es_bonificacion: true }))).toBe(false)
  })
})

describe('unidadesQueNoVuelvenAlStock', () => {
  it('agrupa por producto, como la merma de la mig 269', () => {
    const r = unidadesQueNoVuelvenAlStock([
      item({ id: 'a', producto_id: '7', cantidad: 3, producto: { nombre: 'Yerba' } as PedidoItemDB['producto'] }),
      item({ id: 'b', producto_id: '7', cantidad: 2, es_bonificacion: true, promocion: { regalo_mueve_stock: true } }),
      item({ id: 'c', producto_id: '9', cantidad: 4, producto: { nombre: 'Azúcar' } as PedidoItemDB['producto'] }),
    ])
    expect(r).toEqual([
      { productoId: '7', nombre: 'Yerba', cantidad: 5 },
      { productoId: '9', nombre: 'Azúcar', cantidad: 4 },
    ])
  })

  it('deja afuera el regalo que nunca tocó el stock y los renglones en cero', () => {
    const r = unidadesQueNoVuelvenAlStock([
      item({ producto_id: '1', cantidad: 2, es_bonificacion: true, promocion: { regalo_mueve_stock: false } }),
      item({ producto_id: '2', cantidad: 0 }),
      item({ producto_id: 3 as unknown as string, cantidad: 1 }),
    ])
    expect(r).toEqual([{ productoId: '3', nombre: 'Producto #3', cantidad: 1 }])
  })

  it('tolera un pedido sin items', () => {
    expect(unidadesQueNoVuelvenAlStock(undefined)).toEqual([])
    expect(unidadesQueNoVuelvenAlStock(null)).toEqual([])
  })
})

describe('tieneRegaloConPromo', () => {
  it('detecta un regalo de promoción', () => {
    expect(tieneRegaloConPromo([item({ es_bonificacion: true, promocion_id: '3' })])).toBe(true)
  })

  it('un renglón normal o un regalo sin promo no cuentan', () => {
    expect(tieneRegaloConPromo([item({}), item({ es_bonificacion: true })])).toBe(false)
    expect(tieneRegaloConPromo(undefined)).toBe(false)
  })
})

describe('mensajeCancelacion', () => {
  it('no dice "stock restaurado" cuando el motivo es falta de stock', () => {
    expect(mensajeCancelacion('falta_stock')).not.toMatch(/restaurad/i)
    expect(mensajeCancelacion('falta_stock')).toMatch(/merma/i)
  })

  it('el resto de los motivos mantiene el mensaje de siempre', () => {
    expect(mensajeCancelacion('cerrado')).toBe('Pedido cancelado y stock restaurado')
    expect(mensajeCancelacion(undefined)).toBe('Pedido cancelado y stock restaurado')
  })
})
