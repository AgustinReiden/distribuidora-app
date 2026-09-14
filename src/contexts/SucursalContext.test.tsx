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
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const setSucursalHeaderMock = vi.fn()
const eqMock = vi.fn()

vi.mock('../lib/supabase', () => ({
  supabase: {
    from: (tabla: string) => ({
      select: () => ({ eq: (...args: unknown[]) => eqMock(tabla, ...args) }),
    }),
    rpc: vi.fn(),
  },
  setSucursalHeader: (...args: unknown[]) => setSucursalHeaderMock(...args),
}))

import { SucursalProvider, useSucursal } from './SucursalContext'

const USER = 'user-1'

const filaSucursal = {
  id: 1,
  usuario_id: USER,
  sucursal_id: 3,
  rol: 'preventista',
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
