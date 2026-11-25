/**
 * `useHojasDeRutaDepositoQuery` (Fr-B10 de #1554, T14 de #1690): no tenía ningún test.
 *
 * Depósito no lee `pedidos` por REST: lee las hojas de ruta por la RPC `hojas_de_ruta_deposito`
 * (sin plata). Se fija qué RPC sale y con qué fecha (null = que el server elija la próxima ruta),
 * que un error de red se normaliza (no «Failed to fetch» crudo), que la clave sigue a la sucursal y
 * a la fecha, y que sin sucursal activa no consulta.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { rpc, sucursal } = vi.hoisted(() => ({
  rpc: vi.fn(),
  sucursal: { id: 1 as number | null },
}))

vi.mock('../supabase/base', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursal.id }),
}))

import {
  useHojasDeRutaDepositoQuery,
  fetchHojasDeRutaDeposito,
  hojasDeRutaDepositoKeys,
} from './useHojasDeRutaDepositoQuery'

const RESPUESTA = {
  fecha: '2026-11-26',
  rutas: [{
    recorrido_id: 77, estado: 'en_curso', transportista: { id: 'u-1', nombre: 'Rober' },
    paradas: [{ id: 7143, estado: 'asignado', orden_entrega: 1, cliente: { id: 9, nombre_fantasia: 'Kiosco Lola' }, items: [] }],
  }],
  sin_ruta: [{ id: 8000, estado: 'pendiente', cliente: null, items: [] }],
  subrubros: { 'sub-1': 'Jugos' },
}

const envoltorio = () => {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return {
    queryClient,
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    ),
  }
}

describe('useHojasDeRutaDepositoQuery', () => {
  beforeEach(() => {
    rpc.mockReset()
    sucursal.id = 1
  })

  it('pide la RPC sin plata con la fecha elegida y entrega las hojas normalizadas', async () => {
    rpc.mockResolvedValue({ data: RESPUESTA, error: null })
    const { wrapper } = envoltorio()
    const { result } = renderHook(() => useHojasDeRutaDepositoQuery('2026-11-26'), { wrapper })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(rpc).toHaveBeenCalledWith('hojas_de_ruta_deposito', { p_fecha: '2026-11-26' })
    const hojas = result.current.data!
    expect(hojas.fecha).toBe('2026-11-26')
    expect(hojas.rutas[0].recorridoId).toBe('77')
    expect(hojas.rutas[0].paradas.map(p => p.id)).toEqual(['7143'])
    expect(hojas.sinRuta.map(p => p.id)).toEqual(['8000'])
    expect(hojas.subrubros).toEqual({ 'sub-1': 'Jugos' })
  })

  it('sin fecha manda null: que el servidor elija la próxima ruta armada', async () => {
    rpc.mockResolvedValue({ data: RESPUESTA, error: null })
    const { wrapper } = envoltorio()
    const { result } = renderHook(() => useHojasDeRutaDepositoQuery(null), { wrapper })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(rpc).toHaveBeenCalledWith('hojas_de_ruta_deposito', { p_fecha: null })
  })

  it('un error de red lanza el aviso de sin conexión, no «Failed to fetch»', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' } })
    const { wrapper } = envoltorio()
    const { result } = renderHook(() => useHojasDeRutaDepositoQuery('2026-11-26'), { wrapper })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect((result.current.error as Error).message).toMatch(/^Sin conexión: no se pudieron cargar las hojas de ruta/)
    expect((result.current.error as Error).message).not.toMatch(/failed to fetch/i)
  })

  it('un error del servidor conserva su mensaje', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'Sin permiso', details: '', hint: '', code: '42501' } })

    await expect(fetchHojasDeRutaDeposito('2026-11-26')).rejects.toMatchObject({ message: 'Sin permiso' })
  })

  it('sin sucursal activa no consulta', async () => {
    sucursal.id = null
    const { wrapper } = envoltorio()
    const { result } = renderHook(() => useHojasDeRutaDepositoQuery('2026-11-26'), { wrapper })

    expect(result.current.fetchStatus).toBe('idle')
    expect(rpc).not.toHaveBeenCalled()
  })

  it('la clave sigue a la sucursal y a la fecha, y «próxima» es otra clave que una fecha', () => {
    expect(hojasDeRutaDepositoKeys.fecha(1, '2026-11-26')).toEqual(['hojas-de-ruta-deposito', 1, '2026-11-26'])
    expect(hojasDeRutaDepositoKeys.fecha(1, null)).toEqual(['hojas-de-ruta-deposito', 1, 'proxima'])
    expect(hojasDeRutaDepositoKeys.fecha(2, '2026-11-26')).not.toEqual(hojasDeRutaDepositoKeys.fecha(1, '2026-11-26'))
    // El prefijo de la sucursal alcanza a todas sus fechas al invalidar.
    expect(hojasDeRutaDepositoKeys.fecha(1, '2026-11-26').slice(0, 2)).toEqual(hojasDeRutaDepositoKeys.all(1))
  })
})
