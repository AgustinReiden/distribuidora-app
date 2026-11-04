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
const GASTO = { id: 7, updated_at: '2026-10-28T13:05:22.123456+00:00', rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-05', monto_total: 8000, km_tablero: null }

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

describe('useRendiciones — pagos al personal', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  it('mapea total_pagos_personal a número, y 0 si no viene', async () => {
    respuestas({
      resumen: [
        { ...RESUMEN('tr-1', '2026-10-05'), total_pagos_personal: '100000.50' },
        RESUMEN('tr-2', '2026-10-05'),
      ],
    })
    const { result } = renderHook(() => useRendiciones())

    let resumenes: Awaited<ReturnType<typeof result.current.fetchResumen>> = []
    await act(async () => { resumenes = await result.current.fetchResumen('2026-10-05', '2026-10-05') })

    expect(resumenes.find(r => r.transportista_id === 'tr-1')!.total_pagos_personal).toBe(100000.5)
    expect(resumenes.find(r => r.transportista_id === 'tr-2')!.total_pagos_personal).toBe(0)
  })
})

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
    const cambios = { vistos: [{ id: 7, updated_at: '2026-10-28T13:05:22.123456+00:00' }], guardar: [], quitar: [7], pagos_personal_visto: 100000, faltantes_visto: 0 }

    await act(async () => { await result.current.confirmarRendicion('2026-10-05', 'tr-1', 'confirmada', 'ok', cambios) })

    const llamada = rpc.mock.calls.find(c => c[0] === 'confirmar_rendicion')!
    expect(llamada[1]).toEqual({
      p_fecha: '2026-10-05', p_transportista_id: 'tr-1', p_estado: 'confirmada',
      p_observaciones: 'ok', p_gastos_rendicion: cambios,
    })
    expect(llamada[1]).not.toHaveProperty('p_gastos')
  })
})

const FALTANTE = {
  id: 3, transportista_id: 'tr-1', fecha: '2026-10-05', causal: 'empleado', monto: 3000, observacion: null,
  empleado: { id: 9, nombre: 'Marcos Delgado' }, gasto_id: null, rubro_nombre: null,
  creado_por_nombre: 'Agustín', created_at: '2026-11-03T12:00:00Z',
}

