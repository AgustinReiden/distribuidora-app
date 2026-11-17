/**
 * STK-13 (#1542): editar una compra y sincronizar sus lotes son dos llamadas
 * (`actualizar_compra_items` y después `sincronizar_lotes_compra`). Si la
 * segunda falla con la compra ya bajada, el lote queda más grande que la compra
 * (el stock cierra, la atribución a vencimientos no).
 *
 * Sin una RPC que haga las dos cosas juntas, lo que se puede hacer desde el
 * front es no dejarlo en silencio: el aviso dice qué pasó y la edición devuelve
 * lo que falta sincronizar, para que la pantalla ofrezca reintentarlo.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: vi.fn(),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'admin-1' } } }) },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useActualizarCompraMutation, reintentarSincronizarLotes } from './useComprasQuery'
import type { ActualizarCompraItemsInput } from './useComprasQuery'

const edicion: ActualizarCompraItemsInput = {
  compraId: '221',
  usuarioId: 'user-1',
  renglonesVistos: [9001],
  subtotal: 8_000,
  iva: 1680,
  total: 9_680,
  items: [{ productoId: '7', cantidad: 8, costoUnitario: 1000, subtotal: 8_000, vencimientos: [{ fecha: '2027-03-01', cantidad: 8 }] }],
  cargos: [],
  iiDeclarado: {},
}

const LOTES = [{ producto_id: 7, fecha_vencimiento: '2027-03-01', cantidad: 8 }]

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, ...renderHook(() => useActualizarCompraMutation(), { wrapper }) }
}

/** La compra se edita bien; los lotes responden según el caso. */
function rpcSegun(lotes: () => unknown) {
  rpc.mockImplementation((nombre: string) => {
    if (nombre === 'actualizar_compra_items') return Promise.resolve({ data: { success: true, compra_id: '221' }, error: null })
    if (nombre === 'sincronizar_lotes_compra') return Promise.resolve(lotes())
    return Promise.resolve({ data: null, error: null })
  })
}

describe('STK-13 · editar la compra y sincronizar los lotes', () => {
  beforeEach(() => {
    rpc.mockReset()
  })

  it('si los lotes se sincronizan, no queda nada pendiente', async () => {
    rpcSegun(() => ({ data: { warning_clamp: [] }, error: null }))
    const { result } = setup()
    const res = await result.current.mutateAsync(edicion)
    expect(res.warningLotes).toBeNull()
    expect(res.lotesPendientes).toBeNull()
  })

  it('si fallan, la compra queda editada y el resultado dice qué falta y cómo reintentarlo', async () => {
    rpcSegun(() => ({ data: null, error: { message: 'TypeError: Failed to fetch', code: '' } }))
    const { result } = setup()
    const res = await result.current.mutateAsync(edicion)

    expect(res.compraId).toBe('221')
    // No dice «se registró»: la compra se editó, y el motivo del aviso es otro.
    expect(res.warningLotes).toMatch(/La compra se editó/)
    expect(res.warningLotes).toMatch(/vencimientos/)
    expect(res.warningLotes).toMatch(/más unidades que la compra/)
    expect(res.lotesPendientes).toEqual({ compraId: '221', lotes: LOTES, reintentable: true })
  })

  it('si el server rechaza por regla (más de 8 días), muestra el motivo y no aconseja reintentar', async () => {
    rpcSegun(() => ({ data: null, error: { code: 'P0001', message: 'La compra tiene más de 8 días: no se pueden sincronizar sus lotes.' } }))
    const { result } = setup()
    const res = await result.current.mutateAsync(edicion)

    expect(res.warningLotes).toMatch(/más de 8 días/)
    expect(res.warningLotes).toMatch(/ficha del producto/)
    expect(res.warningLotes).not.toMatch(/Reintentá/)
    expect(res.lotesPendientes).toMatchObject({ compraId: '221', reintentable: false })
  })

  it('el reintento manda la misma foto de lotes y deja la lista de lotes al día', async () => {
    rpcSegun(() => ({ data: { warning_clamp: [] }, error: null }))
    const qc = new QueryClient()
    qc.setQueryData(['lotes', 1, 'reporte', 14], [])

    const aviso = await reintentarSincronizarLotes(qc, 1, { compraId: '221', lotes: LOTES, reintentable: true })

    expect(aviso).toBeNull()
    expect(rpc).toHaveBeenCalledWith('sincronizar_lotes_compra', { p_compra_id: '221', p_lotes: LOTES })
    expect(qc.getQueryState(['lotes', 1, 'reporte', 14])?.isInvalidated).toBe(true)
  })

  it('si el reintento vuelve a fallar, lanza el error para que la pantalla lo muestre y deje reintentar', async () => {
    rpcSegun(() => ({ data: null, error: { message: 'TypeError: Failed to fetch', code: '' } }))
    const qc = new QueryClient()
    await expect(reintentarSincronizarLotes(qc, 1, { compraId: '221', lotes: LOTES, reintentable: true })).rejects.toThrow()
  })
})
