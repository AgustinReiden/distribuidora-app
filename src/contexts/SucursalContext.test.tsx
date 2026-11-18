/**
 * ARRANQUE SIN SEÑAL.
 *
 * Este contexto bloquea el arranque de la app: si la consulta de
 * `usuario_sucursales` falla, `sucursales` queda vacío y App muestra
 * "sin sucursal asignada". Sin red eso convertía un arranque offline en un
 * cartel de error — con `MainApp` montado pero inservible, que es justo el
 * escenario para el que existe toda la maquinaria offline.
 *
 * La distinción que fijan estos tests es la misma de useAuth: que el servidor
 * diga "no tenés sucursales" es una respuesta y se respeta; que no haya
 * servidor no es una respuesta, y ahí se sigue con lo último que se supo.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const setSucursalHeaderMock = vi.fn()
const eqMock = vi.fn()
const selectMock = vi.fn()

vi.mock('../lib/supabase', () => ({
  supabase: {
    from: (tabla: string) => ({
      select: (columnas: string) => {
        selectMock(tabla, columnas)
        return { eq: (...args: unknown[]) => eqMock(tabla, ...args) }
      },
    }),
    rpc: vi.fn(),
  },
  setSucursalHeader: (...args: unknown[]) => setSucursalHeaderMock(...args),
}))

const notifyErrorMock = vi.fn()
vi.mock('../hooks/supabase/base', () => ({
  notifyError: (...args: unknown[]) => notifyErrorMock(...args),
}))

import { supabase } from '../lib/supabase'
import { SucursalProvider, useSucursal } from './SucursalContext'

const USER = 'user-1'

const filaSucursal = {
  id: 1,
  usuario_id: USER,
  sucursal_id: 3,
  es_default: true,
  sucursal: { id: 3, nombre: 'Taco Pozo' },
}

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return (
    <QueryClientProvider client={qc}>
      <SucursalProvider userId={USER} globalRol="preventista">{children}</SucursalProvider>
    </QueryClientProvider>
  )
}

function responder(porTabla: Record<string, unknown>) {
  eqMock.mockImplementation((tabla: string) => {
    const respuesta = porTabla[tabla]
    return respuesta instanceof Error
      ? Promise.resolve({ data: null, error: { message: respuesta.message, code: '' } })
      : Promise.resolve({ data: respuesta, error: null })
  })
}

describe('SucursalContext', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
  })

  it('carga las sucursales del servidor y las deja cacheadas', async () => {
    responder({ usuario_sucursales: [filaSucursal], perfil_roles: [] })

    const { result } = renderHook(() => useSucursal(), { wrapper })

    await waitFor(() => expect(result.current.loading).toBe(false))
    expect(result.current.sucursales).toHaveLength(1)
    expect(result.current.currentSucursalId).toBe(3)
    expect(result.current.userId).toBe(USER)
    expect(localStorage.getItem('distribuidora:ultimas-sucursales')).toContain('Taco Pozo')
  })

  it('el rol de cada sucursal es el de perfiles, y no pide usuario_sucursales.rol (#1519)', async () => {
    responder({ usuario_sucursales: [filaSucursal], perfil_roles: [] })

    const { result } = renderHook(() => useSucursal(), { wrapper })

    await waitFor(() => expect(result.current.loading).toBe(false))
    expect(result.current.sucursales[0].rol).toBe('preventista')
    expect(result.current.currentSucursalRol).toBe('preventista')
    // La columna se dropea en #1525: un select que la nombre falla entero.
    const columnas = selectMock.mock.calls.find(([tabla]) => tabla === 'usuario_sucursales')?.[1] as string
    expect(columnas.split(',').map((c) => c.trim())).not.toContain('rol')
  })

  it('sin red usa las últimas sucursales conocidas en vez de bloquear la app', async () => {
    localStorage.setItem(
      'distribuidora:ultimas-sucursales',
      JSON.stringify({ userId: USER, sucursales: [{ id: 3, nombre: 'Taco Pozo', rol: 'preventista', rolesExtra: [] }] }),
    )
    responder({
      usuario_sucursales: new Error('TypeError: Failed to fetch'),
      perfil_roles: new Error('TypeError: Failed to fetch'),
    })

    const { result } = renderHook(() => useSucursal(), { wrapper })

    await waitFor(() => expect(result.current.loading).toBe(false))
    expect(result.current.sucursales).toHaveLength(1)
    expect(result.current.currentSucursalId).toBe(3)
    // El header tiene que quedar puesto: los RPC resuelven la sucursal con él.
    expect(setSucursalHeaderMock).toHaveBeenCalledWith(3)
  })

  it('no usa el caché de otro usuario', async () => {
    localStorage.setItem(
      'distribuidora:ultimas-sucursales',
      JSON.stringify({ userId: 'otro-usuario', sucursales: [{ id: 9, nombre: 'Ajena', rol: 'admin', rolesExtra: [] }] }),
    )
    responder({
      usuario_sucursales: new Error('TypeError: Failed to fetch'),
      perfil_roles: new Error('TypeError: Failed to fetch'),
    })

    const { result } = renderHook(() => useSucursal(), { wrapper })

    await waitFor(() => expect(result.current.loading).toBe(false))
    expect(result.current.sucursales).toHaveLength(0)
  })

  it('si el servidor contesta que no hay sucursales, no las inventa desde el caché', async () => {
    // El cartel de "sin sucursal asignada" es correcto acá: el servidor
    // contestó. Taparlo con el caché sería el fallback fantasma que se sacó
    // en C6, ahora con otra cara.
    localStorage.setItem(
      'distribuidora:ultimas-sucursales',
      JSON.stringify({ userId: USER, sucursales: [{ id: 3, nombre: 'Taco Pozo', rol: 'preventista', rolesExtra: [] }] }),
    )
    responder({ usuario_sucursales: [], perfil_roles: [] })

    const { result } = renderHook(() => useSucursal(), { wrapper })

    await waitFor(() => expect(result.current.loading).toBe(false))
    expect(result.current.sucursales).toHaveLength(0)
    expect(result.current.currentSucursalId).toBeNull()
  })
})

/**
 * 1563-b3 / 1596-b8: `cambiar_sucursal` NO lanza cuando rechaza el cambio: contesta
 * `{ success: false, error }`. El front sólo miraba `error` y daba el cambio por hecho.
 */
