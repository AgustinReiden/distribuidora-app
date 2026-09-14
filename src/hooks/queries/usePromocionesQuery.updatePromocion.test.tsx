/**
 * `updatePromocion` reemplazaba productos y reglas con un DELETE (sin
 * capturar el error) seguido de un INSERT, sin transacción. Si el INSERT
 * fallaba, la promo quedaba activa pero sin productos ni reglas: dejaba de
 * bonificar y nadie se enteraba.
 *
 * El fix reconcilia contra lo existente (altas y bajas), como
 * `updateGrupoPrecio`: sólo se borra lo que ya no se quiere, así que una fila
 * que sigue queriéndose nunca pasa por un DELETE, y cualquier error de
 * cualquier paso corta la mutación en vez de seguir de largo.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Call {
  table: string
  op: string
  payload?: unknown
  eq?: [string, unknown]
  in?: [string, unknown[]]
}

const calls: Call[] = []

let productosActuales: Array<{ id: string; producto_id: string }> = []
let reglasActuales: Array<{ id: string; clave: string }> = []
let productosDeleteError: { message: string } | null = null
let productosInsertError: { message: string } | null = null
let reglasUpsertError: { message: string } | null = null

function builderFor(table: string) {
  const call: Call = { table, op: '' }
  const b = {
    update: (payload: unknown) => { call.op = 'update'; call.payload = payload; return b },
    delete: () => { call.op = 'delete'; return b },
    insert: (rows: unknown) => { call.op = 'insert'; call.payload = rows; return b },
    upsert: (rows: unknown) => { call.op = 'upsert'; call.payload = rows; return b },
    select: (cols: string) => { if (!call.op) call.op = 'select'; call.payload = cols; return b },
    eq: (col: string, val: unknown) => { call.eq = [col, val]; return b },
    in: (col: string, vals: unknown[]) => { call.in = [col, vals]; return b },
    single: () => b,
    then(onFulfilled: (v: unknown) => unknown, onRejected?: (e: unknown) => unknown) {
      calls.push(call)
      return Promise.resolve(resultFor(table, call)).then(onFulfilled, onRejected)
    },
  }
  return b
}

function resultFor(table: string, call: Call): { data: unknown; error: unknown } {
  if (table === 'promociones' && call.op === 'update') {
    return { data: { id: '5', nombre: 'Promo test' }, error: null }
  }
  if (table === 'promocion_productos') {
    if (call.op === 'select' && call.payload === 'id, producto_id') {
      return { data: productosActuales, error: null }
    }
    if (call.op === 'delete') {
      return { data: null, error: productosDeleteError }
    }
    if (call.op === 'insert') {
      return { data: null, error: productosInsertError }
    }
    // Fetch final (`select('*')`)
    return { data: [], error: null }
  }
  if (table === 'promocion_reglas') {
    if (call.op === 'select' && call.payload === 'id, clave') {
      return { data: reglasActuales, error: null }
    }
    if (call.op === 'delete') {
      return { data: null, error: null }
    }
    if (call.op === 'upsert') {
      return { data: null, error: reglasUpsertError }
    }
    return { data: [], error: null }
  }
  return { data: null, error: null }
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (table: string) => builderFor(table) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useActualizarPromocionMutation } from './usePromocionesQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return renderHook(() => useActualizarPromocionMutation(), { wrapper: makeWrapper(qc) })
}

const INPUT_BASE = {
  nombre: 'Promo test',
  tipo: 'bonificacion' as const,
  fechaInicio: '2026-01-01',
  productoIds: ['1', '2'],
  reglas: [{ clave: 'cantidad_compra', valor: 6 }],
}

describe('updatePromocion — reconciliación de productos y reglas', () => {
  beforeEach(() => {
    calls.length = 0
    productosDeleteError = null
    productosInsertError = null
    reglasUpsertError = null
  })

  it('un producto que sigue queriéndose nunca pasa por un DELETE', async () => {
    // Ya está el producto 1; el form pide 1 y 2 (se agrega el 2).
    productosActuales = [{ id: 'pp1', producto_id: '1' }]
    reglasActuales = [{ id: 'pr1', clave: 'cantidad_compra' }]

    const { result } = setup()
    await result.current.mutateAsync({ id: '5', data: INPUT_BASE })

    const deleteProductos = calls.filter(c => c.table === 'promocion_productos' && c.op === 'delete')
    expect(deleteProductos).toHaveLength(0)
    const insertProductos = calls.filter(c => c.table === 'promocion_productos' && c.op === 'insert')
    expect(insertProductos).toHaveLength(1)
    expect(insertProductos[0].payload).toEqual([{ promocion_id: 5, producto_id: 2 }])
  })

  it('si falla el alta de un producto nuevo, la mutación rechaza y el error no se traga', async () => {
    productosActuales = [{ id: 'pp1', producto_id: '1' }]
    reglasActuales = []
    productosInsertError = { message: 'network error' }

    const { result } = setup()
    await expect(
      result.current.mutateAsync({ id: '5', data: INPUT_BASE }),
    ).rejects.toMatchObject({ message: 'network error' })

    // El producto 1, que seguía queriéndose, nunca se tocó: no hubo DELETE.
    const deleteProductos = calls.filter(c => c.table === 'promocion_productos' && c.op === 'delete')
    expect(deleteProductos).toHaveLength(0)
  })

  it('si el DELETE de productos sobrantes falla, se captura en vez de seguir al INSERT', async () => {
    // El form ya no quiere el producto 3: hace falta un DELETE.
    productosActuales = [{ id: 'pp1', producto_id: '1' }, { id: 'pp3', producto_id: '3' }]
    reglasActuales = []
    productosDeleteError = { message: 'permission denied' }

    const { result } = setup()
    await expect(
      result.current.mutateAsync({ id: '5', data: INPUT_BASE }),
    ).rejects.toMatchObject({ message: 'permission denied' })

    // El INSERT del producto 2 nuevo no debería haberse intentado: el DELETE
    // que lo precede falló y antes ese error se ignoraba en silencio.
    const insertProductos = calls.filter(c => c.table === 'promocion_productos' && c.op === 'insert')
    expect(insertProductos).toHaveLength(0)
  })

  it('las reglas existentes se actualizan con upsert, sin pasar por un DELETE cuando la clave se mantiene', async () => {
    productosActuales = [{ id: 'pp1', producto_id: '1' }, { id: 'pp2', producto_id: '2' }]
    reglasActuales = [{ id: 'pr1', clave: 'cantidad_compra' }]

    const { result } = setup()
    await result.current.mutateAsync({
      id: '5',
      data: { ...INPUT_BASE, reglas: [{ clave: 'cantidad_compra', valor: 12 }] },
    })

    const deleteReglas = calls.filter(c => c.table === 'promocion_reglas' && c.op === 'delete')
    expect(deleteReglas).toHaveLength(0)
    const upsertReglas = calls.filter(c => c.table === 'promocion_reglas' && c.op === 'upsert')
    expect(upsertReglas).toHaveLength(1)
    expect(upsertReglas[0].payload).toEqual([{ promocion_id: 5, clave: 'cantidad_compra', valor: 12 }])
  })

  it('si falla el upsert de reglas, la mutación rechaza en vez de guardar la promo sin avisar', async () => {
    productosActuales = [{ id: 'pp1', producto_id: '1' }, { id: 'pp2', producto_id: '2' }]
    reglasActuales = []
    reglasUpsertError = { message: 'constraint violation' }

    const { result } = setup()
    await expect(
      result.current.mutateAsync({ id: '5', data: INPUT_BASE }),
    ).rejects.toMatchObject({ message: 'constraint violation' })
  })
})
