/**
 * #1146: el detalle del reporte de mermas se pagina en el servidor.
 *
 * Fija lo que el front le manda al RPC (los parámetros nuevos sólo cuando
 * vienen, para no romper contra una base sin la migración en las llamadas
 * viejas) y cómo el Excel recorre el período completo de a páginas del tope.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const h = vi.hoisted(() => ({ rpc: vi.fn() }))
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: h.rpc } }))

import {
  fetchReporteMermas,
  fetchReporteMermasCompleto,
  mermasReporteKeys,
  LIMITE_DETALLE_MERMAS,
  MERMAS_PAGE_SIZE,
} from './useMermasReporteQuery'

function filas(desde: number, cantidad: number) {
  return Array.from({ length: cantidad }, (_, i) => ({ id: desde + i }))
}

function respuesta(over: Record<string, unknown> = {}) {
  return {
    meta: { sucursal_nombre: 'Tucumán' },
    totales: { costo: 100 },
    por_motivo: [],
    detalle: [],
    detalle_total: 0,
    detalle_filtrado: 0,
    detalle_limite: LIMITE_DETALLE_MERMAS,
    detalle_offset: 0,
    detalle_truncado: false,
    ...over,
  }
}

describe('fetchReporteMermas', () => {
  beforeEach(() => {
    h.rpc.mockReset()
    h.rpc.mockResolvedValue({ data: respuesta(), error: null })
  })

  it('sin opciones manda sólo los cuatro parámetros de siempre', async () => {
    await fetchReporteMermas(1, '2026-01-01', '2026-01-31', null)
    expect(h.rpc).toHaveBeenCalledWith('reporte_mermas', {
      p_desde: '2026-01-01',
      p_hasta: '2026-01-31',
      p_sucursal_id: 1,
      p_motivo: null,
    })
  })

  it('manda límite, offset y búsqueda cuando vienen', async () => {
    await fetchReporteMermas(null, '2026-01-01', '2026-01-31', 'rotura', {
      limite: 20,
      offset: 40,
      busqueda: '  coca ',
    })
    expect(h.rpc).toHaveBeenCalledWith('reporte_mermas', {
      p_desde: '2026-01-01',
      p_hasta: '2026-01-31',
      p_sucursal_id: null,
      p_motivo: 'rotura',
      p_limite_detalle: 20,
      p_offset: 40,
      p_busqueda: 'coca',
    })
  })

  it('una búsqueda vacía o en blanco no se manda', async () => {
    await fetchReporteMermas(1, '2026-01-01', '2026-01-31', null, { offset: 0, busqueda: '   ' })
    const params = h.rpc.mock.calls[0][1] as Record<string, unknown>
    expect(params).not.toHaveProperty('p_busqueda')
    expect(params).not.toHaveProperty('p_limite_detalle')
    expect(params.p_offset).toBe(0)
  })

  it('un error del RPC se propaga', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: 'boom', code: 'P0001' } })
    await expect(fetchReporteMermas(1, '2026-01-01', '2026-01-31')).rejects.toBeTruthy()
  })
})

describe('fetchReporteMermasCompleto', () => {
  beforeEach(() => {
    h.rpc.mockReset()
  })

  it('recorre el período de a páginas del tope y deduplica por id', async () => {
    // 4500 filas: offsets 0, 2000 y 4000. La segunda página repite el último id
    // de la primera (entró una merma nueva entre las dos llamadas).
    h.rpc.mockImplementation(async (_n: string, p: { p_offset: number }) => {
      const detalle =
        p.p_offset === 0 ? filas(1, 2000)
          : p.p_offset === 2000 ? [{ id: 2000 }, ...filas(2001, 1999)]
            : filas(4000, 501)
      return {
        data: respuesta({ detalle, detalle_total: 4500, detalle_filtrado: 4500, detalle_offset: p.p_offset, detalle_truncado: true }),
        error: null,
      }
    })
    const r = await fetchReporteMermasCompleto(1, '2026-01-01', '2026-12-31', null)
    expect(h.rpc.mock.calls.map((c) => (c[1] as { p_offset: number }).p_offset)).toEqual([0, 2000, 4000])
    for (const c of h.rpc.mock.calls) {
      expect((c[1] as Record<string, unknown>).p_limite_detalle).toBe(LIMITE_DETALLE_MERMAS)
      expect(c[1]).not.toHaveProperty('p_busqueda')
    }
    expect(r.detalle).toHaveLength(4500)
    expect(new Set(r.detalle.map((f) => f.id)).size).toBe(4500)
    expect(r.detalle_truncado).toBe(false)
    expect(r.totales).toEqual({ costo: 100 })
  })

  it('con un período que entra en una página hace una sola llamada', async () => {
    h.rpc.mockResolvedValue({ data: respuesta({ detalle: filas(1, 30), detalle_total: 30 }), error: null })
    const r = await fetchReporteMermasCompleto(1, '2026-01-01', '2026-01-31', 'rotura')
    expect(h.rpc).toHaveBeenCalledTimes(1)
    expect(h.rpc.mock.calls[0][1]).toMatchObject({ p_motivo: 'rotura', p_offset: 0 })
    expect(r.detalle).toHaveLength(30)
  })

  it('una página vacía corta el recorrido aunque falten filas (se borraron entre llamadas)', async () => {
    h.rpc.mockImplementation(async (_n: string, p: { p_offset: number }) => ({
      data: respuesta({ detalle: p.p_offset === 0 ? filas(1, 2000) : [], detalle_total: 2500 }),
      error: null,
    }))
    const r = await fetchReporteMermasCompleto(1, '2026-01-01', '2026-12-31')
    expect(h.rpc).toHaveBeenCalledTimes(2)
    expect(r.detalle).toHaveLength(2000)
  })
})

describe('mermasReporteKeys', () => {
  it('conserva el prefijo que invalidan las mutaciones', () => {
    // useAnularSalvedadMutation usa `mermasReporteKeys.all` y usePedidosQuery
    // lo escribe literal: si cambia el prefijo, dejan de invalidar el reporte.
    expect(mermasReporteKeys.all).toEqual(['reporte-mermas'])
    const key = mermasReporteKeys.range(1, '2026-01-01', '2026-01-31', null, 'coca', 3)
    expect(key[0]).toBe('reporte-mermas')
    expect(key).toEqual(['reporte-mermas', 1, '2026-01-01', '2026-01-31', null, 'coca', 3])
  })

  it('la página en pantalla es de 20', () => {
    expect(MERMAS_PAGE_SIZE).toBe(20)
  })
})
