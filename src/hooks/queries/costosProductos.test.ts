/**
 * #974 · `fetchCostosProductos` pide los costos de a tandas.
 *
 * La respuesta de una RPC también la corta el tope de filas de PostgREST
 * (1.000). Si se pidieran todos los ids juntos, con más de mil productos algún
 * producto quedaría sin costo, y la ficha guardada sin costo lo pisa con NULL.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const rpc = vi.fn()
vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

import { fetchCostosProductos } from './costosProductos'

describe('fetchCostosProductos', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('con más de 500 ids pide de a tandas de 500 y junta todo', async () => {
    rpc.mockImplementation(async (_fn: string, { p_ids }: { p_ids: number[] }) => ({
      data: p_ids.map(id => ({ id, costo_real: id, costo_promedio: null, costo_sin_iva: null, costo_con_iva: null })),
      error: null,
    }))
    const ids = Array.from({ length: 1200 }, (_, i) => String(i + 1))

    const mapa = await fetchCostosProductos(ids)

    expect(rpc).toHaveBeenCalledTimes(3)
    for (const [, args] of rpc.mock.calls) expect((args as { p_ids: number[] }).p_ids.length).toBeLessThanOrEqual(500)
    expect(mapa.size).toBe(1200)
    expect(mapa.get('1200')?.costo_real).toBe(1200)
  })

  it('no repite ids ni llama si no hay ninguno', async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    await fetchCostosProductos([])
    expect(rpc).not.toHaveBeenCalled()
    await fetchCostosProductos([3, '3', 3])
    expect(rpc).toHaveBeenCalledWith('costos_productos', { p_ids: [3] })
  })

  it('si una tanda falla, falla todo', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'boom' } })
    await expect(fetchCostosProductos([1])).rejects.toMatchObject({ message: 'boom' })
  })
})
