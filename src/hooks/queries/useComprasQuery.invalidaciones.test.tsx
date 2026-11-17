/**
 * 1557-b8 y 1599-b5: registrar o editar una compra dejaba viejos el detalle de
 * la compra (5 min) y los costos anteriores de sus productos. Sólo se
 * invalidaba la lista.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: vi.fn(),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'admin-1' } } }) },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import {
  comprasKeys,
  useRegistrarCompraMutation,
  useActualizarCompraMutation,
  useAnularCompraMutation,
  useCambiarProveedorCompraMutation,
} from './useComprasQuery'
import type { ActualizarCompraItemsInput } from './useComprasQuery'

const DETALLE = comprasKeys.detail(1, '221')
const COSTOS_ANTERIORES = [...comprasKeys.all(1), 'costos-anteriores', '7', 'nueva', '2026-08-19']

function setup<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
  qc.setQueryData(DETALLE, { id: 221 })
  qc.setQueryData(COSTOS_ANTERIORES, [])
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, ...renderHook(hook, { wrapper }) }
}

const invalidadas = (qc: QueryClient) =>
  [DETALLE, COSTOS_ANTERIORES].map(c => qc.getQueryState(c)?.isInvalidated ?? false)

const compra = {
  proveedorId: '3',
  proveedorNombre: null,
  numeroFactura: 'A0005-00461415',
  fechaCompra: '2026-08-19',
  subtotal: 10_000,
  iva: 2100,
  impuestosInternos: 0,
  otrosImpuestos: 0,
  total: 12_100,
  formaPago: 'efectivo',
  notas: null,
  tipoFactura: 'FC' as const,
  usuarioId: 'user-1',
  items: [{ productoId: '7', cantidad: 10, costoUnitario: 1000, subtotal: 10_000 }],
  cargos: [],
  iiDeclarado: {},
}

const edicion: ActualizarCompraItemsInput = {
  compraId: '221',
  usuarioId: 'user-1',
  renglonesVistos: [9001],
  subtotal: 8_000,
  iva: 1680,
  total: 9_680,
  items: [{ productoId: '7', cantidad: 8, costoUnitario: 1000, subtotal: 8_000 }],
  cargos: [],
  iiDeclarado: {},
}

describe('el detalle de la compra y los costos anteriores se invalidan', () => {
  beforeEach(() => {
    rpc.mockReset()
    rpc.mockResolvedValue({ data: { success: true, compra_id: '221', nueva_compra_id: 222, ok: true, warning_clamp: [] }, error: null })
  })

  it('al registrar una compra', async () => {
    const { qc, result } = setup(useRegistrarCompraMutation)
    expect(invalidadas(qc)).toEqual([false, false])
    await result.current.mutateAsync(compra)
    expect(invalidadas(qc)).toEqual([true, true])
  })

  it('al editarla', async () => {
    const { qc, result } = setup(useActualizarCompraMutation)
    await result.current.mutateAsync(edicion)
    expect(invalidadas(qc)).toEqual([true, true])
  })

  it('al anularla y al cambiarle el proveedor (una compra anulada ya no es "la anterior")', async () => {
    const a = setup(useAnularCompraMutation)
    await a.result.current.mutateAsync('221')
    expect(invalidadas(a.qc)).toEqual([true, true])

    const b = setup(useCambiarProveedorCompraMutation)
    await b.result.current.mutateAsync({ compraId: '221', nuevoProveedorId: '4', nuevoProveedorNombre: null, usuarioId: 'user-1' })
    expect(invalidadas(b.qc)).toEqual([true, true])
  })
})
