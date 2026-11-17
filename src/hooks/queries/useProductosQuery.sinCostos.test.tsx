/**
 * 1599-b6: `conCostos` llamaba a la RPC `costos_productos()` (una vez cada 500
 * productos) aunque el rol no vea costos: la RPC le devuelve cero filas, así que
 * eran requests de más en cada carga del catálogo de un preventista, un
 * transportista o un depósito.
 *
 * Sin sesión cargada se sigue llamando (no se sabe el rol, y mandan los datos):
 * eso lo cubre `useProductosQuery.costos.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import AuthDataContext from '../../contexts/AuthDataContext'

const rpc = vi.fn()

const PRODUCTOS = [
  { id: 1, nombre: 'AGUA 2L', precio: 100 },
  { id: 2, nombre: 'BIZCOCHO', precio: 50 },
]

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => {
        const builder = { order: () => builder, range: () => Promise.resolve({ data: PRODUCTOS, error: null }) }
        return builder
      },
    }),
    rpc: (...args: unknown[]) => rpc(...args),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useProductosQuery } from './useProductosQuery'
import { conCostos } from './costosProductos'

function setup(rol: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const sesion = { perfil: { rol } } as never
  return renderHook(() => useProductosQuery(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <AuthDataContext.Provider value={sesion}>
        <QueryClientProvider client={qc}>{children}</QueryClientProvider>
      </AuthDataContext.Provider>
    ),
  })
}

describe('catálogo de productos · la RPC de costos sólo para quien los ve (1599-b6)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    rpc.mockResolvedValue({ data: [], error: null })
  })

  it.each(['preventista', 'transportista', 'deposito'])('un %s no la llama', async (rol) => {
    const { result } = setup(rol)
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(rpc).not.toHaveBeenCalled()
    expect(result.current.data).toEqual(PRODUCTOS)
  })

  it.each(['admin', 'encargado'])('un %s sí', async (rol) => {
    const { result } = setup(rol)
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(rpc).toHaveBeenCalledWith('costos_productos', { p_ids: [1, 2] })
  })

  it('conCostos con puedeVerCostos: false devuelve los productos tal cual y no llama', async () => {
    const productos = [{ id: 1 }, { id: 2 }]
    expect(await conCostos(productos, { puedeVerCostos: false })).toBe(productos)
    expect(rpc).not.toHaveBeenCalled()
  })
})
