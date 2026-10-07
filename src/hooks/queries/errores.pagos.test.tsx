/**
 * #760 — los hooks de datos de pagos y reportes tiran un Error de verdad.
 *
 * supabase-js NO lanza Error: devuelve un objeto plano. Estos tests usan SIEMPRE
 * esa forma real (nunca `new Error`):
 *   - respondió el servidor → `{ message, details, hint, code: 'P0001' }`
 *   - sin red               → `{ message: 'TypeError: Failed to fetch', code: '' }`
 *
 * La imputación de crédito es idempotente por client_request_id: la red se
 * reintenta (3 llamadas) y lo que contestó el servidor no (1).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { isTransientNetworkError } from '../../utils/retryWithBackoff'

const h = vi.hoisted(() => {
  const estado = { respuesta: { data: null, error: null } as { data: unknown; error: unknown } }
  const rpcCalls: string[] = []
  // Cualquier cadena de .from(...).select().eq()... termina resolviendo a `respuesta`.
  function cadena(): unknown {
    const proxy: unknown = new Proxy(function () {}, {
      get: (_t, prop) => {
        if (prop === 'then') return (res: (v: unknown) => void) => res(estado.respuesta)
        return () => proxy
      },
    })
    return proxy
  }
  const mockSupabase = {
    rpc: (fn: string) => {
      rpcCalls.push(fn)
      return Promise.resolve(estado.respuesta)
    },
    from: () => cadena(),
  }
  return { estado, rpcCalls, mockSupabase }
})
const rpcCalls = h.rpcCalls

vi.mock('../supabase/base', () => ({ supabase: h.mockSupabase }))
vi.mock('../../lib/supabase', () => ({ supabase: h.mockSupabase }))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useImputarCreditoMutation, usePedidoOrigenNCQuery } from './useImputarCreditoQuery'
import { useReportePreventistasQuery } from './useMetricasQuery'
import {
  useReporteGerencialQuery,
  usePosicionFiscalQuery,
  useAlertaDetalleQuery,
  useMetasGerencialQuery,
  useGuardarMetaMutation,
  useAnalisisMensualQuery,
} from './useReporteGerencialQuery'
import { useVentasPorClienteQuery } from './useVentasPorClienteQuery'

const ERR_SERVIDOR = {
  message: 'El pago ya fue imputado por completo',
  details: 'detalle',
  hint: 'pista',
  code: 'P0001',
}
const ERR_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }

function wrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  return function W({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function esServidor(e: unknown) {
  expect(e).toBeInstanceOf(Error)
  expect((e as Error).message).toBe(ERR_SERVIDOR.message)
  expect((e as { code?: string }).code).toBe('P0001')
}

function esRed(e: unknown, patron: RegExp) {
  expect(e).toBeInstanceOf(Error)
  expect((e as Error).message).not.toMatch(/failed to fetch/i)
  expect((e as Error).message).toMatch(/sin conexi/i)
  expect((e as Error).message).toMatch(patron)
  expect(isTransientNetworkError(e)).toBe(true)
}

/** Lecturas: [nombre, cómo montar el hook]. */
const lecturas: Array<[string, () => { error: unknown }]> = [
  ['usePedidoOrigenNCQuery', () => usePedidoOrigenNCQuery('5')],
  ['useReportePreventistasQuery', () => useReportePreventistasQuery('2026-10-01', '2026-10-31')],
  ['useReporteGerencialQuery', () => useReporteGerencialQuery(2, '2026-10-01', '2026-10-31')],
  ['usePosicionFiscalQuery', () => usePosicionFiscalQuery(2, '2026-10-01', '2026-10-31')],
  ['useAlertaDetalleQuery', () => useAlertaDetalleQuery(2, 'X', '2026-10-01', '2026-10-31', false)],
  ['useMetasGerencialQuery', () => useMetasGerencialQuery(2, '2026-10-01')],
  ['useAnalisisMensualQuery', () => useAnalisisMensualQuery(2, '2026-10')],
  ['useVentasPorClienteQuery', () => useVentasPorClienteQuery('2026-10-01', '2026-10-31')],
]

describe('lecturas de pagos y reportes', () => {
  beforeEach(() => {
    rpcCalls.length = 0
  })

  describe.each(lecturas)('%s', (_nombre, montar) => {
    it('servidor: Error con el mensaje y el code del servidor', async () => {
      h.estado.respuesta = { data: null, error: ERR_SERVIDOR }
      const { result } = renderHook(montar, { wrapper: wrapper() })
      await waitFor(() => expect(result.current.error).not.toBeNull())
      esServidor(result.current.error)
    })

    it('red: mensaje de sin conexión, no Failed to fetch, y sigue siendo transitorio', async () => {
      h.estado.respuesta = { data: null, error: ERR_RED }
      const { result } = renderHook(montar, { wrapper: wrapper() })
      await waitFor(() => expect(result.current.error).not.toBeNull())
      esRed(result.current.error, /no se pudo cargar/i)
    })
  })
})

describe('useGuardarMetaMutation (escritura)', () => {
  const vars = { sucursalId: 2, periodo: '2026-10-01', metrica: 'venta' as const, valor: 1000 }

  it('servidor', async () => {
    h.estado.respuesta = { data: null, error: ERR_SERVIDOR }
    const { result } = renderHook(() => useGuardarMetaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(vars)).rejects.toSatisfy((e: unknown) => {
      esServidor(e)
      return true
    })
  })

  it('red: avisa que no se pudo confirmar', async () => {
    h.estado.respuesta = { data: null, error: ERR_RED }
    const { result } = renderHook(() => useGuardarMetaMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(vars)).rejects.toSatisfy((e: unknown) => {
      esRed(e, /no se pudo confirmar/i)
      return true
    })
  })
})

describe('useImputarCreditoMutation (dinero, idempotente por client_request_id)', () => {
  const input = { pagoId: '1', pedidoId: '2', monto: 100, clientRequestId: 'abc' }

  beforeEach(() => {
    rpcCalls.length = 0
  })

  it('servidor: un solo intento y el mensaje llega con su code', async () => {
    h.estado.respuesta = { data: null, error: ERR_SERVIDOR }
    const { result } = renderHook(() => useImputarCreditoMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(input)).rejects.toSatisfy((e: unknown) => {
      esServidor(e)
      return true
    })
    expect(rpcCalls).toHaveLength(1)
  })

  it('red: se reintenta (3 intentos) y pide revisar la cuenta antes de reintentar', async () => {
    h.estado.respuesta = { data: null, error: ERR_RED }
    const { result } = renderHook(() => useImputarCreditoMutation(), { wrapper: wrapper() })
    await expect(result.current.mutateAsync(input)).rejects.toSatisfy((e: unknown) => {
      esRed(e, /no se pudo confirmar/i)
      expect((e as Error).message).toMatch(/cuenta del cliente/i)
      return true
    })
    expect(rpcCalls).toHaveLength(3)
  }, 15000)
})
