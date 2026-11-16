/**
 * Las entregas masivas refrescan lo que lee la ruta (#1549, B5).
 *
 * Entregar en masa (con o sin cobro) cierra paradas de rutas armadas. Las dos mutaciones
 * sólo invalidaban `pedidos`: la pantalla del chofer (`recorrido-activo`), Recorridos y el
 * modal de armar ruta (`rutas-en-curso`) seguían con la foto de antes de la entrega.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: () => ({ insert: () => Promise.resolve({ error: null }) }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useEntregasMasivasMutation, useEntregaYPagoMasivosMutation } from './usePedidosQuery'

function setup<T>(usar: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const spy = vi.spyOn(qc, 'invalidateQueries')
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  const { result } = renderHook(usar, { wrapper })
  const claves = () => spy.mock.calls.map(c => JSON.stringify((c[0] as { queryKey: unknown }).queryKey))
  return { result, claves }
}

describe('las entregas masivas invalidan la ruta (#1549)', () => {
  beforeEach(() => {
    rpc.mockReset()
    rpc.mockResolvedValue({ data: 2, error: null })
  })

  it('entrega masiva: ruta activa del chofer, recorridos y rutas en curso', async () => {
    const { result, claves } = setup(() => useEntregasMasivasMutation())

    result.current.mutate({ pedidoIds: ['1', '2'], transportistaId: 't1', fecha: '2026-11-12' })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(claves()).toEqual(expect.arrayContaining([
      JSON.stringify(['recorrido-activo']),
      JSON.stringify(['recorridos']),
      JSON.stringify(['rutas-en-curso']),
    ]))
  })

  it('entrega con pago masiva: ruta activa del chofer y rutas en curso (y mantiene recorridos)', async () => {
    const { result, claves } = setup(() => useEntregaYPagoMasivosMutation())

    result.current.mutate({
      idsEntregar: ['1', '2'], idsCobrar: [],
      transportistaId: 't1', formaPago: 'efectivo', fecha: '2026-11-12',
    })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(claves()).toEqual(expect.arrayContaining([
      JSON.stringify(['recorrido-activo']),
      JSON.stringify(['recorridos']),
      JSON.stringify(['recorridos-hoja-ruta']),
      JSON.stringify(['rutas-en-curso']),
    ]))
  })

  it('con el resultado parcial (falló el cobro) también refresca lo que sí entró', async () => {
    rpc.mockResolvedValueOnce({ data: 2, error: null })
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'Timeout', details: '', hint: '', code: '57014' } })
    const { result, claves } = setup(() => useEntregaYPagoMasivosMutation())

    result.current.mutate({
      idsEntregar: ['1', '2'], idsCobrar: ['3'],
      transportistaId: 't1', formaPago: 'efectivo', fecha: '2026-11-12',
    })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data?.error?.paso).toBe('cobrar')
    expect(claves()).toContain(JSON.stringify(['recorrido-activo']))
  })
})
