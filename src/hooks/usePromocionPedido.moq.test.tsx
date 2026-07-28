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
})
