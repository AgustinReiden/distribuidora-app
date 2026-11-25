/**
 * `useRecorridos` (Fr-B3 resto y Fr-B13 de #1554, T14 de #1690).
 *
 *  - Las estadísticas contaban los recorridos `cancelado` que la lista ya oculta: dos pantallas, dos
 *    números distintos para el mismo rango.
 *  - `completarRecorrido` no tenía llamadores y escribía `recorridos.estado` por REST: se fue.
 */
import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'

type Fila = { id: string; transportista_id: string; fecha: string; estado: string; total_pedidos: number; pedidos_entregados: number }

const { tabla } = vi.hoisted(() => ({ tabla: { filas: [] as unknown[] } }))

vi.mock('./base', () => {
  // Una tabla en memoria: cada filtro de la cadena se aplica de verdad, así que el test mira lo
  // que devuelve la consulta y no cómo está escrita.
  const consulta = () => {
    let filas = (tabla.filas as Fila[]).slice()
    const cadena: Record<string, unknown> = {}
    cadena.select = () => cadena
    cadena.neq = (col: keyof Fila, v: unknown) => { filas = filas.filter(f => f[col] !== v); return cadena }
    cadena.gte = (col: keyof Fila, v: string) => { filas = filas.filter(f => f[col] >= v); return cadena }
    cadena.lte = (col: keyof Fila, v: string) => { filas = filas.filter(f => f[col] <= v); return cadena }
    cadena.then = (res: (v: unknown) => unknown, rej: (e: unknown) => unknown) =>
      Promise.resolve({ data: filas, error: null }).then(res, rej)
    return cadena
  }
  return { supabase: { from: () => consulta() } }
})

import { useRecorridos } from './useRecorridos'

const r = (id: string, transportista: string, estado: string, pedidos = 5): Fila => ({
  id, transportista_id: transportista, fecha: '2026-11-10', estado, total_pedidos: pedidos, pedidos_entregados: pedidos,
})

describe('useRecorridos.getEstadisticasRecorridos — no cuenta los cancelados (Fr-B3)', () => {
  it('un recorrido cancelado no suma al total ni a los pedidos del transportista', async () => {
    tabla.filas = [
      r('1', 't1', 'completado'),
      r('2', 't1', 'cancelado', 7),
      r('3', 't2', 'en_curso'),
    ]
    const { result } = renderHook(() => useRecorridos())

    let stats!: Awaited<ReturnType<typeof result.current.getEstadisticasRecorridos>>
    await act(async () => { stats = await result.current.getEstadisticasRecorridos('2026-11-01', '2026-11-30') })

    expect(stats.total).toBe(2)
    const recorridos = stats.porTransportista.map(t => t.recorridos).sort()
    expect(recorridos).toEqual([1, 1])
    const pedidos = stats.porTransportista.map(t => t.pedidosTotales).sort()
    expect(pedidos).toEqual([5, 5])
  })

  it('un transportista que sólo tiene cancelados no aparece', async () => {
    tabla.filas = [r('1', 't1', 'cancelado'), r('2', 't2', 'completado')]
    const { result } = renderHook(() => useRecorridos())

    let stats!: Awaited<ReturnType<typeof result.current.getEstadisticasRecorridos>>
    await act(async () => { stats = await result.current.getEstadisticasRecorridos('2026-11-01', '2026-11-30') })

    expect(stats.total).toBe(1)
    expect(stats.porTransportista).toHaveLength(1)
  })
})

describe('useRecorridos — completarRecorrido se fue (Fr-B13)', () => {
  it('el hook ya no ofrece una escritura de `recorridos` por REST', () => {
    const { result } = renderHook(() => useRecorridos())
    expect(Object.keys(result.current)).not.toContain('completarRecorrido')
  })
})
