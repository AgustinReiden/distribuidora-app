/**
 * FRG2-2 (#1599): las promos se leen completas y con los errores a la vista.
 *
 * `promocion_productos` y `promocion_reglas` se leían sin `range` ni `order` y
 * sin mirar el `error`: con más de 1.000 filas una promo se veía incompleta (y
 * guardarla desde el panel borraba lo que no había llegado), y un error de red
 * dejaba la lista vacía como si no hubiera promos.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Call { table: string; range?: [number, number]; ordenado: boolean }

const calls: Call[] = []
let falla: { table: string; message: string } | null = null

const PROMO = { id: 1, nombre: 'Combo grande', tipo: 'bonificacion', activo: true, created_at: '2026-11-01' }
// Más de una página (1.000 filas): lo que antes se cortaba en silencio.
const PRODUCTOS = Array.from({ length: 1500 }, (_, i) => ({ id: i + 1, promocion_id: 1, producto_id: 1000 + i }))
const REGLAS = [{ id: 1, promocion_id: 1, clave: 'cantidad_minima', valor: 6 }]

function builderFor(table: string) {
  const call: Call = { table, ordenado: false }
  const b = {
    select: () => b,
    eq: () => b,
    lte: () => b,
    or: () => b,
    in: () => b,
    order: () => { call.ordenado = true; return b },
    range: (desde: number, hasta: number) => { call.range = [desde, hasta]; return b },
    then(onFulfilled: (v: unknown) => unknown) {
      calls.push(call)
      if (falla && falla.table === table) {
        return Promise.resolve({ data: null, error: { message: falla.message, code: 'XX000' } }).then(onFulfilled)
      }
      const todas = table === 'promociones' ? [PROMO] : table === 'promocion_productos' ? PRODUCTOS : REGLAS
      // Sin `range` devuelve sólo la primera página, como PostgREST (tope de 1.000).
      const [desde, hasta] = call.range ?? [0, 999]
      return Promise.resolve({ data: todas.slice(desde, hasta + 1), error: null }).then(onFulfilled)
    },
  }
  return b
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (table: string) => builderFor(table) },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePromoMapQuery, usePromocionesListQuery } from './usePromocionesQuery'

const montar = <T,>(hook: () => T) => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  )
  return renderHook(hook, { wrapper })
}

describe('promos: lectura completa y con error visible (FRG2-2)', () => {
  beforeEach(() => { calls.length = 0; falla = null })

  it('la lista del panel trae los 1.500 productos de la promo, no los primeros 1.000', async () => {
    const { result } = montar(() => usePromocionesListQuery())
    await waitFor(() => expect(result.current.data).toBeDefined())
    expect(result.current.data?.[0].productos).toHaveLength(1500)
    expect(result.current.data?.[0].reglas).toHaveLength(1)
  })

  it('el PromoMap resuelve los 1.500 productos', async () => {
    const { result } = montar(() => usePromoMapQuery())
    await waitFor(() => expect(result.current.data).toBeDefined())
    expect(result.current.data?.size).toBe(1500)
    expect(result.current.data?.has('2499')).toBe(true)
  })

  it('toda lectura de promos va paginada y ordenada', async () => {
    const { result } = montar(() => usePromocionesListQuery())
    await waitFor(() => expect(result.current.data).toBeDefined())
    expect(calls.length).toBeGreaterThan(0)
    for (const c of calls) {
      expect(c.range, `${c.table} sin range`).toBeDefined()
      expect(c.ordenado, `${c.table} sin order`).toBe(true)
    }
  })

  it('un error al leer los productos de la promo se ve como error, no como lista vacía', async () => {
    falla = { table: 'promocion_productos', message: 'canceling statement due to statement timeout' }
    const { result } = montar(() => usePromocionesListQuery())
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeUndefined()
  })

  it('un error al leer las reglas se ve como error en el PromoMap', async () => {
    falla = { table: 'promocion_reglas', message: 'canceling statement due to statement timeout' }
    const { result } = montar(() => usePromoMapQuery())
    await waitFor(() => expect(result.current.isError).toBe(true))
  })
})
