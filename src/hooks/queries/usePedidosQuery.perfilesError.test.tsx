/**
 * #1598 (1598-b7): las lecturas de pedidos para los modales masivos (no entregados,
 * entrega y pago, no pagados) traían el nombre del chofer con una consulta a `perfiles`
 * y no miraban su error: si fallaba, la lista salía igual con el chofer en blanco y sin
 * ningún aviso. La lista paginada ya lo hacía bien (FRT-8): el error sube.
 *
 * H2 de la revisión de C7: sólo «no entregados» muestra el chofer. «Entrega y pago» y «no pagados» no lo
 * muestran, así que no lo piden: un fallo de `perfiles` no tiene por qué tirarles la lista.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

/** Cuántas veces se le pidió algo a la tabla `perfiles`. */
let consultasAPerfiles = 0
const pedidoDeConsultasAPerfiles = (): number => consultasAPerfiles
const resultados = {
  pedidos: { data: [] as unknown[], error: null as unknown },
  perfiles: { data: [] as unknown[], error: null as unknown },
}

/** Builder de supabase-js: cualquier método encadena y `await` devuelve el resultado fijado. */
function builderDe(clave: keyof typeof resultados) {
  const proxy: unknown = new Proxy({}, {
    get: (_t, prop: string) => {
      if (prop === 'then') {
        return (resolve: (v: unknown) => unknown) => resolve(resultados[clave])
      }
      return () => proxy
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      if (tabla === 'pedidos') return builderDe('pedidos')
      if (tabla === 'perfiles') { consultasAPerfiles++; return builderDe('perfiles') }
      throw new Error(`tabla inesperada: ${tabla}`)
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  usePedidosNoEntregadosQuery,
  usePedidosParaEntregaYPagoQuery,
  usePedidosNoPagadosQuery,
} from './usePedidosQuery'

const PEDIDO = { id: 10, estado: 'pendiente', estado_pago: 'pendiente', canal: 'app', transportista_id: 't1', total: 1000 }

function montar<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderHook(hook, {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
}

beforeEach(() => {
  consultasAPerfiles = 0
  resultados.pedidos = { data: [PEDIDO], error: null }
  resultados.perfiles = { data: [{ id: 't1', nombre: 'Beto', email: 'beto@x.com' }], error: null }
})

describe('pedidos no entregados — consulta de perfiles del chofer (se muestra)', () => {
  const useLectura = () => usePedidosNoEntregadosQuery(true)

  it('con todo bien, el pedido sale con el nombre del chofer', async () => {
    const { result } = montar(useLectura)
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data![0].transportista?.nombre).toBe('Beto')
  })

  it('si falla la consulta de perfiles, la lectura falla (no sale con el chofer en blanco)', async () => {
    resultados.perfiles = { data: [], error: { message: 'Failed to fetch' } }
    const { result } = montar(useLectura)

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeUndefined()
  })
})

describe.each([
  ['pedidos para entrega y pago', () => usePedidosParaEntregaYPagoQuery(true)],
  ['pedidos no pagados', () => usePedidosNoPagadosQuery(true)],
] as const)('%s — no muestran el chofer', (_nombre, hook) => {
  it('no piden perfiles: si esa consulta falla, la lista sale igual', async () => {
    resultados.perfiles = { data: [], error: { message: 'Failed to fetch' } }
    const { result } = montar(hook)

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toHaveLength(1)
    expect(pedidoDeConsultasAPerfiles()).toBe(0)
  })
})
