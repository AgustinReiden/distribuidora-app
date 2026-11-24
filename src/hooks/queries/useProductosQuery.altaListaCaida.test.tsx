/**
 * gestion-B3 (tanda 6, #1603): el alta de un producto con la lista fuera de caché (la consulta
 * había fallado) sembraba una lista de UNA fila que quedaba «fresca» 10 minutos: el selector de
 * productos del modal de compra mostraba uno solo. Ahora no siembra nada: la lista se vuelve a leer.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => ({ ilike: () => ({ limit: () => Promise.resolve({ data: [], error: null }) }) }),
      insert: (rows: Array<Record<string, unknown>>) => ({
        select: () => ({ single: () => Promise.resolve({ data: { id: 9, ...rows[0] }, error: null }) }),
      }),
    }),
    rpc: () => Promise.resolve({ data: [], error: null }),
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearProductoMutation, productosKeys } from './useProductosQuery'

function montar() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, wrapper }
}

const producto = { nombre: 'Galletitas', codigo: 'G-1', precio: 100 } as never

describe('gestion-B3: el alta de un producto no siembra una lista de una fila', () => {
  it('con la lista fuera de caché no la deja con un solo producto', async () => {
    const { qc, wrapper } = montar()
    const { result } = renderHook(() => useCrearProductoMutation(), { wrapper })
    await act(async () => { await result.current.mutateAsync(producto) })
    expect(qc.getQueryData(productosKeys.lists(1))).toBeUndefined()
  })

  it('con la lista en caché suma el producto en su lugar', async () => {
    const { qc, wrapper } = montar()
    qc.setQueryData(productosKeys.lists(1), [{ id: 1, nombre: 'Zapallo' }, { id: 2, nombre: 'Arroz' }])
    const { result } = renderHook(() => useCrearProductoMutation(), { wrapper })
    await act(async () => { await result.current.mutateAsync(producto) })
    const lista = qc.getQueryData<Array<{ nombre: string }>>(productosKeys.lists(1)) ?? []
    expect(lista.map(p => p.nombre)).toEqual(['Arroz', 'Galletitas', 'Zapallo'])
  })
})
