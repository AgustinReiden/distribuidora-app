/**
 * Gastos de la rendición (entrega 2): `fetchResumen` pide `obtener_gastos_rendiciones` junto con
 * el resumen y reparte cada gasto a su rendición por (transportista, día); `confirmarRendicion`
 * manda los cambios en `p_gastos_rendicion`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const rpc = vi.fn()
const notifyError = vi.fn()

vi.mock('./base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
  notifyError: (...a: unknown[]) => notifyError(...a),
}))

import { useRendiciones } from './useRendiciones'

const RESUMEN = (transportista_id: string, fecha: string) => ({
  fecha, transportista_id, transportista_nombre: 'Tito', total_efectivo: 50000, total_gastos: 8000, cantidad_gastos: 1,
})
const GASTO = { id: 7, rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-05', monto_total: 8000, km_tablero: null }

function respuestas(opts: { resumen?: unknown; gastos?: unknown; errorGastos?: unknown } = {}) {
  rpc.mockImplementation((fn: string) => {
    if (fn === 'obtener_resumen_rendiciones') {
      return Promise.resolve({ data: opts.resumen ?? [RESUMEN('tr-1', '2026-10-05'), RESUMEN('tr-2', '2026-10-05')], error: null })
    }
    if (fn === 'obtener_gastos_rendiciones') {
      return Promise.resolve({ data: opts.gastos ?? [GASTO], error: opts.errorGastos ?? null })
    }
    return Promise.resolve({ data: null, error: null })
  })
}

describe('useRendiciones — gastos de la rendición', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  it('pide los gastos con el mismo rango y transportista que el resumen', async () => {
    respuestas()
    const { result } = renderHook(() => useRendiciones())

    await act(async () => { await result.current.fetchResumen('2026-10-01', '2026-10-31', 'tr-1') })

    const args = { p_fecha_desde: '2026-10-01', p_fecha_hasta: '2026-10-31', p_transportista_id: 'tr-1' }
    expect(rpc).toHaveBeenCalledWith('obtener_resumen_rendiciones', args)
    expect(rpc).toHaveBeenCalledWith('obtener_gastos_rendiciones', args)
  })

  it('cada resumen recibe los gastos de su rendición, o []', async () => {
    respuestas()
    const { result } = renderHook(() => useRendiciones())

    let resumenes: Awaited<ReturnType<typeof result.current.fetchResumen>> = []
    await act(async () => { resumenes = await result.current.fetchResumen('2026-10-05', '2026-10-05') })

    expect(resumenes.find(r => r.transportista_id === 'tr-1')!.gastos).toEqual([GASTO])
    expect(resumenes.find(r => r.transportista_id === 'tr-2')!.gastos).toEqual([])
  })

  it('si falla obtener_gastos_rendiciones, la carga falla con su mensaje', async () => {
    respuestas({ errorGastos: { message: 'TypeError: Failed to fetch', code: '' } })
    const { result } = renderHook(() => useRendiciones())

    await act(async () => { await result.current.fetchResumen('2026-10-05', '2026-10-05') })

    expect(notifyError).toHaveBeenCalledWith(
      expect.stringContaining('Sin conexión: no se pudieron cargar los gastos de las rendiciones. Revisá la señal e intentá de nuevo.'),
    )
    expect(result.current.resumenes).toEqual([])
  })

  it('confirmarRendicion manda p_gastos_rendicion tal cual y no manda p_gastos', async () => {
    respuestas()
    const { result } = renderHook(() => useRendiciones())
    const cambios = { vistos: [7], guardar: [], quitar: [7] }

    await act(async () => { await result.current.confirmarRendicion('2026-10-05', 'tr-1', 'confirmada', 'ok', cambios) })

    const llamada = rpc.mock.calls.find(c => c[0] === 'confirmar_rendicion')!
    expect(llamada[1]).toEqual({
      p_fecha: '2026-10-05', p_transportista_id: 'tr-1', p_estado: 'confirmada',
      p_observaciones: 'ok', p_gastos_rendicion: cambios,
    })
    expect(llamada[1]).not.toHaveProperty('p_gastos')
  })
})
