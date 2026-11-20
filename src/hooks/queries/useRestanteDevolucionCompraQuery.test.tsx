/**
 * 1590-c (#1590): lo que le queda por acreditar a la compra de un lote, para la
 * devolución por lote de Vencimientos. La fila del lote no trae ni el total ni las
 * notas de la compra: el hook los lee aparte (dos consultas simples, sin embeds)
 * sólo mientras la devolución está abierta.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const tablas = vi.hoisted(() => ({
  compras: vi.fn(),
  notas_credito: vi.fn(),
}))

vi.mock('../supabase/base', () => {
  // Una cadena de PostgREST que guarda los filtros y resuelve con lo que diga la tabla.
  const cadena = (tabla: 'compras' | 'notas_credito') => {
    const filtros: Record<string, unknown> = {}
    const q = {
      select: (cols: string) => { filtros.select = cols; return q },
      eq: (col: string, v: unknown) => { filtros[col] = v; return q },
      maybeSingle: () => Promise.resolve(tablas[tabla](filtros)),
      then: (ok: (r: unknown) => unknown, ko?: (e: unknown) => unknown) =>
        Promise.resolve(tablas[tabla](filtros)).then(ok, ko),
    }
    return q
  }
  return { supabase: { from: (t: 'compras' | 'notas_credito') => cadena(t) } }
})

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useRestanteDevolucionCompraQuery } from './useNotasCreditoQuery'

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('useRestanteDevolucionCompraQuery', () => {
  beforeEach(() => {
    tablas.compras.mockReset()
    tablas.notas_credito.mockReset()
  })

  it('con un ajuste vigente da el total menos las notas vigentes, sin pedir columnas de más', async () => {
    tablas.compras.mockReturnValue({ data: { id: 55, total: 1000 }, error: null })
    tablas.notas_credito.mockReturnValue({
      data: [{ total: 700, tipo: 'ajuste', anulada: false }, { total: 100, tipo: 'devolucion', anulada: false }],
      error: null,
    })
    const { result } = renderHook(() => useRestanteDevolucionCompraQuery(55), { wrapper })

    await waitFor(() => expect(result.current.data).toEqual({ compraId: 55, restante: 200 }))
    expect(tablas.compras).toHaveBeenCalledWith({ select: 'id, total', id: 55 })
    expect(tablas.notas_credito).toHaveBeenCalledWith({ select: 'total, tipo, anulada', compra_id: 55 })
  })

  it('sin ajuste no hay tope: null', async () => {
    tablas.compras.mockReturnValue({ data: { id: 55, total: 1000 }, error: null })
    tablas.notas_credito.mockReturnValue({ data: [], error: null })
    const { result } = renderHook(() => useRestanteDevolucionCompraQuery(55), { wrapper })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toBeNull()
  })

  it('sin compra abierta no consulta nada', () => {
    renderHook(() => useRestanteDevolucionCompraQuery(null), { wrapper })
    expect(tablas.compras).not.toHaveBeenCalled()
    expect(tablas.notas_credito).not.toHaveBeenCalled()
  })
})
