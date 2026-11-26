/**
 * T9 (ola 3 de #1603): el selector del vendedor en la edición del pedido ofrece lo mismo que acepta
 * actualizar_preventista_pedido: admin y preventista activos de la sucursal, y quien actúa como
 * preventista por el rol extra (perfil_roles), sin ser admin ni encargado. Sin la opción (el alta,
 * las metas) la lista sigue siendo la de siempre: crear_pedido_completo todavía pide el rol base.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  tablas: [] as string[],
  filtros: [] as Array<[string, string, unknown, unknown?]>,
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      estado.tablas.push(tabla)
      let porId = false
      const b: Record<string, unknown> = {}
      for (const m of ['select', 'eq', 'order']) b[m] = (...a: unknown[]) => { estado.filtros.push([tabla, m, a[0], a[1]]); return b }
      b.in = (col: string, v: unknown) => { estado.filtros.push([tabla, 'in', col, v]); if (col === 'id') porId = true; return b }
      b.not = (col: string, op: string, v: unknown) => { estado.filtros.push([tabla, 'not', col, `${op} ${String(v)}`]); return b }
      b.then = (resolve: (v: unknown) => unknown) => {
        let data: unknown[] = []
        if (tabla === 'perfil_roles') data = [{ usuario_id: 'u-chofer' }, { usuario_id: 'u-ana' }]
        else if (porId) data = [{ id: 'u-chofer', nombre: 'Beto chofer', rol: 'transportista', activo: true }]
        else data = [{ id: 'u-ana', nombre: 'Ana', rol: 'preventista', activo: true }, { id: 'u-zoe', nombre: 'Zoe', rol: 'admin', activo: true }]
        return Promise.resolve({ data, error: null }).then(resolve)
      }
      return b
    },
    rpc: vi.fn(),
    auth: { getUser: vi.fn() },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePreventistasAsignablesQuery } from './useUsuariosQuery'

const wrapper = ({ children }: { children: React.ReactNode }) => (
  <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>{children}</QueryClientProvider>
)

beforeEach(() => {
  estado.tablas.length = 0
  estado.filtros.length = 0
})

describe('usePreventistasAsignablesQuery', () => {
  it('sin la opción: admin y preventista de la sucursal, sin leer los roles extra', async () => {
    const { result } = renderHook(() => usePreventistasAsignablesQuery(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data?.map(p => p.id)).toEqual(['u-ana', 'u-zoe'])
    expect(estado.tablas).toEqual(['perfiles'])
  })

  it('con conExtraPreventista suma al chofer con el extra de preventista, sin repetir y por nombre', async () => {
    const { result } = renderHook(() => usePreventistasAsignablesQuery({ conExtraPreventista: true }), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data?.map(p => p.nombre)).toEqual(['Ana', 'Beto chofer', 'Zoe'])
    expect(estado.filtros).toContainEqual(['perfil_roles', 'eq', 'rol', 'preventista'])
    expect(estado.filtros).toContainEqual(['perfil_roles', 'eq', 'sucursal_id', 1])
    // Ana ya estaba por el rol base: se piden sólo los que faltan, activos, de la sucursal y sin admin ni encargado.
    expect(estado.filtros).toContainEqual(['perfiles', 'in', 'id', ['u-chofer']])
    expect(estado.filtros).toContainEqual(['perfiles', 'not', 'rol', 'in (admin,encargado)'])
  })
})
