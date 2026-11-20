/**
 * El filtro «Con salvedad / Sin salvedad» de Pedidos (1598-b4, #1598).
 *
 * Antes la lista pedía primero los ids de todos los pedidos con salvedad vigente
 * (`salvedades_items`) y los mandaba en la URL (`id=in.(…)`): pasados 700 ids el filtro
 * dejaba de andar. Ahora es un embed de PostgREST a `salvedades_items` con la FK por nombre
 * (trampa 5: hay dos FK a `pedidos`; sin el nombre, PGRST201 y cae TODA la lista), filtrado a
 * las vigentes: «con» con `!inner`, «sin» con el anti-join `salvedades_items=is.null`. Lo
 * embebido no llega a la pantalla.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

interface Llamada { tabla: string; metodo: string; args: unknown[] }
const llamadas: Llamada[] = []
let filasPedidos: unknown[] = []

/** Builder de supabase-js: anota cada llamada y `await` devuelve las filas fijadas. */
function builderDe(tabla: string) {
  const proxy: unknown = new Proxy({}, {
    get: (_t, prop: string) => {
      if (prop === 'then') {
        const data = tabla === 'pedidos' ? filasPedidos : []
        return (resolve: (v: unknown) => unknown) => resolve({ data, error: null, count: data.length })
      }
      return (...args: unknown[]) => {
        llamadas.push({ tabla, metodo: prop, args })
        return proxy
      }
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (tabla: string) => builderDe(tabla) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePedidosPaginatedQuery, PEDIDO_SELECT } from './usePedidosQuery'
import { usePedidoStatsQuery } from './usePedidoStatsQuery'

type ValorSalvedad = 'todos' | 'con_salvedad' | 'sin_salvedad'

function envolver() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const montarLista = (conSalvedad: ValorSalvedad, busqueda?: string) =>
  renderHook(() => usePedidosPaginatedQuery(1, 15, { conSalvedad }, busqueda), { wrapper: envolver() })

const montarTarjetas = (conSalvedad: ValorSalvedad) =>
  renderHook(() => usePedidoStatsQuery({ conSalvedad }), { wrapper: envolver() })

const sobrePedidos = (metodo: string) => llamadas.filter(l => l.tabla === 'pedidos' && l.metodo === metodo)

const CON = ',salvedades_items!salvedades_items_pedido_id_fkey!inner(id)'
const SIN = ',salvedades_items!salvedades_items_pedido_id_fkey(id)'
const VIGENTES = { tabla: 'pedidos', metodo: 'neq', args: ['salvedades_items.estado_resolucion', 'anulada'] }
const ANTIJOIN = { tabla: 'pedidos', metodo: 'is', args: ['salvedades_items', null] }

beforeEach(() => {
  llamadas.length = 0
  filasPedidos = []
})

describe('lista de pedidos: filtro con/sin salvedad (1598-b4)', () => {
  it('«Con salvedad» suma el embed !inner con la FK por nombre y lo filtra a las vigentes', async () => {
    const { result } = montarLista('con_salvedad')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('select')[0].args[0]).toBe(PEDIDO_SELECT + CON)
    expect(sobrePedidos('select')[0].args[1]).toEqual({ count: 'exact' })
    expect(sobrePedidos('neq')).toContainEqual(VIGENTES)
    expect(sobrePedidos('is')).not.toContainEqual(ANTIJOIN)
    // Ni ids en la URL ni la vuelta previa a salvedades_items para armarlos.
    expect(sobrePedidos('in').filter(l => l.args[0] === 'id')).toEqual([])
    expect(sobrePedidos('not').filter(l => l.args[0] === 'id')).toEqual([])
    expect(llamadas.filter(l => l.tabla === 'salvedades_items')).toEqual([])
  })

  it('«Sin salvedad» es el anti-join: embed sin !inner, vigentes y salvedades_items=is.null', async () => {
    const { result } = montarLista('sin_salvedad')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('select')[0].args[0]).toBe(PEDIDO_SELECT + SIN)
    expect(sobrePedidos('neq')).toContainEqual(VIGENTES)
    expect(sobrePedidos('is')).toContainEqual(ANTIJOIN)
    expect(llamadas.filter(l => l.tabla === 'salvedades_items')).toEqual([])
  })

  it('«Todos» no embebe ni filtra salvedades', async () => {
    const { result } = montarLista('todos')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('select')[0].args[0]).toBe(PEDIDO_SELECT)
    expect(sobrePedidos('neq').filter(l => String(l.args[0]).startsWith('salvedades_items'))).toEqual([])
    expect(sobrePedidos('is').filter(l => l.args[0] === 'salvedades_items')).toEqual([])
  })

  it('con la búsqueda, el embed va sobre el select con el cliente !inner, y combina con el orden y la página', async () => {
    const { result } = montarLista('con_salvedad', 'Kiosco')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    const select = String(sobrePedidos('select')[0].args[0])
    expect(select).toContain('cliente:clientes!inner(')
    expect(select.endsWith(CON)).toBe(true)
    expect(sobrePedidos('or').some(l => String(l.args[0]).includes('Kiosco'))).toBe(true)
    expect(sobrePedidos('order').map(l => l.args[0])).toEqual(['created_at', 'id'])
    expect(sobrePedidos('range')).toEqual([{ tabla: 'pedidos', metodo: 'range', args: [0, 14] }])
  })

  it('lo que trae el embed no llega a la lista', async () => {
    filasPedidos = [{ id: 7, estado: 'pendiente', salvedades_items: [{ id: 99 }] }]
    const { result } = montarLista('con_salvedad')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data?.data[0].id).toBe(7)
    expect(result.current.data?.data[0]).not.toHaveProperty('salvedades_items')
  })
})

describe('tarjetas de totales: el mismo filtro (1598-b4)', () => {
  const SELECT_TARJETAS = 'estado, estado_pago, total, monto_pagado, cargo_envio, tipo_factura'

  it('«Con salvedad»: el mismo embed y el mismo filtro que la lista', async () => {
    const { result } = montarTarjetas('con_salvedad')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('select')[0].args[0]).toBe(SELECT_TARJETAS + CON)
    expect(sobrePedidos('neq')).toContainEqual(VIGENTES)
    expect(llamadas.filter(l => l.tabla === 'salvedades_items')).toEqual([])
  })

  it('«Sin salvedad»: el anti-join', async () => {
    const { result } = montarTarjetas('sin_salvedad')
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(sobrePedidos('select')[0].args[0]).toBe(SELECT_TARJETAS + SIN)
    expect(sobrePedidos('is')).toContainEqual(ANTIJOIN)
  })
})
