/**
 * frv-B8 (tanda 6 de #1603): con «Ver cancelados» activo, la tarjeta «Total» de Pedidos contaba los
 * cancelados (sumaban monto 0) y el conteo no cerraba con las demás tarjetas. Un cancelado no es
 * venta ni deuda: no entra en «Total» ni en «Impagos».
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const from = vi.fn()

vi.mock('../supabase/base', () => ({ supabase: { from: (...args: unknown[]) => from(...args) } }))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { usePedidoStatsQuery } from './usePedidoStatsQuery'

describe('usePedidoStatsQuery — cancelados (frv-B8)', () => {
  it('«Total» e «Impagos» no cuentan los cancelados; el resto sigue igual', async () => {
    const filas = [
      { id: 1, estado: 'pendiente', estado_pago: 'pendiente', total: 100, monto_pagado: 0, tipo_factura: 'ZZ' },
      { id: 2, estado: 'entregado', estado_pago: 'pagado', total: 200, monto_pagado: 200, tipo_factura: 'ZZ' },
      { id: 3, estado: 'cancelado', estado_pago: 'pendiente', total: 0, monto_pagado: 0, tipo_factura: 'ZZ' },
      { id: 4, estado: 'cancelado', estado_pago: 'pagado', total: 0, monto_pagado: 0, tipo_factura: 'FC' },
    ]
    const builder: Record<string, unknown> = {}
    const encadenable = () => builder
    for (const m of ['select', 'order', 'eq', 'gte', 'lte', 'or', 'in', 'not']) builder[m] = encadenable
    builder.range = () => Promise.resolve({ data: filas, error: null })
    from.mockImplementation(() => builder)

    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const wrapper = ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper })
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    const s = result.current.data!
    expect(s.total).toEqual({ count: 2, monto: 300 })
    expect(s.pendientes.count + s.enPreparacion.count + s.enCamino.count + s.entregados.count).toBe(s.total.count)
    expect(s.impagos).toEqual({ count: 1, monto: 100 })
  })
})
