/**
 * Renombrar y eliminar un rubro van en tandas de TANDA_RUBRO (1596-b9, #1596): el hook repite la
 * RPC hasta que no falta nada y expone el avance para el modal.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useEliminarCategoriaMutation, useRenombrarCategoriaMutation } from './useCategoriasQuery'

function envolver() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('rubros en tandas', () => {
  beforeEach(() => { rpc.mockReset() })

  it('renombrar repite la RPC con p_lote hasta terminar y muestra el avance', async () => {
    rpc
      .mockResolvedValueOnce({ data: { success: true, id: 'r1', productos: 5000, faltan: 3000, terminado: false }, error: null })
      .mockResolvedValueOnce({ data: { success: true, id: 'r1', productos: 3000, faltan: 0, terminado: true }, error: null })
    const { result } = renderHook(() => useRenombrarCategoriaMutation(), { wrapper: envolver() })

    await act(async () => {
      await result.current.mutateAsync({ id: 'r1', nombreViejo: 'Bebidas', nombreNuevo: 'Gaseosas' })
    })

    expect(rpc).toHaveBeenCalledTimes(2)
    expect(rpc.mock.calls[0]).toEqual(['renombrar_rubro', {
      p_categoria_id: 'r1', p_nombre_actual: 'Bebidas', p_nombre_nuevo: 'Gaseosas', p_lote: 5000,
    }])
    expect(result.current.avance).toEqual({ hechos: 8000, faltan: 0 })
  })

  it('eliminar repite la RPC con p_lote hasta terminar', async () => {
    rpc
      .mockResolvedValueOnce({ data: { success: true, productos: 5000, faltan: 1, terminado: false }, error: null })
      .mockResolvedValueOnce({ data: { success: true, productos: 1, faltan: 0, terminado: true }, error: null })
    const { result } = renderHook(() => useEliminarCategoriaMutation(), { wrapper: envolver() })

    await act(async () => {
      await result.current.mutateAsync({ id: 'r1', nombre: 'Bebidas' })
    })

    expect(rpc).toHaveBeenCalledTimes(2)
    expect(rpc.mock.calls[1]).toEqual(['eliminar_rubro', { p_categoria_id: 'r1', p_nombre: 'Bebidas', p_lote: 5000 }])
    expect(result.current.avance).toEqual({ hechos: 5001, faltan: 0 })
  })

  it('si una tanda del medio falla, el aviso dice cuánto se hizo y cómo terminar', async () => {
    rpc
      .mockResolvedValueOnce({ data: { success: true, productos: 5000, faltan: 5000, terminado: false }, error: null })
      .mockResolvedValueOnce({ data: null, error: { code: 'P0001', message: 'Algo falló' } })
    const { result } = renderHook(() => useEliminarCategoriaMutation(), { wrapper: envolver() })

    let error: unknown
    await act(async () => {
      error = await result.current.mutateAsync({ id: 'r1', nombre: 'Bebidas' }).catch(e => e)
    })
    expect((error as Error).message).toBe('Algo falló. Ya se pasaron 5.000 productos y faltan 5.000: volvé a tocar «Eliminar» para terminar.')
  })
})
