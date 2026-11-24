/**
 * Tanda 6 (#1603), gestion-B7 y gestion-B8: lo que cada mutación invalida.
 *
 * B7:  aplicar un control de stock mueve los lotes (trigger de stock): Vencimientos y la ficha
 *      mostraban el lote de antes.
 * B8:  registrar una nota de crédito de compra cambia «Compras del período» (neta de notas): el
 *      gerencial y la posición fiscal quedaban con la foto vieja.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 3 }),
}))

import { useAplicarControlStockMutation } from './useControlStockQuery'
import { useRegistrarNotaCreditoMutation } from './useNotasCreditoQuery'

function montar<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const invalidar = vi.spyOn(qc, 'invalidateQueries')
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { invalidar, ...renderHook(hook, { wrapper }) }
}

describe('gestion-B7: aplicar un control de stock invalida los lotes', () => {
  beforeEach(() => rpc.mockReset())

  it('invalida los lotes de la sucursal', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { result, invalidar } = montar(useAplicarControlStockMutation)
    await result.current.mutateAsync({ planillaId: 'P-1', ajustes: [] } as never)
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['lotes', 3] })
  })
})

describe('gestion-B8: registrar una nota de crédito de compra invalida los reportes que la restan', () => {
  beforeEach(() => rpc.mockReset())

  it('invalida el gerencial y la posición fiscal', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { result, invalidar } = montar(useRegistrarNotaCreditoMutation)
    await result.current.mutateAsync({
      compraId: '10', numeroNota: null, motivo: 'x', subtotal: 100, iva: 21, total: 121, items: [],
    } as never)
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['reporte-gerencial'] })
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['posicion-fiscal'] })
  })
})
