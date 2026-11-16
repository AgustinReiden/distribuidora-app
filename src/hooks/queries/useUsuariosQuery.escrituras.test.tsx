/**
 * Escrituras de `useUsuariosQuery` (#1599 b2, #1561 b12).
 *
 * - b2: activar o desactivar a un usuario que la policy no deja tocar da cero filas
 *   (PGRST116) y la pantalla mostraba «Cannot coerce the result…»; ahora dice lo
 *   mismo que la edición.
 * - b12: los roles extra se reemplazaban con DELETE de todo + INSERT de todo, sin
 *   transacción: si el INSERT fallaba el usuario quedaba sin roles. Ahora se
 *   escribe sólo la diferencia, quitando antes de agregar.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  rolesActuales: [] as string[],
  llamadas: [] as string[],
  errorInsert: null as null | { code: string; message: string },
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
      // perfil_roles
      return {
        select: () => ({
          eq: () => ({
            eq: async () => ({ data: estado.rolesActuales.map(rol => ({ rol })), error: null }),
          }),
        }),
        delete: () => {
          const b = {
            eq: () => b,
            in: async (_col: string, roles: string[]) => {
              estado.llamadas.push(`delete:${roles.join(',')}`)
              return { error: null }
            },
          }
          return b
        },
        insert: async (filas: Array<{ rol: string }>) => {
          estado.llamadas.push(`insert:${filas.map(f => f.rol).join(',')}`)
          return { error: estado.errorInsert }
        },
      }
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useAsignarPerfilRolesMutation, useToggleUsuarioActivoMutation } from './useUsuariosQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
}

beforeEach(() => {
  estado.rolesActuales = []
  estado.llamadas = []
  estado.errorInsert = null
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

describe('roles extra del usuario (1561-b12)', () => {
  it('sin cambios no escribe nada', async () => {
    estado.rolesActuales = ['transportista']
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync({ usuarioId: 'u1', roles: ['transportista'] })

    expect(estado.llamadas).toEqual([])
  })

  it('escribe sólo la diferencia: quita lo que sobra y agrega lo que falta, en ese orden', async () => {
    estado.rolesActuales = ['transportista', 'deposito']
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync({ usuarioId: 'u1', roles: ['deposito', 'preventista'] })

    expect(estado.llamadas).toEqual(['delete:transportista', 'insert:preventista'])
  })

  it('si falla el alta tras quitar, avisa qué quedó hecho', async () => {
    estado.rolesActuales = ['transportista']
    estado.errorInsert = { code: 'P0001', message: 'rol no permitido' }
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync({ usuarioId: 'u1', roles: ['preventista'] }).catch(e => e as Error)

    expect((error as Error).message).toMatch(/Se quitaron los roles transportista.*no se pudieron agregar preventista.*rol no permitido/s)
  })

  it('si falla el alta y no se quitó nada, el error es el del server', async () => {
    estado.rolesActuales = []
    estado.errorInsert = { code: 'P0001', message: 'rol no permitido' }
    const { result } = renderHook(() => useAsignarPerfilRolesMutation(), { wrapper: wrapper() })

    await expect(result.current.mutateAsync({ usuarioId: 'u1', roles: ['preventista'] })).rejects.toThrow('rol no permitido')
  })
})
