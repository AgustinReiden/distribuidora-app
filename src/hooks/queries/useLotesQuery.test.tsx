/**
 * Los lotes de una compra que el modal precarga (#1054, mig 338).
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

  // FRT-1 (#1517): la precarga de la edición es de una sola vez y se guarda entera. Con el caché fresco (30 s), una
  // segunda edición enseguida tomaba la foto de antes del primer guardado.
  describe('para editar, lee de nuevo aunque el caché esté fresco', () => {
    const conCache = () => {
      const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      qc.setQueryData(['lotes', 1, 'compra', '221'], [{ id: 9, cantidad: 100, cantidad_restante: 100 }])
      const w = ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
      return { qc, w }
    }

    it('paraEditar: vuelve a leer, y la foto del caché queda reemplazada por la de la base', async () => {
      const { w } = conCache()
      const { result } = renderHook(() => useLotesCompraQuery(221, true, { paraEditar: true }), { wrapper: w })
      await waitFor(() => expect(estado.llamadas).toContainEqual({ metodo: 'from', args: ['producto_lotes'] }))
      // La base (el mock) devuelve [], no la foto vieja.
      await waitFor(() => expect(result.current.data).toEqual([]))
    })

    it('sin paraEditar (el detalle): usa el caché fresco y no lee', async () => {
      const { w } = conCache()
      const { result } = renderHook(() => useLotesCompraQuery(221), { wrapper: w })
      await new Promise(r => setTimeout(r, 20))
      expect(estado.llamadas).toEqual([])
      expect(result.current.data).toEqual([{ id: 9, cantidad: 100, cantidad_restante: 100 }])
    })
  })
})