describe('SucursalContext.switchSucursal', () => {
  const filas = [
    filaSucursal,
    { id: 2, usuario_id: USER, sucursal_id: 4, es_default: false, sucursal: { id: 4, nombre: 'Tucumán' } },
  ]

  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
  })

  async function montar() {
    responder({ usuario_sucursales: filas, perfil_roles: [] })
    const hook = renderHook(() => useSucursal(), { wrapper })
    await waitFor(() => expect(hook.result.current.loading).toBe(false))
    expect(hook.result.current.currentSucursalId).toBe(3)
    setSucursalHeaderMock.mockClear()
    return hook
  }

  it('si el servidor contesta success:false, no cambia la sucursal ni el header, y avisa', async () => {
    const { result } = await montar()
    vi.mocked(supabase.rpc).mockResolvedValue({
      data: { success: false, error: 'No autorizado para esta sucursal' },
      error: null,
    } as never)

    await act(async () => { await result.current.switchSucursal(4) })

    expect(result.current.currentSucursalId).toBe(3)
    expect(setSucursalHeaderMock).not.toHaveBeenCalled()
    expect(localStorage.getItem('distribuidora_sucursal_activa')).toBe('3')
    expect(notifyErrorMock).toHaveBeenCalledTimes(1)
    // Se muestra el motivo que manda el server.
    expect(notifyErrorMock.mock.calls[0][0]).toContain('No autorizado para esta sucursal')
  })

  it('si el motivo es que el usuario está desactivado, lo dice (no «no tenés acceso a esa sucursal»)', async () => {
    const { result } = await montar()
    vi.mocked(supabase.rpc).mockResolvedValue({
      data: { success: false, error: 'Usuario desactivado' },
      error: null,
    } as never)

    await act(async () => { await result.current.switchSucursal(4) })

    expect(result.current.currentSucursalId).toBe(3)
    expect(notifyErrorMock.mock.calls[0][0]).toContain('Usuario desactivado')
    expect(notifyErrorMock.mock.calls[0][0]).not.toMatch(/No tenés acceso/)
  })

  it('«Usuario desactivado» le pide a useAuth que revalide el perfil; otro motivo no', async () => {
    const pedidos = vi.fn()
    window.addEventListener('perfil:revalidar', pedidos)
    try {
      const { result } = await montar()
      vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: false, error: 'Usuario desactivado' }, error: null } as never)
      await act(async () => { await result.current.switchSucursal(4) })
      expect(pedidos).toHaveBeenCalledTimes(1)

      vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: false, error: 'No autorizado para esta sucursal' }, error: null } as never)
      await act(async () => { await result.current.switchSucursal(4) })
      expect(pedidos).toHaveBeenCalledTimes(1)
    } finally {
      window.removeEventListener('perfil:revalidar', pedidos)
    }
  })

  it('sin motivo en la respuesta usa el texto genérico', async () => {
    const { result } = await montar()
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: false }, error: null } as never)

    await act(async () => { await result.current.switchSucursal(4) })

    expect(notifyErrorMock.mock.calls[0][0]).toMatch(/No tenés acceso a esa sucursal/)
  })

  it('si el servidor contesta success:true, cambia la sucursal y el header', async () => {
    const { result } = await montar()
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true, sucursal_id: 4 }, error: null } as never)

    await act(async () => { await result.current.switchSucursal(4) })

    expect(result.current.currentSucursalId).toBe(4)
    expect(setSucursalHeaderMock).toHaveBeenCalledWith(4)
    expect(notifyErrorMock).not.toHaveBeenCalled()
  })

  it('un error del RPC tampoco cambia la sucursal, y ahora avisa', async () => {
    const { result } = await montar()
    vi.mocked(supabase.rpc).mockResolvedValue({ data: null, error: { message: 'Failed to fetch', code: '' } } as never)

    await act(async () => { await result.current.switchSucursal(4) })

    expect(result.current.currentSucursalId).toBe(3)
    expect(notifyErrorMock).toHaveBeenCalledTimes(1)
  })

  // N1 de la revisión de B12a: quien llama tiene que distinguir un «no» del servidor de una falla
  // de red (el aviso de la cola de otra sucursal deja de ofrecer el cambio sólo ante el «no»).
  it('dice cómo terminó: ok, rechazado (el servidor dijo que no) o fallo (sin respuesta)', async () => {
    const { result } = await montar()
    let resultado: string | undefined

    vi.mocked(supabase.rpc).mockResolvedValue({ data: null, error: { message: 'Failed to fetch', code: '' } } as never)
    await act(async () => { resultado = await result.current.switchSucursal(4) })
    expect(resultado).toBe('fallo')

    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: false, error: 'No autorizado para esta sucursal' }, error: null } as never)
    await act(async () => { resultado = await result.current.switchSucursal(4) })
    expect(resultado).toBe('rechazado')

    vi.mocked(supabase.rpc).mockResolvedValue({ data: null, error: { message: 'permission denied', code: '42501' } } as never)
    await act(async () => { resultado = await result.current.switchSucursal(4) })
    expect(resultado).toBe('rechazado')

    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true, sucursal_id: 4 }, error: null } as never)
    await act(async () => { resultado = await result.current.switchSucursal(4) })
    expect(resultado).toBe('ok')
  })
})
