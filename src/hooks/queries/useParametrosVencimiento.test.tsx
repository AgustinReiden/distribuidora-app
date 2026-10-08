/**
 * Los días de alerta de vencimiento salen de una RPC (#999), no de la fila de
 * politicas_comerciales: depósito ya no lee esa tabla (trae el monto mínimo y
 * las comisiones), y /vencimientos es justo su pantalla.
 */
import type { ReactNode } from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { rpc, from, getCachedData } = vi.hoisted(() => ({ rpc: vi.fn(), from: vi.fn(), getCachedData: vi.fn() }))
vi.mock('../supabase/base', () => ({ supabase: { rpc, from } }))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))
vi.mock('../../lib/offlineDb', () => ({ cacheData: vi.fn(() => Promise.resolve()), getCachedData }))

import { useParametrosVencimientoQuery, politicasComercialesKeys } from './usePoliticasComercialesQuery'

function envoltorio(qc: QueryClient) {
  return ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('useParametrosVencimientoQuery', () => {
  beforeEach(() => {
    rpc.mockReset(); from.mockReset()
    getCachedData.mockReset(); getCachedData.mockResolvedValue(null)
  })

  it('lee los días por la RPC, nunca la tabla de políticas', async () => {
    rpc.mockResolvedValue({ data: [{ dias_alerta_vencimiento: 45, dias_critico_vencimiento: 7 }], error: null })
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { result } = renderHook(() => useParametrosVencimientoQuery(), { wrapper: envoltorio(qc) })
    await waitFor(() => expect(result.current.diasAlertaVencimiento).toBe(45))
    expect(result.current.diasCriticoVencimiento).toBe(7)
    expect(rpc).toHaveBeenCalledWith('parametros_vencimiento')
    expect(from).not.toHaveBeenCalled()
  })

  it('mientras no llega, usa los defaults de la mig 223', () => {
    rpc.mockReturnValue(new Promise(() => { /* nunca resuelve */ }))
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { result } = renderHook(() => useParametrosVencimientoQuery(), { wrapper: envoltorio(qc) })
    expect(result.current.diasAlertaVencimiento).toBe(60)
    expect(result.current.diasCriticoVencimiento).toBe(15)
  })

  it('sin señal, usa los días de la última política cacheada, no los defaults', async () => {
    // El admin o encargado que abrió la app con conexión dejó la política en
    // Dexie (usePoliticasComercialesQuery); antes /vencimientos la usaba offline.
    getCachedData.mockResolvedValue({ diasAlertaVencimiento: 30, diasCriticoVencimiento: 5 })
    rpc.mockReturnValue(new Promise(() => { /* sin red: nunca resuelve */ }))
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { result } = renderHook(() => useParametrosVencimientoQuery(), { wrapper: envoltorio(qc) })
    await waitFor(() => expect(result.current.diasAlertaVencimiento).toBe(30))
    expect(result.current.diasCriticoVencimiento).toBe(5)
  })

  it('cuelga de la clave de políticas: editar la política en /configuracion la refresca', () => {
    rpc.mockResolvedValue({ data: [], error: null })
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    renderHook(() => useParametrosVencimientoQuery(), { wrapper: envoltorio(qc) })
    const claves = qc.getQueryCache().findAll({ queryKey: politicasComercialesKeys.all(1) }).map(q => q.queryKey)
    expect(claves).toHaveLength(1)
  })
})
