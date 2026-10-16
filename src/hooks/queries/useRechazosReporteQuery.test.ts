/**
 * #1198: lo que el front le manda a `reporte_rechazos` y cómo trata el error.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const h = vi.hoisted(() => ({ rpc: vi.fn() }))
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: h.rpc } }))

import { fetchReporteRechazos, rechazosReporteKeys } from './useRechazosReporteQuery'

describe('fetchReporteRechazos', () => {
  beforeEach(() => {
    h.rpc.mockReset()
  })

  it('manda período y sucursal con los nombres del RPC', async () => {
    h.rpc.mockResolvedValue({ data: { totales: { rechazos_totales: 37 } }, error: null })
    const r = await fetchReporteRechazos(1, '2026-09-01', '2026-09-30')
    expect(h.rpc).toHaveBeenCalledWith('reporte_rechazos', {
      p_desde: '2026-09-01',
      p_hasta: '2026-09-30',
      p_sucursal_id: 1,
    })
    expect(r.totales.rechazos_totales).toBe(37)
  })

  it('null es la red y se manda tal cual', async () => {
    h.rpc.mockResolvedValue({ data: {}, error: null })
    await fetchReporteRechazos(null, '2026-09-01', '2026-09-30')
    expect(h.rpc).toHaveBeenCalledWith('reporte_rechazos', expect.objectContaining({ p_sucursal_id: null }))
  })

  it('el error del RPC sube con su mensaje', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: 'Acceso denegado: se requiere rol admin o encargado', code: 'P0001' } })
    await expect(fetchReporteRechazos(1, '2026-09-01', '2026-09-30')).rejects.toThrow(/Acceso denegado/)
  })

  it('la key separa sucursal y período', () => {
    expect(rechazosReporteKeys.range(null, 'a', 'b')).not.toEqual(rechazosReporteKeys.range(1, 'a', 'b'))
    expect(rechazosReporteKeys.range(1, 'a', 'b')[0]).toBe(rechazosReporteKeys.all[0])
  })
})
