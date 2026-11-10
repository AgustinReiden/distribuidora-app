/**
 * FRT-5 (#1517): el tile "Impagos" sumaba el TOTAL entero de los pedidos con pago
 * parcial. `fetchPedidoStats` no pedía `monto_pagado`: una boleta de $1.000 con
 * $600 cobrados aportaba $1.000 a la deuda en vez de los $400 que faltan.
 *
 * El conteo no cambia (una boleta parcial sigue siendo impaga, como en el filtro
 * de la lista): lo que se corrige es el monto.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const from = vi.fn()
const select = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { from: (...args: unknown[]) => from(...args) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePedidoStatsQuery } from './usePedidoStatsQuery'

interface FilaFake {
  estado: string
  estado_pago: string | null
  total: number
  monto_pagado: number | null
  tipo_factura?: string | null
}

function tabla(filas: FilaFake[]) {
  const builder: Record<string, unknown> = {}
  const encadenable = () => builder
  builder.select = (columnas: string) => { select(columnas); return builder }
  for (const m of ['order', 'eq', 'gte', 'lte', 'or', 'in', 'not']) builder[m] = encadenable
  builder.range = () => Promise.resolve({ data: filas, error: null })
  return builder
}

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderHook(() => usePedidoStatsQuery(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('usePedidoStatsQuery — "Impagos" suma lo que falta (FRT-5)', () => {
  it('una boleta de $1.000 con $600 cobrados suma $400, no $1.000', async () => {
    from.mockImplementation(() => tabla([
      { estado: 'entregado', estado_pago: 'parcial', total: 1000, monto_pagado: 600 },
    ]))
    const { result } = montar()
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(result.current.data!.impagos.count).toBe(1)
    expect(result.current.data!.impagos.monto).toBe(400)
  })

  it('una boleta sin cobros suma el total, y una sin dato de cobro (null) también', async () => {
    from.mockImplementation(() => tabla([
      { estado: 'pendiente', estado_pago: 'pendiente', total: 1000, monto_pagado: 0 },
      { estado: 'pendiente', estado_pago: null, total: 500, monto_pagado: null },
    ]))
    const { result } = montar()
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(result.current.data!.impagos.count).toBe(2)
    expect(result.current.data!.impagos.monto).toBe(1500)
  })

  it('un cobro de más no resta deuda de las otras boletas', async () => {
    from.mockImplementation(() => tabla([
      { estado: 'entregado', estado_pago: 'parcial', total: 1000, monto_pagado: 1200 },
      { estado: 'entregado', estado_pago: 'pendiente', total: 300, monto_pagado: 0 },
    ]))
    const { result } = montar()
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(result.current.data!.impagos.monto).toBe(300)
  })

  it('el monto de los otros tiles sigue siendo la venta, sin descontar cobros', async () => {
    from.mockImplementation(() => tabla([
      { estado: 'entregado', estado_pago: 'parcial', total: 1000, monto_pagado: 600 },
    ]))
    const { result } = montar()
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(result.current.data!.entregados.monto).toBe(1000)
    expect(result.current.data!.total.monto).toBe(1000)
  })

  it('pide la columna monto_pagado (sin ella no hay cómo restar lo cobrado)', async () => {
    from.mockImplementation(() => tabla([]))
    const { result } = montar()
    await waitFor(() => expect(result.current.isPlaceholderData).toBe(false))

    expect(select).toHaveBeenCalled()
    expect(String(select.mock.calls[0][0])).toContain('monto_pagado')
  })
})
