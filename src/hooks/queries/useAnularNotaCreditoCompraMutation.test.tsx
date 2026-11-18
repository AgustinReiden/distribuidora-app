/**
 * B18 de la ola 2 (#1603): anular una nota de crédito de compra (mig 523). La RPC
 * valida rol y sucursal; el hook manda la nota y el motivo, muestra el rechazo del
 * server tal cual y, al anular, invalida todo lo que dependía de la nota.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
let rpcResult: { data: unknown; error: { code?: string; message: string } | null } = { data: null, error: null }

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    from: (tabla: string) => {
      throw new Error(`anular la nota no debería tocar la tabla ${tabla}`)
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 3 }),
}))

import { useAnularNotaCreditoCompraMutation } from './useNotasCreditoQuery'

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const invalidar = vi.spyOn(qc, 'invalidateQueries')
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  const { result } = renderHook(() => useAnularNotaCreditoCompraMutation(), { wrapper })
  return { result, invalidar }
}

describe('useAnularNotaCreditoCompraMutation', () => {
  beforeEach(() => {
    rpcCalls.length = 0
    rpcResult = { data: { success: true, nota_credito_id: 9, tipo: 'devolucion', warnings: null }, error: null }
  })

  it('manda la nota y el motivo, e invalida notas, compras, productos, lotes y reportes', async () => {
    const { result, invalidar } = setup()

    const avisos = await result.current.mutateAsync({ notaId: '9', motivo: 'Era de otra compra' })

    expect(rpcCalls).toEqual([{ fn: 'anular_nota_credito_compra', args: { p_nota_id: 9, p_motivo: 'Era de otra compra' } }])
    expect(avisos).toEqual([])
    for (const queryKey of [['notas_credito', 3], ['compras', 3], ['productos'], ['lotes', 3], ['reporte-gerencial'], ['posicion-fiscal'], ['stock-red'], ['valuacion-inventario']]) {
      expect(invalidar).toHaveBeenCalledWith({ queryKey })
    }
  })

  it('devuelve los avisos de la base en castellano', async () => {
    rpcResult = {
      data: { success: true, warnings: [{ producto_id: 1, warning: 'costo_no_restaurado: sin otra compra válida de referencia' }] },
      error: null,
    }
    const { result } = setup()
    const avisos = await result.current.mutateAsync({ notaId: '9', motivo: 'x' })
    expect(avisos).toHaveLength(1)
    expect(avisos[0]).toMatch(/^El costo de reposición quedó como estaba/)
  })

  it('si la base la rechaza, el motivo llega tal cual y no invalida nada', async () => {
    const motivo = 'Esta nota es anterior al 10/11/2026 y no se puede anular desde acá: cuando se cargó no corrigió el costo promedio.'
    rpcResult = { data: { success: false, error: motivo }, error: null }
    const { result, invalidar } = setup()

    await expect(result.current.mutateAsync({ notaId: '9', motivo: 'x' })).rejects.toThrow(motivo)
    expect(invalidar).not.toHaveBeenCalled()
  })
})
