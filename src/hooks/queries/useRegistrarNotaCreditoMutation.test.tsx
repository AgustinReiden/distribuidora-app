/**
 * Nota de crédito por factura entera (#1079): la devolución con ítems sale de
 * los lotes de la compra que se acredita, así que al terminar se invalidan
 * también los lotes —la ficha del producto y la vista de vencimientos—, no
 * sólo compras, productos y notas.
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
      throw new Error(`registrar la nota no debería tocar la tabla ${tabla}`)
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 3 }),
}))

import { useRegistrarNotaCreditoMutation } from './useNotasCreditoQuery'
import type { NotaCreditoFormInput } from '../../types'

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const invalidar = vi.spyOn(qc, 'invalidateQueries')
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  const { result } = renderHook(() => useRegistrarNotaCreditoMutation(), { wrapper })
  return { result, invalidar }
}

const devolucion = {
  compraId: '12',
  numeroNota: 'NC-1',
  motivo: 'vencido',
  subtotal: 100,
  iva: 21,
  total: 121,
  usuarioId: null,
  items: [{ productoId: '5', cantidad: 10, costoUnitario: 10, subtotal: 100 }],
} as unknown as NotaCreditoFormInput

describe('useRegistrarNotaCreditoMutation', () => {
  beforeEach(() => {
    rpcCalls.length = 0
    rpcResult = { data: { success: true, nota_credito_id: 9 }, error: null }
  })

  it('al registrar una devolución invalida los lotes de la sucursal', async () => {
    const { result, invalidar } = setup()

    await result.current.mutateAsync(devolucion)

    expect(rpcCalls.map(c => c.fn)).toEqual(['registrar_nota_credito'])
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['lotes', 3] })
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['productos'] })
  })

  it('si la base la rechaza no invalida nada', async () => {
    rpcResult = { data: { success: false, error: 'No se puede acreditar: X' }, error: null }
    const { result, invalidar } = setup()

    await expect(result.current.mutateAsync(devolucion)).rejects.toThrow('No se puede acreditar: X')
    expect(invalidar).not.toHaveBeenCalled()
  })
})
