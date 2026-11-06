/**
 * `updatePromocion` guarda la promo en UNA llamada (#1491).
 *
 * Desde la 467 (#1473) el regalo y el contenedor iban por la RPC
 * `cambiar_regalo_promocion` y el resto por un UPDATE REST, en dos
 * transacciones: si fallaba el UPDATE (el contenedor sin stock para el factor
 * nuevo, el límite debajo de lo ya regalado, la red), el regalo nuevo ya había
 * quedado. Antes de eso, los productos y las reglas se reconciliaban en otras
 * cuatro llamadas REST, cada una con su propio "a medias".
 *
 * Ahora la RPC recibe todo en `p_datos` y concilia productos y reglas en la
 * misma transacción: el front no escribe nada por REST, y un rechazo del
 * servidor llega con su mensaje y no deja nada guardado.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Call {
  table: string
  op: string
  payload?: unknown
}

const calls: Call[] = []

function builderFor(table: string) {
  const call: Call = { table, op: '' }
  const b = {
    update: (payload: unknown) => { call.op = 'update'; call.payload = payload; return b },
    delete: () => { call.op = 'delete'; return b },
    insert: (rows: unknown) => { call.op = 'insert'; call.payload = rows; return b },
    upsert: (rows: unknown) => { call.op = 'upsert'; call.payload = rows; return b },
    select: (cols: string) => { if (!call.op) { call.op = 'select'; call.payload = cols } return b },
    eq: () => b,
    in: () => b,
    single: () => b,
    then(onFulfilled: (v: unknown) => unknown, onRejected?: (e: unknown) => unknown) {
      calls.push(call)
      const data = table === 'promocion_productos'
        ? [{ id: 'pp1', promocion_id: '5', producto_id: '1' }]
        : [{ id: 'pr1', promocion_id: '5', clave: 'cantidad_compra', valor: 6 }]
      return Promise.resolve({ data, error: null }).then(onFulfilled, onRejected)
    },
  }
  return b
}

const PROMO_GUARDADA = { id: '5', nombre: 'Promo test', usos_pendientes: 3 }
let rpcResultado: { data: unknown; error: unknown } = { data: { success: true, promocion: PROMO_GUARDADA }, error: null }
function rpcFor(fn: string, args: unknown) {
  calls.push({ table: `rpc:${fn}`, op: 'rpc', payload: args })
  return Promise.resolve(rpcResultado)
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (table: string) => builderFor(table), rpc: (fn: string, args: unknown) => rpcFor(fn, args) },
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

const escrituras = () => calls.filter(c => ['update', 'insert', 'upsert', 'delete'].includes(c.op))

describe('updatePromocion — la promo se guarda en una sola llamada', () => {
  beforeEach(() => {
    calls.length = 0
    rpcResultado = { data: { success: true, promocion: PROMO_GUARDADA }, error: null }
  })

  it('manda todo a la RPC una vez, con el regalo, el contenedor, el factor, los productos y las reglas', async () => {
    const { result } = setup()
    await result.current.mutateAsync({
      id: '5',
      data: {
        ...INPUT_BASE, productoRegaloId: '9', ajusteProductoId: '11', ajusteAutomatico: true,
        unidadesPorBloque: 6, stockPorBloque: 1, limiteUsos: 40, fechaFin: '2026-02-01',
        prioridad: 2, regaloMueveStock: true, modoExclusion: 'excluyente', descripcionRegalo: 'un fardo',
      },
    })

    const rpcs = calls.filter(c => c.op === 'rpc')
    expect(rpcs).toHaveLength(1)
    expect(rpcs[0].table).toBe('rpc:cambiar_regalo_promocion')
    expect(rpcs[0].payload).toEqual({
      p_promocion_id: 5,
      p_producto_regalo_id: 9,
      p_ajuste_producto_id: 11,
      p_ajuste_automatico: true,
      p_datos: {
        nombre: 'Promo test',
        tipo: 'bonificacion',
        fecha_inicio: '2026-01-01',
        fecha_fin: '2026-02-01',
        limite_usos: 40,
        prioridad: 2,
        regalo_mueve_stock: true,
        modo_exclusion: 'excluyente',
        unidades_por_bloque: 6,
        stock_por_bloque: 1,
        descripcion_regalo: 'un fardo',
        producto_ids: [1, 2],
        reglas: [{ clave: 'cantidad_compra', valor: 6 }],
      },
    })
  })

  it('no escribe nada por REST: ni la promo, ni sus productos, ni sus reglas', async () => {
    const { result } = setup()
    await result.current.mutateAsync({ id: '5', data: { ...INPUT_BASE, productoRegaloId: '9' } })

    expect(escrituras()).toHaveLength(0)
  })

  it('sin regalo ni contenedor manda null, y los valores por defecto de lo que no vino', async () => {
    const { result } = setup()
    await result.current.mutateAsync({ id: '5', data: { ...INPUT_BASE, productoIds: [], reglas: [] } })

    const rpc = calls.find(c => c.op === 'rpc')
    expect(rpc?.payload).toMatchObject({
      p_producto_regalo_id: null,
      p_ajuste_producto_id: null,
      p_ajuste_automatico: false,
      p_datos: {
        fecha_fin: null, limite_usos: null, prioridad: 0, regalo_mueve_stock: false, modo_exclusion: 'acumulable',
        unidades_por_bloque: null, stock_por_bloque: null, descripcion_regalo: null, producto_ids: [], reglas: [],
      },
    })
  })

  it('devuelve la promo que guardó el servidor, con sus productos y sus reglas', async () => {
    const { result } = setup()
    const promo = await result.current.mutateAsync({ id: '5', data: INPUT_BASE })

    expect(promo).toMatchObject({ id: '5', nombre: 'Promo test', usos_pendientes: 3 })
    expect(promo.productos).toHaveLength(1)
    expect(promo.reglas).toHaveLength(1)
  })

  it('si el servidor rechaza (el contenedor sin stock para el factor nuevo), llega su mensaje y no se toca nada más', async () => {
    const mensaje = 'El contenedor «Fardo» no tiene stock para el factor nuevo (hay 2): el cambio cierra bloques que no se pueden descontar. No se guardó ningún cambio de la promoción.'
    rpcResultado = { data: { success: false, codigo: 'contenedor_sin_stock', error: mensaje }, error: null }
    const { result } = setup()
    await expect(
      result.current.mutateAsync({ id: '5', data: { ...INPUT_BASE, productoRegaloId: '9', unidadesPorBloque: 1 } }),
    ).rejects.toMatchObject({ message: mensaje, status: 409 })

    expect(calls.filter(c => c.op !== 'rpc')).toHaveLength(0)
  })

  it('si la RPC da un error del servidor, la mutación rechaza con su mensaje y no sigue', async () => {
    rpcResultado = { data: null, error: { code: 'P0001', message: 'La promo «X» ya regaló 5 unidades: el límite no puede ser menor.' } }
    const { result } = setup()
    await expect(
      result.current.mutateAsync({ id: '5', data: { ...INPUT_BASE, limiteUsos: 1 } }),
    ).rejects.toMatchObject({ message: 'La promo «X» ya regaló 5 unidades: el límite no puede ser menor.' })

    expect(calls.filter(c => c.op !== 'rpc')).toHaveLength(0)
  })
})
