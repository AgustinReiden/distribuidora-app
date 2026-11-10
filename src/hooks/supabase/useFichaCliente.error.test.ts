/**
 * FRT-3 y FRT-7 (#1517): la ficha del cliente.
 *
 * FRT-3: si la carga fallaba, el hook sólo avisaba con un toast y dejaba
 * `estadisticas = null` y `pedidosCliente = []`, y el modal los pintaba como
 * "0 pedidos · $0 comprado". Ahora el hook expone `error`.
 *
 * FRT-7: la query pesada trae los últimos 50 pedidos (`.limit(50)`) y nadie avisaba
 * que la pestaña Pedidos estaba cortada. El hook expone `pedidosTotales` (la cantidad
 * real, de la query liviana) para que el modal lo diga.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor, act } from '@testing-library/react'

const m = vi.hoisted(() => ({
  livianos: [] as Array<Record<string, unknown>>,
  pesada: [] as Array<Record<string, unknown>>,
  fallaPesada: false,
  notifyError: vi.fn(),
}))

vi.mock('./base', () => {
  const tabla = (nombre: string) => {
    const builder: Record<string, unknown> = {}
    const enc = () => builder
    builder.select = enc
    builder.eq = enc
    builder.order = enc
    // traerTodo (livianos y pagos) cierra con .range(); la query pesada con .limit().
    builder.range = () => Promise.resolve({ data: nombre === 'pedidos' ? m.livianos : [], error: null })
    builder.limit = () => Promise.resolve(
      m.fallaPesada
        ? { data: null, error: { message: 'canceling statement due to statement timeout', code: '57014' } }
        : { data: m.pesada, error: null },
    )
    return builder
  }
  return { supabase: { from: (n: string) => tabla(n) }, notifyError: m.notifyError }
})

import { useFichaCliente } from './useFichaCliente'

const ped = (over: Record<string, unknown>) => ({
  cliente_id: '440', estado: 'entregado', estado_pago: 'pagado', canal: 'app',
  fecha: '2026-10-01', created_at: '2026-10-01T15:00:00Z', tipo_factura: 'ZZ', total: 1000, ...over,
})

beforeEach(() => {
  vi.clearAllMocks()
  m.livianos = []
  m.pesada = []
  m.fallaPesada = false
})

describe('useFichaCliente — error de carga (FRT-3)', () => {
  it('si la query de pedidos falla, `error` es true y no hay estadísticas (no son cero: se desconocen)', async () => {
    m.fallaPesada = true
    const { result } = renderHook(() => useFichaCliente('440'))

    await waitFor(() => expect(result.current.error).toBe(true))
    expect(result.current.loading).toBe(false)
    expect(result.current.estadisticas).toBeNull()
    expect(result.current.pedidosCliente).toEqual([])
    expect(m.notifyError).toHaveBeenCalledWith(expect.stringContaining('Error al cargar datos del cliente'))
  })

  it('al reintentar con éxito, `error` vuelve a false y llegan las estadísticas', async () => {
    m.fallaPesada = true
    m.livianos = [ped({ id: '1' })]
    const { result } = renderHook(() => useFichaCliente('440'))
    await waitFor(() => expect(result.current.error).toBe(true))

    m.fallaPesada = false
    await act(async () => { await result.current.refetch() })

    expect(result.current.error).toBe(false)
    expect(result.current.estadisticas).not.toBeNull()
    expect(result.current.estadisticas!.totalCompras).toBe(1000)
  })

  it('con la carga bien, `error` es false (explícito, no undefined)', async () => {
    m.livianos = [ped({ id: '1' })]
    const { result } = renderHook(() => useFichaCliente('440'))
    await waitFor(() => expect(result.current.estadisticas).not.toBeNull())

    expect(result.current.error).toBe(false)
  })

  it('`loading` ya es true en el primer render si hay cliente (no se ve un instante de ceros)', async () => {
    const vistos: boolean[] = []
    const { result } = renderHook(() => {
      const ficha = useFichaCliente('440')
      vistos.push(ficha.loading)
      return ficha
    })

    expect(vistos[0]).toBe(true)
    await waitFor(() => expect(result.current.loading).toBe(false))
  })

  it('sin cliente no hay nada que cargar: `loading` es false', () => {
    const { result } = renderHook(() => useFichaCliente(null))

    expect(result.current.loading).toBe(false)
    expect(result.current.error).toBe(false)
  })
})

describe('useFichaCliente — pedidos totales (FRT-7)', () => {
  it('`pedidosTotales` es la cantidad real aunque la lista traiga sólo los últimos 50', async () => {
    m.livianos = Array.from({ length: 83 }, (_, i) => ped({ id: String(i + 1) }))
    m.pesada = Array.from({ length: 50 }, (_, i) => ped({ id: String(83 - i), items: [] }))
    const { result } = renderHook(() => useFichaCliente('440'))
    await waitFor(() => expect(result.current.estadisticas).not.toBeNull())

    expect(result.current.pedidosCliente).toHaveLength(50)
    expect(result.current.pedidosTotales).toBe(83)
  })

  it('cuenta todos los pedidos del cliente, también los canjes y los vales blancos', async () => {
    m.livianos = [
      ped({ id: '1' }),
      ped({ id: '2', canal: 'cambio', total: 0 }),
      ped({ id: '3', tipo_factura: 'VB' }),
      ped({ id: '4', estado: 'pendiente' }),
    ]
    m.pesada = m.livianos.map(p => ({ ...p, items: [] }))
    const { result } = renderHook(() => useFichaCliente('440'))
    await waitFor(() => expect(result.current.estadisticas).not.toBeNull())

    expect(result.current.pedidosTotales).toBe(4)
    expect(result.current.pedidosCliente).toHaveLength(4)
  })
})
