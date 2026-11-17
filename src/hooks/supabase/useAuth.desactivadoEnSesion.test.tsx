/**
 * 1600-b15, a mitad de sesión (decisión del dueño: «las sesiones no caducan»).
 *
 * Con la app abierta, el perfil se revalida al volver el foco o la red, cada tanto y cuando una RPC
 * contesta «Usuario desactivado». SÓLO se cierra si el server devuelve la fila con `activo === false`:
 * la red caída, el timeout, la fila que no llegó, un 42501 o un `activo` nulo no sacan a nadie.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'

const { mockSupabase } = vi.hoisted(() => ({
  mockSupabase: {
    auth: { getSession: vi.fn(), signInWithPassword: vi.fn(), signOut: vi.fn(), refreshSession: vi.fn(), onAuthStateChange: vi.fn() },
    from: vi.fn(),
  },
}))
vi.mock('./base', () => ({ supabase: mockSupabase }))
vi.mock('../../lib/queryClient', () => ({ queryClient: { clear: vi.fn() } }))
vi.mock('../../lib/rutaOfflineCache', () => ({ olvidarRuta: vi.fn(), olvidarTodasLasRutas: vi.fn() }))
vi.mock('../../lib/offlineDb', () => ({ limpiarCachesDeLectura: vi.fn().mockResolvedValue(undefined) }))
vi.mock('../../contexts/SucursalContext', () => ({ SUCURSAL_STORAGE_KEY: 'distribuidora_sucursal_activa' }))

import { AuthProvider, useAuth } from './useAuth'
import { leerAvisoDeCierre, olvidarAvisoDeCierre, MENSAJES_DE_CIERRE } from '../../utils/avisoDeCierreDeSesion'
import { pedirRevalidacionDelPerfil } from '../../utils/revalidarPerfil'

const USUARIO = { id: 'user-A', email: 'a@x.com' }
const perfil = (activo: boolean | null) => ({ id: 'user-A', nombre: 'A', email: 'a@x.com', rol: 'preventista', activo })
const SIN_RED = { message: 'TypeError: Failed to fetch', code: '' }
const SIN_PERMISO = { message: 'permission denied for table perfiles', code: '42501' }

let respuestaPerfil: () => { data: unknown; error: unknown }
const wrapper = ({ children }: { children: React.ReactNode }) => <AuthProvider>{children}</AuthProvider>

async function sesionAbierta() {
  const hook = renderHook(() => useAuth(), { wrapper })
  await waitFor(() => expect(hook.result.current.perfil?.id).toBe('user-A'))
  mockSupabase.from.mockClear()
  return hook
}

async function volverElFoco() {
  await act(async () => {
    window.dispatchEvent(new Event('focus'))
    await new Promise(r => setTimeout(r, 30))
  })
}

beforeEach(() => {
  vi.clearAllMocks()
  localStorage.clear()
  olvidarAvisoDeCierre()
  respuestaPerfil = () => ({ data: perfil(true), error: null })
  mockSupabase.auth.getSession.mockResolvedValue({ data: { session: { user: USUARIO } } })
  mockSupabase.auth.signOut.mockResolvedValue({ error: null })
  mockSupabase.auth.refreshSession.mockResolvedValue({ data: { session: { user: USUARIO } }, error: null })
  mockSupabase.auth.onAuthStateChange.mockImplementation(() => ({ data: { subscription: { unsubscribe: vi.fn() } } }))
  mockSupabase.from.mockImplementation(() => ({
    select: () => ({ eq: () => ({ maybeSingle: async () => respuestaPerfil() }) }),
  }))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('el desactivado sale a mitad de sesión (1600-b15)', () => {
  it('al volver el foco, si el server dice «desactivado», lo saca con el aviso', async () => {
    const { result } = await sesionAbierta()

    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await volverElFoco()

    await waitFor(() => expect(result.current.user).toBeNull())
    expect(mockSupabase.auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
    expect(leerAvisoDeCierre()).toBe('desactivado')
  })

  it('al volver la red también', async () => {
    const { result } = await sesionAbierta()

    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await act(async () => {
      window.dispatchEvent(new Event('online'))
      await new Promise(r => setTimeout(r, 30))
    })

    await waitFor(() => expect(result.current.user).toBeNull())
    expect(leerAvisoDeCierre()).toBe('desactivado')
  })

  it('cuando una RPC contestó «Usuario desactivado» y piden revalidar, lo confirma con el perfil y lo saca', async () => {
    const { result } = await sesionAbierta()

    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await act(async () => {
      pedirRevalidacionDelPerfil()
      await new Promise(r => setTimeout(r, 30))
    })

    await waitFor(() => expect(result.current.user).toBeNull())
    expect(leerAvisoDeCierre()).toBe('desactivado')
  })

  it('cada 7 minutos, con la pestaña visible', async () => {
    // Se captura el intervalo que registra useAuth en vez de falsear los timers: el waitFor de RTL usa
    // setInterval y con timers falsos no avanza.
    const intervalos = vi.spyOn(globalThis, 'setInterval')
    const { result } = await sesionAbierta()
    const revalidacion = intervalos.mock.calls.find(([, ms]) => ms === 7 * 60 * 1000)
    expect(revalidacion).toBeDefined()

    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await act(async () => {
      ;(revalidacion![0] as () => void)()
      await new Promise(r => setTimeout(r, 30))
    })

    await waitFor(() => expect(result.current.user).toBeNull())
    expect(leerAvisoDeCierre()).toBe('desactivado')
    intervalos.mockRestore()
  })

  it('una sola vez: un segundo foco después de salir no vuelve a cerrar ni a leer', async () => {
    const { result } = await sesionAbierta()
    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await volverElFoco()
    await waitFor(() => expect(result.current.user).toBeNull())

    await volverElFoco()
    await act(async () => { pedirRevalidacionDelPerfil(); await new Promise(r => setTimeout(r, 30)) })

    expect(mockSupabase.auth.signOut).toHaveBeenCalledTimes(1)
    expect(mockSupabase.from).toHaveBeenCalledTimes(1)
  })

  it('el aviso dice que lo que estaba a medio cargar no se guardó', () => {
    expect(MENSAJES_DE_CIERRE.desactivado).toMatch(/a medio cargar, no se guardó/)
  })
})

describe('lo que NO es «desactivado» no saca a nadie (1600-b15)', () => {
  const noLoSaca: Array<[string, () => { data: unknown; error: unknown }]> = [
    ['la red caída', () => ({ data: null, error: SIN_RED })],
    ['un permiso denegado (42501)', () => ({ data: null, error: SIN_PERMISO })],
    ['la fila que no llegó', () => ({ data: null, error: null })],
    ['un `activo` nulo', () => ({ data: perfil(null), error: null })],
  ]

  for (const [nombre, respuesta] of noLoSaca) {
    it(`${nombre}: la sesión sigue y no hay aviso`, async () => {
      const { result } = await sesionAbierta()

      respuestaPerfil = respuesta
      await volverElFoco()
      await act(async () => { pedirRevalidacionDelPerfil(); await new Promise(r => setTimeout(r, 30)) })

      expect(mockSupabase.from).toHaveBeenCalled()
      expect(result.current.user?.id).toBe('user-A')
      expect(result.current.perfil?.id).toBe('user-A')
      expect(mockSupabase.auth.signOut).not.toHaveBeenCalled()
      expect(leerAvisoDeCierre()).toBeNull()
    })
  }

  it('un timeout: la sesión sigue y no hay aviso', async () => {
    const { result } = await sesionAbierta()

    respuestaPerfil = () => { throw new Error('fetchPerfil timed out after 15000ms') }
    await volverElFoco()

    expect(mockSupabase.from).toHaveBeenCalled()
    expect(result.current.user?.id).toBe('user-A')
    expect(mockSupabase.auth.signOut).not.toHaveBeenCalled()
    expect(leerAvisoDeCierre()).toBeNull()
  })

  it('sin red del dispositivo (navigator.onLine false) ni siquiera consulta por foco o intervalo', async () => {
    const { result } = await sesionAbierta()

    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await volverElFoco()

    expect(mockSupabase.from).not.toHaveBeenCalled()
    expect(result.current.user?.id).toBe('user-A')
    vi.restoreAllMocks()
  })

  it('con la pestaña oculta tampoco consulta por foco', async () => {
    const { result } = await sesionAbierta()

    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden')
    respuestaPerfil = () => ({ data: perfil(false), error: null })
    await volverElFoco()

    expect(mockSupabase.from).not.toHaveBeenCalled()
    expect(result.current.user?.id).toBe('user-A')
    vi.restoreAllMocks()
  })

  it('un perfil activo que sigue igual no vuelve a pisar el estado (sin re-render de más)', async () => {
    const { result } = await sesionAbierta()
    const antes = result.current.perfil

    await volverElFoco()

    expect(mockSupabase.from).toHaveBeenCalled()
    expect(result.current.perfil).toBe(antes)
  })
})
