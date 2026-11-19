/**
 * Escrituras de `useUsuariosQuery` (#1599 b2, #1561 b12).
 *
 * - b2: activar o desactivar a un usuario que la policy no deja tocar da cero filas
 *   (PGRST116) y la pantalla mostraba «Cannot coerce the result…»; ahora dice lo
 *   mismo que la edición.
 * - b12: los roles extra se reemplazaban con DELETE + INSERT REST, sin transacción:
 *   si el INSERT fallaba el usuario quedaba sin roles. Ahora es UNA RPC
 *   (`guardar_roles_extra`, C4b de #1603) que deja los roles como la lista, en una
 *   transacción, y el front no escribe perfil_roles por REST.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  llamadas: [] as string[],
  rpcs: [] as Array<{ fn: string; args: Record<string, unknown> }>,
  errorRpc: null as null | { code: string; message: string },
  errorUpdate: null as null | { code: string; message: string },
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      if (tabla === 'perfiles') {
        const b = {
          update: () => b,
          eq: () => b,
          select: () => b,
          single: async () => ({ data: estado.errorUpdate ? null : { id: 'u1', activo: true }, error: estado.errorUpdate }),
        }
        return b
      }
      // perfil_roles: ya no se escribe por REST.
      const registrar = (op: string) => () => { estado.llamadas.push(`${tabla}.${op}`); return Promise.resolve({ error: null }) }
      return { insert: registrar('insert'), delete: registrar('delete'), update: registrar('update'), upsert: registrar('upsert') }
    },
    rpc: async (fn: string, args: Record<string, unknown>) => {
      estado.rpcs.push({ fn, args })
      if (fn === 'guardar_usuario') {
        const p = args.p_usuario as { id: string; campos: Record<string, unknown> }
        return { data: estado.errorRpc ? null : { success: true, perfil: { id: p.id, ...p.campos } }, error: estado.errorRpc }
      }
      return { data: estado.errorRpc ? null : { roles: args.p_roles }, error: estado.errorRpc }
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useActualizarUsuarioMutation, useAsignarPerfilRolesMutation, useToggleUsuarioActivoMutation } from './useUsuariosQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
}

beforeEach(() => {
  estado.llamadas = []
  estado.rpcs = []
  estado.errorRpc = null
  estado.errorUpdate = null
})

describe('activar o desactivar un usuario (1599-b2)', () => {
  it('cero filas (PGRST116) dice que no podés editarlo, no «Cannot coerce…»', async () => {
    estado.errorUpdate = { code: 'PGRST116', message: 'Cannot coerce the result to a single JSON object' }
    const { result } = renderHook(() => useToggleUsuarioActivoMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync({ id: 'u1', activo: false }).catch(e => e as Error)

    expect((error as Error).message).toMatch(/No podés editar a este usuario.*sucursales que no son tuyas/)
    expect((error as Error).message).not.toMatch(/coerce/i)
  })

  it('otro error del server conserva su mensaje', async () => {
    estado.errorUpdate = { code: 'P0001', message: 'No se puede desactivar al último admin' }
    const { result } = renderHook(() => useToggleUsuarioActivoMutation(), { wrapper: wrapper() })

    await expect(result.current.mutateAsync({ id: 'u1', activo: false })).rejects.toThrow('No se puede desactivar al último admin')
  })
})

describe('roles extra del usuario (1561-b12, C4b)', () => {
  it('es una sola llamada a guardar_roles_extra con la lista entera, sin escrituras REST', async () => {
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync({ usuarioId: 'u1', roles: ['transportista'] })

    expect(estado.llamadas).toEqual([])
    expect(estado.rpcs).toEqual([{ fn: 'guardar_roles_extra', args: { p_usuario_id: 'u1', p_roles: ['transportista'] } }])
  })

  it('sacar el rol es mandar la lista vacía', async () => {
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync({ usuarioId: 'u1', roles: [] })

    expect(estado.rpcs[0].args).toEqual({ p_usuario_id: 'u1', p_roles: [] })
  })

  it('un rechazo del server llega con su motivo', async () => {
    estado.errorRpc = { code: '42501', message: 'No podés editar a este usuario: también trabaja en sucursales que no son tuyas. Lo edita un admin de todas ellas.' }
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    await expect(result.current.mutateAsync({ usuarioId: 'u1', roles: ['transportista'] }))
      .rejects.toThrow('No podés editar a este usuario')
  })

  it('sin respuesta, dice que se puede volver a guardar (deja los roles como se marcaron)', async () => {
    estado.errorRpc = { code: '', message: 'TypeError: Failed to fetch' }
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    await expect(result.current.mutateAsync({ usuarioId: 'u1', roles: ['transportista'] }))
      .rejects.toThrow(/Podés volver a guardar/)
  })
})

describe('guardar un usuario: el perfil y los roles extra en una sola llamada (C4b v2)', () => {
  it('llama a guardar_usuario con los campos y los roles, sin escribir perfiles ni perfil_roles por REST', async () => {
    const { result } = renderHook(() => useActualizarUsuarioMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync({ id: 'u1', data: { nombre: 'Nuevo', rol: 'deposito', activo: true, zona: null, rolesExtra: ['transportista'] } })

    expect(estado.llamadas).toEqual([])
    expect(estado.rpcs).toEqual([{
      fn: 'guardar_usuario',
      args: { p_usuario: { id: 'u1', campos: { nombre: 'Nuevo', rol: 'deposito', activo: true, zona: null }, roles_extra: ['transportista'] } },
    }])
  })

  it('sin roles extra (no cargaron) no los manda', async () => {
    const { result } = renderHook(() => useActualizarUsuarioMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync({ id: 'u1', data: { nombre: 'Nuevo' } })

    expect((estado.rpcs[0].args.p_usuario as Record<string, unknown>)).not.toHaveProperty('roles_extra')
  })

  it('un rechazo llega con su motivo (y no quedó nada: es una transacción)', async () => {
    estado.errorRpc = { code: '42501', message: 'No podés editar a este usuario: también trabaja en sucursales que no son tuyas. Lo edita un admin de todas ellas.' }
    const { result } = renderHook(() => useActualizarUsuarioMutation(), { wrapper: wrapper() })

    await expect(result.current.mutateAsync({ id: 'u1', data: { nombre: 'X', rolesExtra: [] } }))
      .rejects.toThrow('No podés editar a este usuario')
  })
})
