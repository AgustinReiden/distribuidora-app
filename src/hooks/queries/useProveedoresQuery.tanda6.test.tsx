/**
 * Tanda 6 (#1603), gestion-B3 y gestion-B4.
 *
 * B3: el alta de un proveedor con la lista fuera de caché (la consulta había fallado) sembraba una
 *     lista de UNA fila y quedaba «fresca» 10 minutos.
 * B4: guardar la edición de un proveedor mandaba `activo` desde la copia de la lista: si otro admin
 *     lo había desactivado en el medio, lo reactivaba.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const actualizados: Array<Record<string, unknown>> = []

function builder() {
  let escritura: Record<string, unknown> | null = null
  const b: Record<string, unknown> = {}
  b.select = () => b
  b.eq = () => b
  b.ilike = () => b
  b.insert = (rows: Array<Record<string, unknown>>) => { escritura = rows[0]; return b }
  b.update = (fila: Record<string, unknown>) => { actualizados.push(fila); escritura = fila; return b }
  b.single = () => Promise.resolve({ data: { id: 7, nombre: 'Nuevo', ...escritura }, error: null })
  b.then = (resolve: (v: unknown) => unknown) => Promise.resolve({ data: [], error: null }).then(resolve)
  return b
}

vi.mock('../supabase/base', () => ({
  supabase: { from: () => builder(), rpc: vi.fn() },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  useCrearProveedorMutation,
  useActualizarProveedorMutation,
  proveedoresKeys,
} from './useProveedoresQuery'

function montar() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, wrapper }
}

describe('gestion-B3: el alta no siembra una lista de una fila', () => {
  beforeEach(() => { actualizados.length = 0 })

  it('con la lista fuera de caché, el alta no la deja con un solo proveedor', async () => {
    const { qc, wrapper } = montar()
    const { result } = renderHook(() => useCrearProveedorMutation(), { wrapper })
    await act(async () => { await result.current.mutateAsync({ nombre: 'Nuevo' } as never) })
    expect(qc.getQueryData(proveedoresKeys.lists(1))).toBeUndefined()
  })

  it('con la lista en caché, el alta suma el proveedor en su lugar', async () => {
    const { qc, wrapper } = montar()
    qc.setQueryData(proveedoresKeys.lists(1), [{ id: 1, nombre: 'Zeta' }, { id: 2, nombre: 'Alfa' }])
    const { result } = renderHook(() => useCrearProveedorMutation(), { wrapper })
    await act(async () => { await result.current.mutateAsync({ nombre: 'Nuevo' } as never) })
    const lista = qc.getQueryData<Array<{ nombre: string }>>(proveedoresKeys.lists(1)) ?? []
    expect(lista.map(p => p.nombre)).toEqual(['Alfa', 'Nuevo', 'Zeta'])
  })
})

describe('gestion-B4: editar un proveedor no toca su estado', () => {
  beforeEach(() => { actualizados.length = 0 })

  it('el UPDATE no manda `activo`, aunque el formulario lo traiga en true', async () => {
    const { qc, wrapper } = montar()
    qc.setQueryData(proveedoresKeys.lists(1), [{ id: '5', nombre: 'Viejo', activo: true }])
    const { result } = renderHook(() => useActualizarProveedorMutation(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ id: '5', data: { nombre: 'Renombrado', activo: true } as never })
    })
    expect(actualizados).toHaveLength(1)
    expect(actualizados[0]).not.toHaveProperty('activo')
    expect(actualizados[0].nombre).toBe('Renombrado')
  })
})