describe('useRendiciones — faltantes de la rendición', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  const conFaltantes = (faltantes: unknown, errorFaltantes: unknown = null, resumen?: unknown) =>
    rpc.mockImplementation((fn: string) => {
      if (fn === 'obtener_resumen_rendiciones') {
        return Promise.resolve({ data: resumen ?? [{ ...RESUMEN('tr-1', '2026-10-05'), total_faltantes_empleados: '3000.50' }, RESUMEN('tr-2', '2026-10-05')], error: null })
      }
      if (fn === 'obtener_gastos_rendiciones') return Promise.resolve({ data: [], error: null })
      if (fn === 'obtener_faltantes_rendiciones') return Promise.resolve({ data: faltantes, error: errorFaltantes })
      return Promise.resolve({ data: null, error: null })
    })

  it('trae los faltantes y los cuelga de su rendición', async () => {
    conFaltantes([FALTANTE])
    const { result } = renderHook(() => useRendiciones())

    let resumenes: Awaited<ReturnType<typeof result.current.fetchResumen>> = []
    await act(async () => { resumenes = await result.current.fetchResumen('2026-10-01', '2026-10-31', 'tr-1') })

    const args = { p_fecha_desde: '2026-10-01', p_fecha_hasta: '2026-10-31', p_transportista_id: 'tr-1' }
    expect(rpc).toHaveBeenCalledWith('obtener_faltantes_rendiciones', args)
    expect(resumenes.find(r => r.transportista_id === 'tr-1')!.faltantes).toEqual([FALTANTE])
    expect(resumenes.find(r => r.transportista_id === 'tr-2')!.faltantes).toEqual([])
  })

  it('mapea total_faltantes_empleados a número, y sin la columna es 0', async () => {
    conFaltantes([])
    const { result } = renderHook(() => useRendiciones())

    let resumenes: Awaited<ReturnType<typeof result.current.fetchResumen>> = []
    await act(async () => { resumenes = await result.current.fetchResumen('2026-10-05', '2026-10-05') })

    expect(resumenes.find(r => r.transportista_id === 'tr-1')!.total_faltantes_empleados).toBe(3000.5)
    expect(resumenes.find(r => r.transportista_id === 'tr-2')!.total_faltantes_empleados).toBe(0)
  })

  it('un error de faltantes notifica con su mensaje y no deja resúmenes a medias', async () => {
    conFaltantes(null, { message: 'TypeError: Failed to fetch', code: '' })
    const { result } = renderHook(() => useRendiciones())

    await act(async () => { await result.current.fetchResumen('2026-10-05', '2026-10-05') })

    expect(notifyError).toHaveBeenCalledWith(
      expect.stringContaining('Sin conexión: no se pudieron cargar las diferencias de las rendiciones. Revisá la señal e intentá de nuevo.'),
    )
    expect(result.current.resumenes).toEqual([])
  })

  it('resolver manda la resolución entera', async () => {
    conFaltantes([])
    const { result } = renderHook(() => useRendiciones())
    const resolucion = {
      lineas: [{ causal: 'empleado' as const, monto: 3000, empleado_id: 9, observacion: null }],
      vistos: [{ id: 7, updated_at: '2026-10-28T13:05:22.123456+00:00' }],
      pagos_personal_visto: 100000,
    }

    await act(async () => { await result.current.resolverRendicion('2026-10-05', 'tr-1', 'Se le cobró', resolucion) })

    const llamada = rpc.mock.calls.find(c => c[0] === 'resolver_rendicion')!
    expect(llamada[1]).toEqual({
      p_fecha: '2026-10-05', p_transportista_id: 'tr-1', p_observaciones: 'Se le cobró', p_resolucion: resolucion,
    })
  })

  it.each([
    ['resolver', (h: ReturnType<typeof useRendiciones>) =>
      h.resolverRendicion('2026-10-05', 'tr-1', 'ok', { lineas: [], vistos: [], pagos_personal_visto: 0 }), 'resolver_rendicion'],
    ['deshacer', (h: ReturnType<typeof useRendiciones>) =>
      h.deshacerResolucion('2026-10-05', 'tr-1', 'me equivoqué'), 'deshacer_resolucion_rendicion'],
  ])('si %s falla, igual recarga el resumen y los faltantes y lanza el error', async (_nombre, llamar, rpcFalla) => {
    conFaltantes([])
    const { result } = renderHook(() => useRendiciones())
    await act(async () => { await result.current.fetchResumen('2026-10-01', '2026-10-31') })
    rpc.mockClear()
    rpc.mockImplementation((fn: string) => {
      if (fn === rpcFalla) return Promise.resolve({ data: null, error: { message: 'Se cortó la respuesta', code: 'P0001' } })
      return Promise.resolve({ data: [], error: null })
    })

    let lanzado: Error | undefined
    await act(async () => { await llamar(result.current).catch((e: Error) => { lanzado = e }) })

    expect(lanzado?.message).toBe('Se cortó la respuesta')
    const args = { p_fecha_desde: '2026-10-01', p_fecha_hasta: '2026-10-31', p_transportista_id: null }
    expect(rpc).toHaveBeenCalledWith('obtener_resumen_rendiciones', args)
    expect(rpc).toHaveBeenCalledWith('obtener_faltantes_rendiciones', args)
  })

  it('si resolver falla sin haber cargado nunca la lista, no recarga nada', async () => {
    rpc.mockImplementation((fn: string) =>
      Promise.resolve(fn === 'resolver_rendicion'
        ? { data: null, error: { message: 'No', code: 'P0001' } }
        : { data: [], error: null }))
    const { result } = renderHook(() => useRendiciones())

    await act(async () => {
      await result.current.resolverRendicion('2026-10-05', 'tr-1', 'ok', { lineas: [], vistos: [], pagos_personal_visto: 0 })
        .catch(() => undefined)
    })

    expect(rpc.mock.calls.map(c => c[0])).toEqual(['resolver_rendicion'])
  })

  it('deshacer manda el motivo y refresca el último rango', async () => {
    conFaltantes([])
    const { result } = renderHook(() => useRendiciones())
    await act(async () => { await result.current.fetchResumen('2026-10-01', '2026-10-31') })
    rpc.mockClear()

    await act(async () => { await result.current.deshacerResolucion('2026-10-05', 'tr-1', 'Me equivoqué de empleado') })

    const llamada = rpc.mock.calls.find(c => c[0] === 'deshacer_resolucion_rendicion')!
    expect(llamada[1]).toEqual({ p_fecha: '2026-10-05', p_transportista_id: 'tr-1', p_motivo: 'Me equivoqué de empleado' })
    expect(rpc).toHaveBeenCalledWith('obtener_resumen_rendiciones', {
      p_fecha_desde: '2026-10-01', p_fecha_hasta: '2026-10-31', p_transportista_id: null,
    })
  })
})
