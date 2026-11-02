/**
 * El PromoMap de un pedido que se edita (#1300, PRM-N4).
 *
 * `fetchPromoMap` filtra `activo = true`, y una promo se apaga sola al llegar a
 * su límite: el pedido que completó el cupo perdía el regalo al editarlo. Las
 * promos de las que el pedido ya tiene regalo entran igual, y sólo ésas: en un
 * alta, una promo apagada sigue sin resolver.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Call { table: string; in?: [string, unknown[]] }

const calls: Call[] = []
const promoActiva = { id: 1, nombre: 'Activa', tipo: 'bonificacion', activo: true }
const promoApagada = { id: 13, nombre: 'Apagada por el límite', tipo: 'bonificacion', activo: false }

function builderFor(table: string) {
  const call: Call = { table }
  const b = {
    select: () => b,
    eq: () => b,
    lte: () => b,
    or: () => b,
    in: (col: string, vals: unknown[]) => { call.in = [col, vals]; return b },
    then(onFulfilled: (v: unknown) => unknown) {
      calls.push(call)
      return Promise.resolve(resultFor(call)).then(onFulfilled)
    },
  }
  return b
}

function resultFor(call: Call): { data: unknown; error: null } {
  if (call.table === 'promociones') {
    return { data: call.in ? [promoApagada] : [promoActiva], error: null }
  }
  if (call.table === 'promocion_productos') {
    return {
      data: [{ promocion_id: 1, producto_id: 10 }, { promocion_id: 13, producto_id: 20 }],
      error: null,
    }
  }
  return { data: [], error: null }
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (table: string) => builderFor(table) },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { promocionesKeys, usePromoMapQuery } from './usePromocionesQuery'

const montar = (promosDelPedido?: readonly string[]) => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  )
  return renderHook(() => usePromoMapQuery(undefined, promosDelPedido), { wrapper })
}

describe('usePromoMapQuery con las promos del pedido (#1300)', () => {
  beforeEach(() => { calls.length = 0 })

  it('sin pedido no pide promos por id: una apagada no resuelve', async () => {
    const { result } = montar()
    await waitFor(() => expect(result.current.data).toBeDefined())
    expect(result.current.data?.has('10')).toBe(true)
    expect(result.current.data?.has('20')).toBe(false)
    expect(calls.filter(c => c.table === 'promociones' && c.in)).toEqual([])
  })

  it('la promo apagada de la que el pedido tiene regalo sigue resolviendo', async () => {
    const { result } = montar(['13'])
    await waitFor(() => expect(result.current.data).toBeDefined())
    expect(result.current.data?.get('20')?.[0].id).toBe('13')
    expect(result.current.data?.has('10')).toBe(true)
  })

  it('una promo del pedido que sigue activa no se pide dos veces', async () => {
    const { result } = montar(['1'])
    await waitFor(() => expect(result.current.data).toBeDefined())
    expect(calls.filter(c => c.table === 'promociones' && c.in)).toEqual([])
    expect(result.current.data?.get('10')).toHaveLength(1)
  })

  it('cada pedido cachea aparte, y el alta conserva su clave', () => {
    expect(promocionesKeys.promoMap(1, undefined, ['13']))
      .not.toEqual(promocionesKeys.promoMap(1, undefined, ['14']))
    expect(promocionesKeys.promoMap(1, undefined, [])).toEqual(promocionesKeys.promoMap(1))
  })
})
