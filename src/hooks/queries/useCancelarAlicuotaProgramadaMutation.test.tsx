/**
 * Cancelar una alícuota de II programada (mig 283, #914): que viaje por su RPC
 * con el id como número, que cada negativa de la base llegue con un mensaje
 * que se entienda, y que al terminar se invaliden el catálogo y las fichas.
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
      throw new Error(`cancelar no debería tocar la tabla ${tabla}`)
    },
  },
}))

import { useCancelarAlicuotaProgramadaMutation } from './useImpuestosInternosQuery'

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const invalidar = vi.spyOn(qc, 'invalidateQueries')
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  const { result } = renderHook(() => useCancelarAlicuotaProgramadaMutation(), { wrapper })
  return { result, invalidar }
}

describe('useCancelarAlicuotaProgramadaMutation', () => {
  beforeEach(() => {
    rpcCalls.length = 0
    rpcResult = { data: null, error: null }
  })

  it('llama a cancelar_alicuota_programada con el id como número e invalida catálogo y fichas', async () => {
    const { result, invalidar } = setup()

    await result.current.mutateAsync('7')

    expect(rpcCalls).toEqual([{ fn: 'cancelar_alicuota_programada', args: { p_alicuota_id: 7 } }])
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['impuestos_internos'] })
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['productos'] })
  })

  it.each([
    ['42501', 'Solo un administrador puede cancelar una alícuota programada.'],
    ['22023', 'Esa alícuota ya empezó a regir: no se puede cancelar. Para corregirla, cargá otra tasa.'],
    ['P0002', 'Esa alícuota ya no existe: puede que la haya cancelado otra persona.'],
  ])('traduce el error %s', async (code, mensaje) => {
    rpcResult = { data: null, error: { code, message: 'texto de la base' } }
    const { result, invalidar } = setup()

    await expect(result.current.mutateAsync('7')).rejects.toThrow(mensaje)
    expect(invalidar).not.toHaveBeenCalled()
  })
})
