/**
 * #1303 (PLT-N3): el replay le pone un plazo a cada alta, y el plazo tiene que
 * cortar los requests de verdad. `setSucursalHeader` se lee cuando sale el fetch:
 * un reintento de la mutation que saliera después de vencido el plazo podría
 * llevar el header de otra operación. Con la señal abortada no sale.
 *
 * Con el cliente real: la señal importa recién donde llega al `fetch`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type Init = NonNullable<Parameters<typeof fetch>[1]>

const red = vi.hoisted(() => ({
  pedidos: [] as Array<{ url: string; init: Init }>,
  responder: (async () => new Response('{}')) as (url: string, init: Init) => Promise<Response>,
}))

vi.mock('../supabase/base', async () => {
  const { createClient } = await import('@supabase/supabase-js')
  return {
    supabase: createClient('https://proyecto.supabase.co', 'anon-key', {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        fetch: ((url: string, init: Init) => {
          red.pedidos.push({ url: String(url), init })
          return red.responder(String(url), init)
        }) as typeof fetch,
      },
    }),
  }
})

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearPedidoMutation } from './usePedidosQuery'

const INPUT = {
  clienteId: '7',
  total: 1000,
  usuarioId: 'u1',
  items: [{ productoId: '3', cantidad: 1, precioUnitario: 1000 }],
  offlineId: 'uuid-1',
  origenes: [{ producto_id: '3', es_bonificacion: false, origen_precio: 'lista' }],
}

type Alta = Parameters<ReturnType<typeof useCrearPedidoMutation>['mutateAsync']>[0]

function mutacion() {
  const qc = new QueryClient()
  return renderHook(() => useCrearPedidoMutation(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  }).result
}

function json(cuerpo: unknown): Response {
  return new Response(JSON.stringify(cuerpo), { status: 200 })
}

beforeEach(() => {
  red.pedidos.length = 0
})

describe('crearPedido con señal', () => {
  it('el alta lleva la señal hasta el fetch', async () => {
    red.responder = async () => json({ success: true, pedido_id: '501' })
    const { signal } = new AbortController()
    const result = mutacion()

    await act(async () => { await result.current.mutateAsync({ ...INPUT, signal } as Alta) })

    const alta = red.pedidos.find(p => p.url.includes('crear_pedido_idempotente'))!
    expect(alta.init.signal).toBe(signal)
  })

  it('la rama idempotente también: la lectura y el registro de orígenes', async () => {
    red.responder = async (url) => {
      if (url.includes('crear_pedido_idempotente')) return json({ success: true, pedido_id: '501', idempotente: true })
      if (url.includes('/pedidos')) return json({ cliente_id: 7, total: 1000, cargo_envio: 0 })
      return json(null)
    }
    const { signal } = new AbortController()
    const result = mutacion()

    await act(async () => { await result.current.mutateAsync({ ...INPUT, signal } as Alta) })

    expect(red.pedidos.map(p => p.url.split('/').pop()?.split('?')[0])).toEqual([
      'crear_pedido_idempotente',
      'pedidos',
      'registrar_origen_precio_items',
    ])
    for (const pedido of red.pedidos) expect(pedido.init.signal).toBe(signal)
  })

  it('el alta online no lleva ninguna: su espera no cambia', async () => {
    red.responder = async () => json({ success: true, pedido_id: '501' })
    const result = mutacion()

    await act(async () => { await result.current.mutateAsync(INPUT as Alta) })

    expect(red.pedidos[0].init.signal).toBeUndefined()
  })
})
