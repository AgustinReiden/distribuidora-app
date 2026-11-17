/**
 * STK-15 (#1542): registrar una merma y cancelar un pedido mueven los contadores
 * de los lotes (el trigger de stock baja o devuelve unidades del lote), pero
 * ninguna de las dos invalidaba `lotes`: Vencimientos seguía ofreciendo «dar de
 * baja» sobre un lote que la merma ya había vaciado.
 *
 * Las claves van escritas literal (`['lotes', sucursal, …]`) a propósito, como
 * las de `['mermas']` y `['reporte-mermas']` en usePedidosQuery: importar
 * `useLotesQuery` arrastra las demás familias de queries a estos módulos.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'u1' } } }) },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useRegistrarMermaMutation } from './useMermasQuery'
import { useCancelarPedidoMutation } from './usePedidosQuery'

const LOTES = [
  ['lotes', 2, 'producto', 72],
  ['lotes', 2, 'reporte', 14],
  ['lotes', 2, 'compra', '221'],
]
const OTRA_SUCURSAL = ['lotes', 1, 'reporte', 14]

function montar<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
  for (const clave of [...LOTES, OTRA_SUCURSAL]) qc.setQueryData(clave, [{ id: 1, cantidad_restante: 10 }])
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, ...renderHook(hook, { wrapper }) }
}

const invalidadas = (qc: QueryClient, claves: unknown[][]) =>
  claves.map(c => qc.getQueryState(c)?.isInvalidated ?? false)

describe('STK-15 · los lotes se invalidan cuando la merma o la cancelación los mueven', () => {
  beforeEach(() => {
    rpc.mockReset()
  })

  it('registrar una merma', async () => {
    rpc.mockResolvedValue({ data: { ok: true, merma: { id: 926, producto_id: 72, cantidad: 10 } }, error: null })
    const { qc, result } = montar(useRegistrarMermaMutation)
    expect(invalidadas(qc, LOTES)).toEqual([false, false, false])

    await result.current.mutateAsync({ productoId: '72', cantidad: 10, motivo: 'vencimiento' } as never)

    expect(invalidadas(qc, LOTES)).toEqual([true, true, true])
  })

  it('cancelar un pedido (devuelve unidades a sus lotes)', async () => {
    rpc.mockResolvedValue({ data: { success: true }, error: null })
    const { qc, result } = montar(useCancelarPedidoMutation)

    await result.current.mutateAsync({ pedidoId: '10', motivo: 'El cliente no lo quiso' })

    expect(invalidadas(qc, LOTES)).toEqual([true, true, true])
  })

  it('una merma que falla no invalida nada', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'el stock del producto es 3 y la baja es de 5', code: 'P0001' } })
    const { qc, result } = montar(useRegistrarMermaMutation)

    await expect(result.current.mutateAsync({ productoId: '72', cantidad: 5, motivo: 'vencimiento' } as never)).rejects.toBeTruthy()

    expect(invalidadas(qc, LOTES)).toEqual([false, false, false])
  })
})
