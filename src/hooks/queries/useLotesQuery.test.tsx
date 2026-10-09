/**
 * Los lotes de una compra que el modal precarga (#1054, mig 337).
 *
 * Un vencimiento que el usuario sacó de la compra, si ya tenía traza (a qué
 * cliente se vendió), no se borra: queda como lote `solo_traza`, agotado, para
 * que un retiro siga encontrando a los clientes. No es un vencimiento de la
 * compra: si el modal lo precargara, volvería a aparecer como fila editable y
 * contaría contra la cantidad de la línea.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  llamadas: [] as { metodo: string; args: unknown[] }[],
}))

/** Cadena de PostgREST que anota cada método llamado; `await` da una lista vacía. */
function cadena(): unknown {
  const proxy: unknown = new Proxy(() => undefined, {
    get(_t, prop) {
      if (prop === 'then') {
        return (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) =>
          Promise.resolve({ data: [], error: null }).then(res, rej)
      }
      return (...args: unknown[]) => {
        estado.llamadas.push({ metodo: String(prop), args })
        return proxy
      }
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (tabla: string) => { estado.llamadas.push({ metodo: 'from', args: [tabla] }); return cadena() } },
  notifyError: vi.fn(),
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useLotesCompraQuery } from './useLotesQuery'

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('useLotesCompraQuery', () => {
  beforeEach(() => { estado.llamadas = [] })

  it('no trae los lotes que quedaron solo para la traza', async () => {
    const { result } = renderHook(() => useLotesCompraQuery(221), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(estado.llamadas).toContainEqual({ metodo: 'from', args: ['producto_lotes'] })
    expect(estado.llamadas).toContainEqual({ metodo: 'eq', args: ['compra_id', 221] })
    expect(estado.llamadas).toContainEqual({ metodo: 'eq', args: ['solo_traza', false] })
  })
})
