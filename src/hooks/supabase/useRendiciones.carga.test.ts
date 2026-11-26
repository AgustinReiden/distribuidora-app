/**
 * `useRendiciones` — carga de la lista (Fr-B4 de #1554, T14 de #1690).
 *
 *  1. Un error de carga se veía como lista vacía («No hay rendiciones en el rango»): ahora lo dice
 *     `error`, y la pantalla muestra «Reintentar».
 *  2. Sin guarda de orden entre pedidos, una respuesta vieja pisaba una nueva (cambiar el rango dos
 *     veces seguidas dejaba en pantalla el rango anterior).
 *  3. Confirmar, marcar y desmarcar no recargaban ante un error: la llamada pudo haber llegado y la
 *     tarjeta seguía «Pendiente». Hacen lo que resolver y deshacer.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'

const rpc = vi.fn()
const notifyError = vi.fn()

vi.mock('./base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
  notifyError: (...a: unknown[]) => notifyError(...a),
  getSucursalHeader: () => 1,
}))

import { useRendiciones } from './useRendiciones'

const RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }

const fila = (transportista: string, fecha: string) => ({
  fecha, transportista_id: transportista, transportista_nombre: transportista, estado: 'pendiente',
})

type Respuesta = { data: unknown; error: unknown }

/** Una respuesta que el test resuelve cuando quiere. */
function diferido() {
  let resolver!: (r: Respuesta) => void
  const promesa = new Promise<Respuesta>(res => { resolver = res })
  return { promesa, resolver }
}

const resumenPedidos = () => rpc.mock.calls.filter(([n]) => n === 'obtener_resumen_rendiciones')

/** Todo bien salvo lo que el test pise. */
function rpcBien(resumen: () => Promise<Respuesta> = () => Promise.resolve({ data: [], error: null })) {
  rpc.mockImplementation((nombre: string) => {
    if (nombre === 'obtener_resumen_rendiciones') return resumen()
    return Promise.resolve({ data: nombre.startsWith('obtener_') ? [] : null, error: null })
  })
}

const GASTOS_VACIOS = { vistos: [], guardar: [], quitar: [], pagos_personal_visto: 0, faltantes_visto: 0 }

describe('useRendiciones — un error de carga no es una lista vacía', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  it('si la carga falla lo dice `error`, y una carga que sale bien lo limpia', async () => {
    rpcBien(() => Promise.resolve({ data: null, error: RED }))
    const { result } = renderHook(() => useRendiciones())
    expect(result.current.error).toBe(false)

    await act(async () => { await result.current.fetchResumen('2026-11-01', '2026-11-07') })
    expect(result.current.error).toBe(true)
    expect(result.current.resumenes).toEqual([])

    rpcBien(() => Promise.resolve({ data: [fila('t1', '2026-11-02')], error: null }))
    await act(async () => { await result.current.fetchResumen('2026-11-01', '2026-11-07') })
    expect(result.current.error).toBe(false)
    expect(result.current.resumenes).toHaveLength(1)
  })

  it('un rango sin rendiciones (respuesta vacía) NO es error', async () => {
    rpcBien()
    const { result } = renderHook(() => useRendiciones())
    await act(async () => { await result.current.fetchResumen('2026-11-01', '2026-11-07') })
    expect(result.current.error).toBe(false)
    expect(result.current.resumenes).toEqual([])
  })
})

