/**
 * CAT-11 (#1596, decisión del dueño): desactivar un rubro sólo lo oculta. Antes
 * también le ponía `productos.categoria = NULL` a todos sus productos, sin
 * confirmar y sin vuelta atrás.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const escrituras: Array<{ tabla: string; valores: unknown }> = []

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => ({
      update: (valores: unknown) => {
        escrituras.push({ tabla, valores })
        const b = {
          eq: () => b,
          select: () => b,
          single: () => Promise.resolve({ data: { id: '5', nombre: 'GASEOSAS', activa: (valores as { activa: boolean }).activa }, error: null }),
          then: (f: (v: unknown) => unknown) => Promise.resolve({ error: null }).then(f),
        }
        return b
      },
    }),
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useToggleCategoriaActivaMutation } from './useCategoriasQuery'

const montar = () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  )
  return renderHook(() => useToggleCategoriaActivaMutation(), { wrapper })
}

describe('useToggleCategoriaActivaMutation (CAT-11)', () => {
  beforeEach(() => { escrituras.length = 0 })

  it('desactivar un rubro escribe sólo la fila del rubro: sus productos no se tocan', async () => {
    const { result } = montar()
    await act(async () => { await result.current.mutateAsync({ id: '5', activa: false, nombre: 'GASEOSAS' }) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(escrituras).toEqual([{ tabla: 'categorias', valores: { activa: false } }])
  })

  it('reactivarlo tampoco toca productos', async () => {
    const { result } = montar()
    await act(async () => { await result.current.mutateAsync({ id: '5', activa: true, nombre: 'GASEOSAS' }) })
    expect(escrituras).toEqual([{ tabla: 'categorias', valores: { activa: true } }])
  })
})
