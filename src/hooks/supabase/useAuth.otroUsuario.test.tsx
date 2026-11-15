/**
 * INF-3 (#1563): otro usuario que entra en otra pestaña no hereda lo del anterior.
 *
 * supabase-js comparte la sesión entre pestañas: cuando B inicia sesión en otra,
 * esta recibe un SIGNED_IN de B sin haber pasado por un SIGNED_OUT de A. Antes se
 * cargaba el perfil de B y el caché de TanStack Query quedaba en pie: sus claves
 * llevan la sucursal pero no el usuario, así que B veía lo que había visto A.
 * Ahora se limpia como en un logout, antes de cargar a B.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'

const { mockSupabase, queryClientClear, olvidarTodasLasRutas, limpiarCachesDeLectura } = vi.hoisted(() => ({
  queryClientClear: vi.fn(),
  olvidarTodasLasRutas: vi.fn(),
  limpiarCachesDeLectura: vi.fn().mockResolvedValue(undefined),
  mockSupabase: {
    auth: { getSession: vi.fn(), signInWithPassword: vi.fn(), signOut: vi.fn(), refreshSession: vi.fn(), onAuthStateChange: vi.fn() },
    from: vi.fn(),
  },
}))
vi.mock('./base', () => ({ supabase: mockSupabase }))
vi.mock('../../lib/queryClient', () => ({ queryClient: { clear: queryClientClear } }))
vi.mock('../../lib/rutaOfflineCache', () => ({ olvidarRuta: vi.fn(), olvidarTodasLasRutas }))
vi.mock('../../lib/offlineDb', () => ({ limpiarCachesDeLectura }))
vi.mock('../../contexts/SucursalContext', () => ({ SUCURSAL_STORAGE_KEY: 'distribuidora_sucursal_activa' }))

import { AuthProvider, useAuth } from './useAuth'
import { claveNotificaciones, usuarioNotificaciones } from '../../utils/notificacionesGuardadas'
import { requestIdPersistente } from '../../utils/requestIdPersistente'

type Emisor = (evento: string, sesion: unknown) => void

const A = { id: 'user-A', email: 'a@x.com' }
const B = { id: 'user-B', email: 'b@x.com' }
const perfil = (id: string) => ({
  id, nombre: id, email: `${id}@x.com`, rol: id === 'user-A' ? 'admin' : 'preventista', activo: true,
})
const HUELLA_COBRO = 'pedido|9|2026-11-12||100@efectivo'

describe('INF-3: SIGNED_IN de otro usuario sin logout', () => {
  let emitir: Emisor | null = null

  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
    mockSupabase.auth.getSession.mockResolvedValue({ data: { session: { user: A } } })
    mockSupabase.auth.signOut.mockResolvedValue({ error: null })
    mockSupabase.auth.onAuthStateChange.mockImplementation((f: Emisor) => {
      emitir = f
      return { data: { subscription: { unsubscribe: vi.fn() } } }
    })
    mockSupabase.from.mockImplementation(() => ({
      select: () => ({ eq: (_c: string, id: string) => ({ maybeSingle: async () => ({ data: perfil(id), error: null }) }) }),
    }))
  })

  async function sesionDeA() {
    const wrapper = ({ children }: { children: React.ReactNode }) => <AuthProvider>{children}</AuthProvider>
    const hook = renderHook(() => useAuth(), { wrapper })
    await waitFor(() => expect(hook.result.current.perfil?.id).toBe('user-A'))
    return hook
  }

  it('borra el caché, las rutas, los caches de lectura y lo guardado de A antes de cargar a B', async () => {
    const { result } = await sesionDeA()
    localStorage.setItem(claveNotificaciones('user-A'), JSON.stringify([{ id: 1, title: 'Cobro a Kiosco X' }]))
    const claveCobroDeA = requestIdPersistente(HUELLA_COBRO)
    expect(queryClientClear).not.toHaveBeenCalled()

    await act(async () => {
      emitir?.('SIGNED_IN', { user: B })
      await new Promise(r => setTimeout(r, 20))
    })
    await waitFor(() => expect(result.current.perfil?.id).toBe('user-B'))

    expect(result.current.isAdmin).toBe(false)
    expect(queryClientClear).toHaveBeenCalledTimes(1)
    expect(olvidarTodasLasRutas).toHaveBeenCalled()
    expect(limpiarCachesDeLectura).toHaveBeenCalled()
    expect(localStorage.getItem(claveNotificaciones('user-A'))).toBeNull()
    // Las claves de los cobros de A no se le ofrecen a B: B arranca con otra.
    expect(requestIdPersistente(HUELLA_COBRO)).not.toBe(claveCobroDeA)
    // Las notificaciones que se guarden desde ahora son de B.
    expect(usuarioNotificaciones()).toBe('user-B')
  })

  it('un SIGNED_IN del mismo usuario (otra pestaña que reentra) no borra nada', async () => {
    const { result } = await sesionDeA()

    await act(async () => {
      emitir?.('SIGNED_IN', { user: A })
      await new Promise(r => setTimeout(r, 20))
    })

    expect(result.current.perfil?.id).toBe('user-A')
    expect(queryClientClear).not.toHaveBeenCalled()
  })
})
