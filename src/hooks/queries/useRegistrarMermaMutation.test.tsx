/**
 * Tests del contrato de la merma manual (issue #518).
 *
 * EL BUG: la merma se armaba con tres requests desde el navegador — INSERT en
 * `mermas_stock`, `UPDATE productos SET stock = <absoluto>` con el valor que el
 * modal había calculado sobre su snapshot, y un DELETE compensatorio a mano si
 * el segundo fallaba. Dos mermas de 10 sobre stock 100 escribían las dos
 * `stock = 90`: dos filas por 20 unidades y el stock bajo 10. Rompe STK-A.
 *
 * Lo que fijan estos tests es la mitad del cliente: que viaje la CANTIDAD por
 * la RPC y que el navegador no escriba `productos` ni `mermas_stock` nunca más.
 * La otra mitad — el `FOR UPDATE` y el `stock = stock - N` — vive en la mig 232
 * y se verificó contra la base: dos bajas de 10 sobre 100 dejan 80 y dos filas.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
/** Cualquier uso de `.from()` es una regresión: la merma ya no escribe tablas. */
const fromCalls: string[] = []
let rpcResult: { data: unknown; error: { message: string } | null } = {
  data: { ok: true, merma: { id: 926, producto_id: 72, cantidad: 10 } },
  error: null,
}

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    from: (tabla: string) => {
      fromCalls.push(tabla)
      throw new Error(`la merma no debería tocar la tabla ${tabla}`)
    },
    auth: { getUser: vi.fn() },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useRegistrarMermaMutation } from './useMermasQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return renderHook(() => useRegistrarMermaMutation(), { wrapper: makeWrapper(qc) })
}

describe('registrar una merma manual — contrato con el servidor', () => {
  beforeEach(() => {
    rpcCalls.length = 0
    fromCalls.length = 0
    rpcResult = {
      data: { ok: true, merma: { id: 926, producto_id: 72, cantidad: 10 } },
      error: null,
    }
  })

  it('manda la cantidad por la RPC, nunca un stock absoluto', async () => {
    const { result } = setup()

    await result.current.mutateAsync({
      productoId: '72',
      cantidad: 10,
      motivo: 'rotura',
      observaciones: 'se cayó el pallet',
    })

    await waitFor(() => expect(rpcCalls).toHaveLength(1))
    expect(rpcCalls[0].fn).toBe('registrar_merma_manual')
    expect(rpcCalls[0].args).toEqual({
      p_producto_id: '72',
      p_cantidad: 10,
      p_motivo: 'rotura',
      p_observaciones: 'se cayó el pallet',
      p_sucursal_id: 2,
    })

    // El saldo resultante no se calcula acá: no viaja ningún stock.
    const claves = Object.keys(rpcCalls[0].args).join(' ')
    expect(claves).not.toMatch(/stock/i)
    // Ni el usuario: `usuario_id` es `auth.uid()` server-side (MERMA-I).
    expect(claves).not.toMatch(/usuario/i)
  })

  it('no escribe ninguna tabla desde el navegador (ni mermas_stock ni productos)', async () => {
    const { result } = setup()

    await result.current.mutateAsync({ productoId: '72', cantidad: 3, motivo: 'vencimiento' })

    expect(fromCalls).toEqual([])
    expect(rpcCalls).toHaveLength(1)
  })

  it('sin observaciones manda null, no undefined ni cadena vacía', async () => {
    const { result } = setup()

    await result.current.mutateAsync({ productoId: '72', cantidad: 1, motivo: 'robo' })

    expect(rpcCalls[0].args.p_observaciones).toBeNull()
  })

  it('propaga el error del servidor en vez de compensar a mano', async () => {
    rpcResult = { data: null, error: { message: 'El stock del producto es 3 y la baja es de 5' } }
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ productoId: '72', cantidad: 5, motivo: 'rotura' }),
    ).rejects.toThrow(/el stock del producto es 3/i)

    // Sin DELETE compensatorio: la transacción del servidor ya deshizo todo.
    expect(fromCalls).toEqual([])
  })

  it('devuelve la merma que creó el servidor, con el id y el costo congelado', async () => {
    rpcResult = {
      data: { ok: true, merma: { id: 926, producto_id: 72, cantidad: 10, costo_unitario: 3077.3 }, stock: 80 },
      error: null,
    }
    const { result } = setup()

    const res = await result.current.mutateAsync({ productoId: '72', cantidad: 10, motivo: 'rotura' })

    expect(res.success).toBe(true)
    expect(res.merma).toMatchObject({ id: 926, costo_unitario: 3077.3 })
  })
})
