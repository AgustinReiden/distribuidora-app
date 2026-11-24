/**
 * gestion-B2 (tanda 6, #1603): `fetchProductoMedidas` leía todo `producto_medidas` de la sucursal sin
 * paginar ni ordenar: PostgREST corta en 1.000 filas sin avisar y a los demás productos les faltaban
 * las unidades por pallet. Ahora pagina con el orden de la clave de la tabla.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const TOTAL = 1200
const filas = Array.from({ length: TOTAL }, (_, i) => ({ producto_id: i + 1, medida_id: 3, unidades_por: 12 }))
const rangos: Array<[number, number]> = []
const ordenes: string[] = []

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => {
      const b: Record<string, unknown> = {}
      b.select = () => b
      b.eq = () => b
      b.order = (col: string) => { ordenes.push(col); return b }
      // Como PostgREST: nunca más de 1.000 filas por respuesta.
      b.range = (desde: number, hasta: number) => {
        rangos.push([desde, hasta])
        return Promise.resolve({ data: filas.slice(desde, Math.min(hasta + 1, desde + 1000)), error: null })
      }
      b.then = (resolve: (v: unknown) => unknown) =>
        Promise.resolve({ data: filas.slice(0, 1000), error: null }).then(resolve)
      return b
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useProductoMedidasQuery } from './useCargosCatalogoQuery'

describe('gestion-B2: las medidas de los productos se traen todas, no sólo las primeras 1.000', () => {
  beforeEach(() => { rangos.length = 0; ordenes.length = 0 })

  it('con 1.200 filas trae las 1.200, en dos páginas y con un orden único', async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    )
    const { result } = renderHook(() => useProductoMedidasQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(Object.keys(result.current.data ?? {})).toHaveLength(TOTAL)
    expect(result.current.data?.['1200']).toEqual({ '3': 12 })
    expect(rangos).toEqual([[0, 999], [1000, 1999]])
    expect(ordenes).toContain('producto_id')
    expect(ordenes).toContain('medida_id')
  })
})
