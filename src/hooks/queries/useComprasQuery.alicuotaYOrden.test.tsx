/**
 * Dos cosas que salen de esta capa y ningún otro test ve:
 *
 *  - la alícuota de cada línea que viaja a las RPCs de compra (#1274). Un exento
 *    que viaja al 21 no rompe nada, porque la RPC lo normaliza: sólo deja a las
 *    dos puntas diciendo cosas distintas;
 *  - el orden de las dos consultas que eligen "la última compra" (#1333). El
 *    `order` es un string que no ven ni tsc ni los tests de la elección pura.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { CondicionIva } from '../../utils/calculations'

const estado = vi.hoisted(() => ({
  order: [] as [string, unknown][],
  select: [] as string[],
}))
const rpc = vi.hoisted(() => vi.fn())

/** Cadena de PostgREST que anota lo que se le pide y da vacío al `await`. */
function cadena(): unknown {
  const proxy: unknown = new Proxy(() => undefined, {
    get(_t, prop) {
      if (prop === 'then') {
        return (res: (v: unknown) => unknown) => Promise.resolve({ data: [], error: null }).then(res)
      }
      return (...args: unknown[]) => {
        if (prop === 'order') estado.order.push([args[0] as string, args[1]])
        if (prop === 'select') estado.select.push(args[0] as string)
        return proxy
      }
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: () => cadena(),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'admin-1' } } }) },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  paramsActualizarCompraItems, useCompraQueFijaCostoQuery, useCostosAnterioresQuery, useRegistrarCompraMutation,
} from './useComprasQuery'
import type { ActualizarCompraItemsInput } from './useComprasQuery'

function setup<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return renderHook(hook, { wrapper })
}

/** Exento y no gravado sin porcentaje, y gravado al 10,5 y sin porcentaje. */
const CASOS: { nombre: string; condicionIva?: CondicionIva; porcentajeIva?: number; alicuota: number }[] = [
  { nombre: 'exento sin porcentaje', condicionIva: 'exento', alicuota: 0 },
  { nombre: 'no gravado sin porcentaje', condicionIva: 'no_gravado', alicuota: 0 },
  { nombre: 'gravado al 10,5', condicionIva: 'gravado', porcentajeIva: 10.5, alicuota: 10.5 },
  { nombre: 'gravado sin porcentaje', condicionIva: 'gravado', alicuota: 21 },
]

const lineas = CASOS.map((c, i) => ({
  productoId: String(i + 1), cantidad: 1, costoUnitario: 100, subtotal: 100,
  ...(c.condicionIva ? { condicionIva: c.condicionIva } : {}),
  ...(c.porcentajeIva !== undefined ? { porcentajeIva: c.porcentajeIva } : {}),
}))

beforeEach(() => {
  rpc.mockReset()
  estado.order.length = 0
  estado.select.length = 0
})

describe('la alícuota que viaja a las RPCs de compra (#1274)', () => {
  it('registrar_compra_completa recibe la que dice la condición', async () => {
    rpc.mockResolvedValue({ data: { success: true, compra_id: '226' }, error: null })
    const { result } = setup(useRegistrarCompraMutation)

    await result.current.mutateAsync({
      proveedorId: '3', proveedorNombre: null, numeroFactura: 'A0005-00461415', fechaCompra: '2026-08-19',
      subtotal: 400, iva: 0, impuestosInternos: 0, otrosImpuestos: 0, total: 400, formaPago: 'efectivo',
      notas: null, tipoFactura: 'FC', usuarioId: 'user-1', items: lineas, cargos: [], iiDeclarado: {},
    } as never)

    const [nombre, params] = rpc.mock.calls.find(c => c[0] === 'registrar_compra_completa')!
    expect(nombre).toBe('registrar_compra_completa')
    const items = params.p_items as { porcentaje_iva: number; condicion_iva: string }[]
    expect(items.map(i => i.porcentaje_iva)).toEqual(CASOS.map(c => c.alicuota))
    expect(items.map(i => i.condicion_iva)).toEqual(['exento', 'no_gravado', 'gravado', 'gravado'])
  })

  it('actualizar_compra_items recibe la misma', () => {
    const input = {
      compraId: '221', usuarioId: 'user-1', subtotal: 400, iva: 0, total: 400, items: lineas, cargos: [], iiDeclarado: {},
    } as unknown as ActualizarCompraItemsInput
    const items = paramsActualizarCompraItems(input).p_items_nuevos as { porcentaje_iva: number }[]
    expect(items.map(i => i.porcentaje_iva)).toEqual(CASOS.map(c => c.alicuota))
  })
})

describe('el orden de "la última compra" (#1333)', () => {
  const MAS_NUEVA_PRIMERO = [
    ['compra(fecha_compra)', { ascending: false }],
    ['compra(created_at)', { ascending: false }],
    ['compra_id', { ascending: false }],
  ]

  // PostgREST ordena por lo que el embed selecciona: sin `created_at` en el
  // select, `order=compra(created_at)` da 42703 y falla la consulta entera. Ni tsc
  // ni un mock lo ven, y la ficha no avisa: esa consulta falla en silencio.
  const EMBED_CON_LA_HORA = /compra:compras!inner\([^)]*\bcreated_at\b/

  it('la ficha ordena por (fecha_compra, created_at, id), como _reposicion_desde_ultima_compra', async () => {
    setup(() => useCompraQueFijaCostoQuery('7'))
    await waitFor(() => expect(estado.order.length).toBeGreaterThan(0))
    expect(estado.order).toEqual(MAS_NUEVA_PRIMERO)
    expect(estado.select[0]).toMatch(EMBED_CON_LA_HORA)
  })

  it('la compra anterior ordena igual', async () => {
    setup(() => useCostosAnterioresQuery(['7'], {
      compraId: '304', createdAt: '2026-09-12T15:30:00+00:00', fechaCompra: '2026-09-12', numeroFactura: null,
    }))
    await waitFor(() => expect(estado.order.length).toBeGreaterThan(0))
    expect(estado.order).toEqual(MAS_NUEVA_PRIMERO)
    expect(estado.select[0]).toMatch(EMBED_CON_LA_HORA)
  })
})
