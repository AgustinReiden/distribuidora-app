/**
 * La sugerencia de combos del hook (#1194): la cuenta es `sugerirCombos`, con
 * la misma cotización que arma el pedido, y el hook le suma el mínimo de venta
 * (lo agregado no puede dejar el confirmar bloqueado).
 */
import { describe, it, expect, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import type { ComboVigente } from '../utils/combos'

const FERNET = '10'
const COCA = '11'

const combos: ComboVigente[] = [{
  id: '500',
  nombre: 'Fernet + Coca',
  precio: 11000,
  combinaEscalas: false,
  prioridad: 0,
  topeRestante: null,
  componentes: [
    { componente: 1, cantidad: 1, productos: [FERNET] },
    { componente: 2, cantidad: 1, productos: [COCA] },
  ],
}]

const { minimos } = vi.hoisted(() => ({ minimos: new Map<string, number>() }))

vi.mock('./queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => ({ data: combos, isLoading: false }),
}))
vi.mock('./queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('./queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('./queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: minimos, isLoading: false }),
}))

import { usePromocionPedido } from './usePromocionPedido'

const PRECIOS: Record<string, number> = { [FERNET]: 10000, [COCA]: 2500 }
const sugerencias = {
  precioDe: (p: string) => PRECIOS[p] ?? 0,
  puedeAgregar: () => true,
}
const items = [{ productoId: FERNET, cantidad: 1, precioUnitario: 10000 }]

describe('usePromocionPedido — sugerencia de combos', () => {
  it('con el Fernet sugiere la Coca y el ahorro del combo', () => {
    minimos.clear()
    const { result } = renderHook(() =>
      usePromocionPedido(items, undefined, undefined, undefined, undefined, { sugerencias }))
    expect(result.current.sugerenciasCombos).toEqual([
      { comboId: '500', nombre: 'Fernet + Coca', agregar: [{ productoId: COCA, cantidad: 1 }], ahorro: 1500 },
    ])
  })

  it('sin opciones de sugerencia no calcula nada', () => {
    minimos.clear()
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.sugerenciasCombos).toEqual([])
  })

  it('no sugiere lo que quedaría bajo el mínimo de venta', () => {
    minimos.clear()
    minimos.set(COCA, 6)
    const { result } = renderHook(() =>
      usePromocionPedido(items, undefined, undefined, undefined, undefined, { sugerencias }))
    expect(result.current.sugerenciasCombos).toEqual([])
  })

  it('un pedido sin combos (vale blanco) no sugiere', () => {
    minimos.clear()
    const { result } = renderHook(() =>
      usePromocionPedido(items, undefined, undefined, undefined, undefined, { habilitados: false, sugerencias }))
    expect(result.current.sugerenciasCombos).toEqual([])
  })
})
