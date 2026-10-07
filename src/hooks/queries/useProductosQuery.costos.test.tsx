/**
 * #974 · el catálogo se lee sin costos y los costos llegan por la RPC.
 *
 * `authenticated` ya no tiene SELECT sobre las columnas de costo de productos,
 * así que la consulta del catálogo tiene que pedir `PRODUCTO_COLUMNAS` (un `*`
 * la haría fallar entera, para todos los roles) y pegarle los costos que
 * devuelve `costos_productos()` —que sólo los da a admin y encargado—.
 *
 * Y si la RPC falla, el catálogo falla: la ficha del producto arranca el form
 * con los costos que trae el producto, y guardarla sin ellos los pisaría con
 * NULL.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { PRODUCTO_COLUMNAS } from '../../lib/productoColumnas'

const select = vi.fn()
const rpc = vi.fn()

const PRODUCTOS = [
  { id: 1, nombre: 'AGUA 2L', precio: 100 },
  { id: 2, nombre: 'BIZCOCHO', precio: 50 },
]

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: (cols: string) => {
        select(cols)
        return { order: () => Promise.resolve({ data: PRODUCTOS, error: null }) }
      },
    }),
    rpc: (...args: unknown[]) => rpc(...args),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useProductosQuery } from './useProductosQuery'

function setup() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderHook(() => useProductosQuery(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
}

describe('useProductosQuery · costos por RPC (#974)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('pide las columnas concedidas, no `*`', async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    const { result } = setup()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(select).toHaveBeenCalledWith(PRODUCTO_COLUMNAS)
  })

  it('admin/encargado: pega los costos de la RPC a cada producto', async () => {
    rpc.mockResolvedValue({
      data: [{ id: 1, costo_real: 60, costo_promedio: 58.5, costo_sin_iva: 50, costo_con_iva: 60.5 }],
      error: null,
    })
    const { result } = setup()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(rpc).toHaveBeenCalledWith('costos_productos', { p_ids: [1, 2] })
    expect(result.current.data).toEqual([
      { id: 1, nombre: 'AGUA 2L', precio: 100, costo_real: 60, costo_promedio: 58.5, costo_sin_iva: 50, costo_con_iva: 60.5 },
      { id: 2, nombre: 'BIZCOCHO', precio: 50 },
    ])
  })

  it('preventista: la RPC no devuelve filas y el catálogo llega sin costos', async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    const { result } = setup()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual(PRODUCTOS)
    for (const p of result.current.data!) expect(p).not.toHaveProperty('costo_real')
  })

  it('si la RPC falla, el catálogo falla (no sigue sin costos)', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'boom', code: 'XX000' } })
    const { result } = setup()
    await waitFor(() => expect(result.current.isError).toBe(true))
  })
})
