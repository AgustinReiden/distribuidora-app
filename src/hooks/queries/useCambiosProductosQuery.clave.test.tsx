/**
 * Rut-B8 (ola 3, T3 de #1677): el canje de productos lleva la clave del formulario.
 *
 * `registrar_cambio_producto` recibe `p_clave` y, con la misma clave y lo mismo, devuelve el
 * canje del primer intento (altas_por_clave en el server). Acá: el hook manda una clave,
 * la repite al reintentar lo mismo después de un error (la respuesta perdida, el doble
 * toque), y pide otra cuando el canje salió bien o cuando cambia lo que se canjea.
 */
import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type ErrorDeSupabase = { message: string; details?: string; hint?: string; code: string }

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
let rpcResultados: Array<{ data: unknown; error: ErrorDeSupabase | null }> = []

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResultados.shift() ?? { data: 77, error: null })
    },
    auth: { getUser: vi.fn() },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useRegistrarCambioProductoMutation, type RegistrarCambioInput } from './useCambiosProductosQuery'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const CANJE: RegistrarCambioInput = {
  clienteId: '5',
  productoDevueltoId: '1',
  cantidadDevuelta: 2,
  productoEntregadoId: '2',
  cantidadEntregada: 2,
  observaciones: 'vencido',
  motivo: 'vencimiento',
}

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const claves = () => rpcCalls.map((c) => c.args.p_clave)

beforeEach(() => {
  rpcCalls.length = 0
  rpcResultados = []
})

describe('useRegistrarCambioProductoMutation: la clave del canje', () => {
  it('manda los mismos parámetros de antes más p_clave (un uuid)', async () => {
    const { result } = renderHook(() => useRegistrarCambioProductoMutation(), { wrapper })

    const id = await result.current.mutateAsync(CANJE)

    expect(id).toBe(77)
    expect(rpcCalls).toEqual([{
      fn: 'registrar_cambio_producto',
      args: {
        p_cliente_id: 5,
        p_producto_devuelto_id: 1,
        p_cantidad_devuelta: 2,
        p_producto_entregado_id: 2,
        p_cantidad_entregada: 2,
        p_observaciones: 'vencido',
        p_motivo: 'vencimiento',
        p_clave: expect.stringMatching(UUID),
      },
    }])
  })

  it('reintentar lo mismo después de un error repite la clave', async () => {
    rpcResultados = [{ data: null, error: { message: 'Failed to fetch', code: '' } }]
    const { result } = renderHook(() => useRegistrarCambioProductoMutation(), { wrapper })

    await expect(result.current.mutateAsync(CANJE)).rejects.toBeTruthy()
    await result.current.mutateAsync(CANJE)

    expect(claves()).toHaveLength(2)
    expect(claves()[0]).toEqual(expect.stringMatching(UUID))
    expect(claves()[1]).toBe(claves()[0])
  })

  it('después de un canje que salió bien, el mismo canje otra vez lleva otra clave', async () => {
    const { result } = renderHook(() => useRegistrarCambioProductoMutation(), { wrapper })

    await result.current.mutateAsync(CANJE)
    await result.current.mutateAsync(CANJE)

    expect(claves()[1]).not.toBe(claves()[0])
  })

  it('otro contenido es otro canje: otra clave, aunque el anterior haya fallado', async () => {
    rpcResultados = [{ data: null, error: { message: 'Failed to fetch', code: '' } }]
    const { result } = renderHook(() => useRegistrarCambioProductoMutation(), { wrapper })

    await expect(result.current.mutateAsync(CANJE)).rejects.toBeTruthy()
    await result.current.mutateAsync({ ...CANJE, cantidadEntregada: 3 })

    expect(claves()[1]).not.toBe(claves()[0])
  })
})