describe('useRendiciones — la última carga pedida es la que manda', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  it('una respuesta vieja que llega tarde no pisa la nueva', async () => {
    const vieja = diferido()
    const nueva = diferido()
    const cola = [vieja, nueva]
    rpcBien(() => cola.shift()!.promesa)
    const { result } = renderHook(() => useRendiciones())

    let cargaVieja!: Promise<unknown>
    let cargaNueva!: Promise<unknown>
    act(() => {
      cargaVieja = result.current.fetchResumen('2026-10-01', '2026-10-07')
      cargaNueva = result.current.fetchResumen('2026-11-01', '2026-11-07')
    })
    await waitFor(() => expect(resumenPedidos()).toHaveLength(2))

    // Primero llega la nueva, después la vieja.
    await act(async () => {
      nueva.resolver({ data: [fila('t-nueva', '2026-11-02')], error: null })
      await cargaNueva
    })
    expect(result.current.resumenes.map(r => r.transportista_id)).toEqual(['t-nueva'])
    expect(result.current.loading).toBe(false)

    await act(async () => {
      vieja.resolver({ data: [fila('t-vieja', '2026-10-02')], error: null })
      await cargaVieja
    })
    expect(result.current.resumenes.map(r => r.transportista_id)).toEqual(['t-nueva'])
  })

  it('un error de la carga vieja no marca error ni vacía lo que la nueva ya mostró', async () => {
    const vieja = diferido()
    const nueva = diferido()
    const cola = [vieja, nueva]
    rpcBien(() => cola.shift()!.promesa)
    const { result } = renderHook(() => useRendiciones())

    let cargaVieja!: Promise<unknown>
    let cargaNueva!: Promise<unknown>
    act(() => {
      cargaVieja = result.current.fetchResumen('2026-10-01', '2026-10-07')
      cargaNueva = result.current.fetchResumen('2026-11-01', '2026-11-07')
    })
    await waitFor(() => expect(resumenPedidos()).toHaveLength(2))

    await act(async () => {
      nueva.resolver({ data: [fila('t-nueva', '2026-11-02')], error: null })
      await cargaNueva
    })
    await act(async () => {
      vieja.resolver({ data: null, error: RED })
      await cargaVieja
    })

    expect(result.current.error).toBe(false)
    expect(result.current.resumenes.map(r => r.transportista_id)).toEqual(['t-nueva'])
    expect(notifyError).not.toHaveBeenCalled()
  })

  it('mientras la nueva sigue en vuelo, la vieja que termina no apaga el «cargando»', async () => {
    const vieja = diferido()
    const nueva = diferido()
    const cola = [vieja, nueva]
    rpcBien(() => cola.shift()!.promesa)
    const { result } = renderHook(() => useRendiciones())

    let cargaVieja!: Promise<unknown>
    let cargaNueva!: Promise<unknown>
    act(() => {
      cargaVieja = result.current.fetchResumen('2026-10-01', '2026-10-07')
      cargaNueva = result.current.fetchResumen('2026-11-01', '2026-11-07')
    })
    await waitFor(() => expect(resumenPedidos()).toHaveLength(2))

    await act(async () => {
      vieja.resolver({ data: [fila('t-vieja', '2026-10-02')], error: null })
      await cargaVieja
    })
    expect(result.current.loading).toBe(true)
    expect(result.current.resumenes).toEqual([])

    await act(async () => {
      nueva.resolver({ data: [fila('t-nueva', '2026-11-02')], error: null })
      await cargaNueva
    })
    expect(result.current.loading).toBe(false)
    expect(result.current.resumenes.map(r => r.transportista_id)).toEqual(['t-nueva'])
  })
})

describe('useRendiciones — confirmar, marcar y desmarcar recargan ante un error (la llamada pudo llegar)', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  const CAMINOS: Array<{
    nombre: string
    rpc: string
    llamar: (h: ReturnType<typeof useRendiciones>) => Promise<unknown>
  }> = [
    { nombre: 'confirmarRendicion', rpc: 'confirmar_rendicion', llamar: h => h.confirmarRendicion('2026-11-02', 't1', 'confirmada', null, GASTOS_VACIOS) },
    { nombre: 'marcarControlada', rpc: 'marcar_rendicion_controlada', llamar: h => h.marcarControlada('2026-11-02', 't1') },
    { nombre: 'desmarcarControlada', rpc: 'desmarcar_rendicion_controlada', llamar: h => h.desmarcarControlada('2026-11-02', 't1') },
  ]

  describe.each(CAMINOS)('$nombre', ({ rpc: nombreRpc, llamar }) => {
    it('si la llamada falla, vuelve a leer el mismo rango y relanza el error', async () => {
      rpc.mockImplementation((nombre: string) => {
        if (nombre === nombreRpc) return Promise.resolve({ data: null, error: RED })
        if (nombre === 'obtener_resumen_rendiciones') return Promise.resolve({ data: [fila('t1', '2026-11-02')], error: null })
        return Promise.resolve({ data: [], error: null })
      })
      const { result } = renderHook(() => useRendiciones())
      await act(async () => { await result.current.fetchResumen('2026-11-01', '2026-11-07', 't1') })
      expect(resumenPedidos()).toHaveLength(1)

      let lanzado: Error | undefined
      await act(async () => { await llamar(result.current).catch((e: Error) => { lanzado = e }) })

      expect(lanzado).toBeInstanceOf(Error)
      expect(lanzado!.message).toMatch(/Sin conexión/)
      const pedidos = resumenPedidos()
      expect(pedidos).toHaveLength(2)
      expect(pedidos[1][1]).toEqual({ p_fecha_desde: '2026-11-01', p_fecha_hasta: '2026-11-07', p_transportista_id: 't1' })
    })
  })
})
