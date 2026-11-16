/**
 * Crear una promo son tres INSERT sin transacción (#1561, 1561-b12): promo, productos y
 * reglas. Si los productos o las reglas fallan, la promo quedaba creada, activa y vacía.
 * Ahora se borra (nadie la usó todavía) y el error dice qué pasó.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  log: [] as string[],
  respuestas: {} as Record<string, { data?: unknown; error?: { code: string; message: string } | null }>,
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      let op = 'select'
      const responder = () => {
        estado.log.push(`${tabla}.${op}`)
        const r = estado.respuestas[`${tabla}.${op}`]
        return Promise.resolve({ data: r?.data ?? [], error: r?.error ?? null })
      }
      const b: Record<string, unknown> = {}
      for (const nombre of ['insert', 'delete']) b[nombre] = () => { op = nombre; return b }
      for (const nombre of ['select', 'eq']) b[nombre] = () => b
      b.single = () => responder().then(r => ({ ...r, data: Array.isArray(r.data) ? r.data[0] : r.data }))
      b.then = (ok: (v: unknown) => unknown, ko?: (e: unknown) => unknown) => responder().then(ok, ko)
      return b
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearPromocionMutation } from './usePromocionesQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
}

const entrada = {
  nombre: 'Promo', tipo: 'bonificacion', fechaInicio: '2026-11-01',
  productoIds: ['1', '2'], reglas: [{ clave: 'cantidad_compra', valor: 6 }],
}

beforeEach(() => {
  estado.log = []
  estado.respuestas = { 'promociones.insert': { data: [{ id: '5', nombre: 'Promo' }] } }
})

describe('crear una promo (1561-b12)', () => {
  it('si fallan los productos, borra la promo recién creada y dice que no se creó nada', async () => {
    estado.respuestas['promocion_productos.insert'] = { error: { code: 'P0001', message: 'producto inactivo' } }
    const { result } = renderHook(() => useCrearPromocionMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/producto inactivo.*No se creó nada/)
    expect(estado.log).toContain('promociones.delete')
    // No siguió con las reglas.
    expect(estado.log).not.toContain('promocion_reglas.insert')
  })

  it('si fallan las reglas, también la deshace', async () => {
    estado.respuestas['promocion_reglas.insert'] = { error: { code: 'P0001', message: 'regla inválida' } }
    const { result } = renderHook(() => useCrearPromocionMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/regla inválida.*No se creó nada/)
    expect(estado.log).toContain('promociones.delete')
  })

  it('si ni borrarla se pudo, avisa que quedó a medias', async () => {
    estado.respuestas['promocion_productos.insert'] = { error: { code: 'P0001', message: 'producto inactivo' } }
    estado.respuestas['promociones.delete'] = { error: { code: 'P0001', message: 'no' } }
    const { result } = renderHook(() => useCrearPromocionMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/quedó creada a medias/)
  })

  it('si todo sale bien no borra nada', async () => {
    const { result } = renderHook(() => useCrearPromocionMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync(entrada as never)

    expect(estado.log).not.toContain('promociones.delete')
  })
})
