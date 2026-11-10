/**
 * FRT-1 (#1517): las mutaciones de compras invalidan los lotes.
 *
 * El alta y la edición cargan los vencimientos (`sincronizar_lotes_compra`), la
 * edición a la baja achica los lotes de la compra (mig 482), la anulación los
 * borra y el cambio de proveedor los reapunta. Ninguna invalidaba `lotesKeys`:
 * la ficha del producto, Vencimientos y la precarga de la edición siguiente
 * quedaban con la foto de antes, y la edición siguiente la mandaba completa
 * (borraba los vencimientos recién cargados o devolvía los que se habían sacado).
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
  useRegistrarCompraMutation,
  useActualizarCompraMutation,
  useAnularCompraMutation,
  useCambiarProveedorCompraMutation,
} from './useComprasQuery'
import type { ActualizarCompraItemsInput } from './useComprasQuery'
import { lotesKeys } from './useLotesQuery'

// Las tres lecturas de lotes que hay: la de una compra (la precarga de la edición), la del producto y el panel.
const CLAVES = [
  [...lotesKeys.all(1), 'compra', '221'],
  lotesKeys.byProducto(1, 7),
  [...lotesKeys.reporte(1), null],
]

function setup<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
  for (const clave of CLAVES) qc.setQueryData(clave, [{ id: 1, cantidad_restante: 100 }])
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, ...renderHook(hook, { wrapper }) }
}

const invalidadas = (qc: QueryClient) => CLAVES.map(c => qc.getQueryState(c)?.isInvalidated ?? false)

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
  subtotal: 8_000,
  iva: 1680,
  total: 9_680,
  items: [{ productoId: '7', cantidad: 8, costoUnitario: 1000, subtotal: 8_000, vencimientos: [{ fecha: '2027-03-01', cantidad: 8 }] }],
  cargos: [],
  iiDeclarado: {},
}

describe('FRT-1 · las mutaciones de compras invalidan los lotes', () => {
  beforeEach(() => {
    rpc.mockReset()
    rpc.mockResolvedValue({ data: { success: true, compra_id: '221', nueva_compra_id: 222, ok: true, warning_clamp: [] }, error: null })
  })

  it('registrar una compra', async () => {
    const { qc, result } = setup(useRegistrarCompraMutation)
    expect(invalidadas(qc)).toEqual([false, false, false])
    await result.current.mutateAsync(compra)
    expect(invalidadas(qc)).toEqual([true, true, true])
  })

  it('editarla (y con eso la precarga de la próxima edición vuelve a leer)', async () => {
    const { qc, result } = setup(useActualizarCompraMutation)
    await result.current.mutateAsync(edicion)
    expect(invalidadas(qc)).toEqual([true, true, true])
  })

  it('anularla', async () => {
    const { qc, result } = setup(useAnularCompraMutation)
    await result.current.mutateAsync('221')
    expect(invalidadas(qc)).toEqual([true, true, true])
  })

  it('cambiarle el proveedor', async () => {
    const { qc, result } = setup(useCambiarProveedorCompraMutation)
    await result.current.mutateAsync({ compraId: '221', nuevoProveedorId: '4', nuevoProveedorNombre: null, usuarioId: 'user-1' })
    expect(invalidadas(qc)).toEqual([true, true, true])
  })

  it('un error no invalida (la compra no cambió)', async () => {
    rpc.mockResolvedValue({ data: { success: false, error: 'La compra tiene 1 nota(s) de crédito: no se puede editar.' }, error: null })
    const { qc, result } = setup(useActualizarCompraMutation)
    await expect(result.current.mutateAsync(edicion)).rejects.toThrow(/nota\(s\) de crédito/)
    expect(invalidadas(qc)).toEqual([false, false, false])
  })
})
