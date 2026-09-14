/**
 * `usePromoUnidadesEntregadasQuery` sumaba `pedido_items.cantidad` cruda.
 * En una promo Fracción esa cantidad está en subunidades sueltas (botellas),
 * no en unidades de venta (fardos): una promo "6+2" que entregó 392 botellas
 * mostraba "392 unidades regaladas" en vez de los 65 fardos reales — el mismo
 * bug que ya se había arreglado para la boleta y el reporte (issues
 * #534/#552), pero no acá.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Fila {
  promocion_id: number
  cantidad: number
  unidades_por_bloque_al_crear: number | null
  promocion: { unidades_por_bloque: number | null; regalo_mueve_stock: boolean | null } | null
}

let filas: Fila[] = []

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => {
      const builder = {
        select: () => builder,
        eq: () => builder,
        not: () => builder,
        neq: () => builder,
        order: () => builder,
        range: async () => ({ data: filas, error: null }),
      }
      return builder
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { usePromoUnidadesEntregadasQuery } from './usePromocionesQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderHook(() => usePromoUnidadesEntregadasQuery(), { wrapper: makeWrapper(qc) })
}

describe('usePromoUnidadesEntregadasQuery', () => {
  beforeEach(() => {
    filas = []
  })

  it('divide por el factor congelado: 392 botellas con factor 6 son 65 fardos, no 392 unidades', async () => {
    filas = [{
      promocion_id: 5,
      cantidad: 392,
      unidades_por_bloque_al_crear: 6,
      promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
    }]

    const { result } = setup()
    await waitFor(() => expect(result.current.data).toBeDefined())

    const unidades = result.current.data!.get('5') ?? 0
    expect(Math.round(unidades)).toBe(65)
  })

  it('una promo no fraccionada (factor 1) sigue sumando cantidad cruda', async () => {
    filas = [
      { promocion_id: 8, cantidad: 10, unidades_por_bloque_al_crear: 1, promocion: null },
      { promocion_id: 8, cantidad: 4, unidades_por_bloque_al_crear: 1, promocion: null },
    ]

    const { result } = setup()
    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(result.current.data!.get('8')).toBe(14)
  })

  it('items de la misma promo con factores distintos (cambio histórico) dividen cada uno por el propio', async () => {
    filas = [
      { promocion_id: 9, cantidad: 392, unidades_por_bloque_al_crear: 6, promocion: { unidades_por_bloque: 12, regalo_mueve_stock: false } },
      { promocion_id: 9, cantidad: 120, unidades_por_bloque_al_crear: 12, promocion: { unidades_por_bloque: 12, regalo_mueve_stock: false } },
    ]

    const { result } = setup()
    await waitFor(() => expect(result.current.data).toBeDefined())

    // 392/6 + 120/12 = 65,33 + 10 = 75,33
    expect(result.current.data!.get('9')).toBeCloseTo(75.33, 1)
  })
})
