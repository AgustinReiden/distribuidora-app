/**
 * El mínimo de venta del producto (mig 147) tiene que valer aunque el negocio
 * no tenga NINGUNA condición mayorista cargada. Antes el hook cortocircuitaba
 * con `pricingMap.size === 0` y devolvía el MOQ vacío, así que el mínimo por
 * sabor no bloqueaba nada en la app (el trigger de la DB sí lo rechazaba, pero
 * recién al confirmar y con un error opaco).
 */
import { describe, it, expect, vi } from 'vitest'
import { renderHook } from '@testing-library/react'

const pricingMap = new Map()
const promoMap = new Map()
const minimos = new Map([['p1', 3]])

vi.mock('./queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: pricingMap, isLoading: false }),
}))
vi.mock('./queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: promoMap, isLoading: false }),
}))
vi.mock('./queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: minimos, isLoading: false }),
}))

import { usePromocionPedido } from './usePromocionPedido'
import { obtenerMOQ } from '../utils/precioMayorista'

const item = (productoId: string, cantidad: number) => ({
  productoId,
  cantidad,
  precioUnitario: 100,
})

describe('usePromocionPedido — mínimo de venta del producto', () => {
  it('expone el mínimo en moqMap sin condiciones mayoristas', () => {
    const { result } = renderHook(() => usePromocionPedido([item('p1', 3)]))
    expect(result.current.moqMap.get('p1')).toBe(3)
  })

  it('marca violación cuando la cantidad queda por debajo del mínimo', () => {
    const { result } = renderHook(() => usePromocionPedido([item('p1', 2)]))
    expect(result.current.violacionesMOQ).toHaveLength(1)
    expect(result.current.violacionesMOQ[0]).toMatchObject({
      productoId: 'p1',
      cantidadActual: 2,
      cantidadMinima: 3,
    })
  })

  it('no marca violación al alcanzar el mínimo', () => {
    const { result } = renderHook(() => usePromocionPedido([item('p1', 3)]))
    expect(result.current.violacionesMOQ).toHaveLength(0)
  })

  it('no toca los productos sin mínimo', () => {
    const { result } = renderHook(() => usePromocionPedido([item('p2', 1)]))
    expect(result.current.moqMap.size).toBe(0)
    expect(result.current.violacionesMOQ).toHaveLength(0)
  })

  /**
   * `moqMap` se construye iterando los items DEL CARRITO, así que para un
   * producto que todavía no se agregó devuelve undefined. El listado del
   * catálogo lo consultaba igual, con dos consecuencias: el badge "Min: N" no
   * aparecía, y al tocar el producto se lo agregaba con cantidad 1 — en
   * violación de su propio mínimo, con el cartel ámbar y el confirmar en gris.
   * El preventista tenía que abrir el carrito y tipear la cantidad a mano, con
   * el cliente esperando, para un dato que el sistema ya conocía.
   *
   * Por eso el hook expone además `minimosProducto`, que es el catálogo entero.
   */
  it('moqMap NO cubre lo que todavía no está en el carrito', () => {
    // p1 tiene mínimo 3, pero el carrito está vacío.
    const { result } = renderHook(() => usePromocionPedido([]))
    expect(result.current.moqMap.get('p1')).toBeUndefined()
  })

  it('minimosProducto sí lo cubre, que es lo que mira el catálogo', () => {
    const { result } = renderHook(() => usePromocionPedido([]))
    expect(obtenerMOQ('p1', result.current.minimosProducto)).toBe(3)
    // Y un producto sin mínimo sigue siendo 1, no undefined.
    expect(obtenerMOQ('p2', result.current.minimosProducto)).toBe(1)
  })
})
