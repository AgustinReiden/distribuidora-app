/**
 * El error de las cards de "Pedidos" se normaliza (#1011).
 *
 * `paginarStats` hacía `new Error(\`No se pudieron calcular los totales de
 * pedidos: ${error.message}\`)`: perdía el `code` y, sin servidor, el mensaje era
 * "...: TypeError: Failed to fetch". Con `errorDeSupabase`, el caso con servidor
 * conserva el mensaje de siempre (más el `code`) y el caso sin servidor dice que
 * no hubo conexión, sin perder de qué cálculo se trata.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { from: (...args: unknown[]) => from(...args) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { usePedidoStatsQuery } from './usePedidoStatsQuery'

const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const ERROR_DE_SERVIDOR = { message: 'canceling statement due to statement timeout', details: '', hint: '', code: '57014' }

function tablaQueFalla(error: unknown) {
  const builder: Record<string, unknown> = {}
  const encadenable = () => builder
  for (const m of ['select', 'order', 'eq', 'gte', 'lte', 'or', 'in', 'not']) builder[m] = encadenable
  builder.range = () => Promise.resolve({ data: null, error })
  return builder
}

async function errorDelHook(error: unknown): Promise<Error & { code?: string; sinServidor?: boolean }> {
  from.mockImplementation(() => tablaQueFalla(error))
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  const { result } = renderHook(() => usePedidoStatsQuery(), { wrapper })
  await waitFor(() => expect(result.current.isError).toBe(true))
  return result.current.error as Error & { code?: string; sinServidor?: boolean }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('usePedidoStatsQuery — errores normalizados (#1011)', () => {
  it('sin servidor: mensaje de sin conexión que nombra los totales, sin "Failed to fetch"', async () => {
    const e = await errorDelHook(ERROR_DE_RED)

    expect(e.sinServidor).toBe(true)
    expect(e.message).toMatch(/^Sin conexión/)
    expect(e.message).toContain('totales de pedidos')
    expect(e.message).not.toMatch(/failed to fetch/i)
  })

  it('con servidor: conserva "No se pudieron calcular los totales de pedidos: <mensaje>" y el code', async () => {
    const e = await errorDelHook(ERROR_DE_SERVIDOR)

    expect(e.message).toBe(
      'No se pudieron calcular los totales de pedidos: canceling statement due to statement timeout',
    )
    expect(e.code).toBe('57014')
  })
})
