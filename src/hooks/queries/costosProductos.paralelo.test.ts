/**
 * gestion-B10 (tanda 6, #1603): `fetchCostosProductos` llamaba `costos_productos` de a 500 ids y en
 * serie: con 30.000 productos, 60 viajes seguidos en cada carga fría del catálogo. Ahora las tandas
 * van de a varias a la vez (con tope), y el resultado es el mismo.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const rpc = vi.fn()
vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

import { fetchCostosProductos } from './costosProductos'

describe('fetchCostosProductos · las tandas van en paralelo', () => {
  beforeEach(() => vi.clearAllMocks())

  it('con 6.000 ids hace 12 llamadas, nunca más de 4 a la vez ni una sola a la vez, y junta todo', async () => {
    let enVuelo = 0
    let maximo = 0
    rpc.mockImplementation(async (_fn: string, { p_ids }: { p_ids: number[] }) => {
      enVuelo++
      maximo = Math.max(maximo, enVuelo)
      await new Promise(r => setTimeout(r, 5))
      enVuelo--
      return {
        data: p_ids.map(id => ({ id, costo_real: id, costo_promedio: null, costo_sin_iva: null, costo_con_iva: null })),
        error: null,
      }
    })
    const ids = Array.from({ length: 6000 }, (_, i) => String(i + 1))

    const mapa = await fetchCostosProductos(ids)

    expect(rpc).toHaveBeenCalledTimes(12)
    expect(maximo).toBeGreaterThan(1)
    expect(maximo).toBeLessThanOrEqual(4)
    expect(mapa.size).toBe(6000)
    expect(mapa.get('6000')?.costo_real).toBe(6000)
  })

  it('si una de las tandas falla, falla todo', async () => {
    rpc.mockImplementation(async (_fn: string, { p_ids }: { p_ids: number[] }) =>
      p_ids.includes(1200)
        ? { data: null, error: { message: 'boom' } }
        : { data: [], error: null })
    const ids = Array.from({ length: 2000 }, (_, i) => String(i + 1))
    await expect(fetchCostosProductos(ids)).rejects.toMatchObject({ message: 'boom' })
  })
})
