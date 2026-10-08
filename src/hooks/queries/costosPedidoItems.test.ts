/**
 * #1003 · `fetchCostosPedidoItems` pide el costo de la venta de a tandas.
 *
 * La respuesta de una RPC también la corta el tope de filas de PostgREST
 * (1.000): con todos los ids juntos, un mes de ventas dejaría ítems sin costo y
 * el export a BI los mostraría con margen inflado.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const rpc = vi.fn()
vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

import { fetchCostosPedidoItems } from './costosPedidoItems'

describe('fetchCostosPedidoItems', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('con más de 500 ids pide de a tandas de 500 y junta todo', async () => {
    rpc.mockImplementation(async (_fn: string, { p_ids }: { p_ids: number[] }) => ({
      data: p_ids.map(id => ({ id, costo_unitario_al_crear: id * 2 })),
      error: null,
    }))
    const ids = Array.from({ length: 1200 }, (_, i) => String(i + 1))

    const mapa = await fetchCostosPedidoItems(ids)

    expect(rpc).toHaveBeenCalledTimes(3)
    for (const [fn, args] of rpc.mock.calls) {
      expect(fn).toBe('costos_pedido_items')
      expect((args as { p_ids: number[] }).p_ids.length).toBeLessThanOrEqual(500)
    }
    expect(mapa.size).toBe(1200)
    expect(mapa.get('1200')).toBe(2400)
  })

  it('no repite ids ni llama si no hay ninguno', async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    await fetchCostosPedidoItems([])
    expect(rpc).not.toHaveBeenCalled()
    await fetchCostosPedidoItems([3, '3', 3])
    expect(rpc).toHaveBeenCalledWith('costos_pedido_items', { p_ids: [3] })
  })

  it('si una tanda falla, falla todo', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'boom' } })
    await expect(fetchCostosPedidoItems([1])).rejects.toMatchObject({ message: 'boom' })
  })

  it('un rol sin acceso recibe cero filas: mapa vacío, sin error', async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    const mapa = await fetchCostosPedidoItems([1, 2])
    expect(mapa.size).toBe(0)
  })

  it('conserva el costo null de un ítem sin snapshot', async () => {
    rpc.mockResolvedValue({ data: [{ id: 5, costo_unitario_al_crear: null }], error: null })
    const mapa = await fetchCostosPedidoItems([5])
    expect(mapa.has('5')).toBe(true)
    expect(mapa.get('5')).toBeNull()
  })
})
