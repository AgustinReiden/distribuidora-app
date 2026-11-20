/**
 * STK-13 (#1542): editar una compra y sincronizar sus lotes eran dos llamadas
 * (`actualizar_compra_items` y después `sincronizar_lotes_compra`). Si la
 * segunda fallaba con la compra ya bajada, el lote quedaba más grande que la
 * compra, y la pantalla sólo podía avisar y ofrecer reintentar (#1643).
 *
 * Desde la migración de la tarjeta C3 (#1603) la edición manda los vencimientos
 * en la misma llamada (`p_lotes`) y el server los sincroniza en su transacción:
 * o se guarda todo, o nada. Ya no hay una segunda llamada ni nada pendiente.
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

import { useActualizarCompraMutation } from './useComprasQuery'
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

describe('STK-13 · la edición de una compra guarda sus vencimientos en la misma llamada', () => {
  beforeEach(() => {
    rpc.mockReset()
  })

  it('manda la foto de los lotes con la edición y no llama a sincronizar_lotes_compra', async () => {
    rpc.mockResolvedValue({ data: { success: true, compra_id: '221', lotes_sincronizados: true, warning_clamp: [] }, error: null })
    const { result } = setup()
    const res = await result.current.mutateAsync(edicion)

    expect(rpc.mock.calls.map(c => c[0])).toEqual(['actualizar_compra_items'])
    expect((rpc.mock.calls[0][1] as { p_lotes: unknown }).p_lotes).toEqual(LOTES)
    expect(res.warningLotes).toBeNull()
  })

  it('sin vencimientos manda la lista vacía: es la foto, y borra los que había', async () => {
    rpc.mockResolvedValue({ data: { success: true, compra_id: '221', lotes_sincronizados: true, warning_clamp: [] }, error: null })
    const { result } = setup()
    await result.current.mutateAsync({ ...edicion, items: [{ ...edicion.items[0], vencimientos: [] }] })

    expect(rpc.mock.calls.map(c => c[0])).toEqual(['actualizar_compra_items'])
    expect((rpc.mock.calls[0][1] as { p_lotes: unknown }).p_lotes).toEqual([])
  })

  it('si los vencimientos no entran, la edición entera falla con el motivo del server', async () => {
    rpc.mockResolvedValue({
      data: { success: false, error: 'Los vencimientos de Agua 500 suman 9 u. y la compra 221 trae 8' },
      error: null,
    })
    const { result } = setup()

    await expect(result.current.mutateAsync(edicion)).rejects.toThrow('Los vencimientos de Agua 500 suman 9 u. y la compra 221 trae 8')
    expect(rpc.mock.calls.map(c => c[0])).toEqual(['actualizar_compra_items'])
  })

  it('lo que el server tuvo que recortar de los lotes llega como aviso', async () => {
    rpc.mockResolvedValue({
      data: { success: true, compra_id: '221', lotes_sincronizados: true, warning_clamp: [{ producto_id: 7, unidades: 3 }] },
      error: null,
    })
    const { result } = setup()
    const res = await result.current.mutateAsync(edicion)

    expect(res.warningLotes).toBe('Se recortaron 3 u. de vencimientos en 1 producto(s): los lotes no entraban en el stock disponible.')
  })
})
