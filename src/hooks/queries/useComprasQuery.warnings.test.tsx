/**
 * Los avisos blandos que devuelven las RPCs de compra tienen que llegar arriba.
 *
 * EL HUECO
 * --------
 * `registrar_compra_completa` devuelve `warning_descuadre` (el total calculado
 * no coincide con el informado) y `warning_ii_declarado` (la apertura del
 * impuesto interno por alícuota no cierra contra el total, o declara una tasa
 * que ninguna línea usa). `actualizar_compra_items` devuelve el segundo. La
 * base los redactaba y el cliente los tiraba a la basura: la compra se
 * guardaba, el usuario veía "Compra registrada" y el descuadre no existía para
 * nadie.
 *
 * Se testea la capa de query y no el DOM porque lo que se rompe en silencio es
 * justo esto: leer un campo del jsonb. Un `warning_ii` en vez de
 * `warning_ii_declarado` no lo ve tsc —el jsonb entra como `any` casteado— y no
 * tira ninguna pantalla; sólo vuelve a apagar el aviso.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: vi.fn(),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useRegistrarCompraMutation, useActualizarCompraMutation } from './useComprasQuery'
import type { ActualizarCompraItemsInput } from './useComprasQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup<T>(hook: () => T) {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return renderHook(hook, { wrapper: makeWrapper(qc) })
}

const compra = {
  proveedorId: '3',
  proveedorNombre: null,
  numeroFactura: 'A0005-00461415',
  fechaCompra: '2026-08-19',
  subtotal: 10_000,
  iva: 2100,
  impuestosInternos: 500,
  otrosImpuestos: 0,
  total: 12_600,
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
  subtotal: 10_000,
  iva: 2100,
  total: 12_600,
  items: [{ productoId: '7', cantidad: 10, costoUnitario: 1000, subtotal: 10_000 }],
  cargos: [],
  iiDeclarado: {},
}

const DESCUADRE = 'Descuadre: total calculado 12700.00 vs total informado 12600.00'
const II = 'El impuesto interno declarado por alicuota suma 900.00 y el total informado es 500.00.'

describe('avisos de la base al registrar una compra', () => {
  beforeEach(() => rpc.mockReset())

  it('sube los dos warnings tal como los redacto la RPC', async () => {
    rpc.mockResolvedValue({
      data: {
        success: true,
        compra_id: '226',
        warning_descuadre: DESCUADRE,
        warning_ii_declarado: II,
      },
      error: null,
    })
    const { result } = setup(useRegistrarCompraMutation)

    const res = await result.current.mutateAsync(compra)

    // Tal cual: reescribir el texto acá haria que la app y la base cuenten la
    // misma diferencia con dos numeros distintos.
    expect(res.warningDescuadre).toBe(DESCUADRE)
    expect(res.warningIiDeclarado).toBe(II)
    expect(res.compraId).toBe('226')
  })

  it('sin descuadre no inventa aviso', async () => {
    rpc.mockResolvedValue({
      data: { success: true, compra_id: '226', warning_descuadre: null, warning_ii_declarado: null },
      error: null,
    })
    const { result } = setup(useRegistrarCompraMutation)

    const res = await result.current.mutateAsync(compra)

    expect(res.warningDescuadre).toBeNull()
    expect(res.warningIiDeclarado).toBeNull()
  })

  it('el aviso NO convierte la compra en un error: viene con success', async () => {
    // Es la razon de ser del warning blando. Si se tratara como error, el
    // container haria rollback de la UI de una compra que quedo registrada.
    rpc.mockResolvedValue({
      data: { success: true, compra_id: '226', warning_descuadre: DESCUADRE },
      error: null,
    })
    const { result } = setup(useRegistrarCompraMutation)

    await expect(result.current.mutateAsync(compra)).resolves.toMatchObject({ success: true })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
  })
})

describe('avisos de la base al editar una compra', () => {
  beforeEach(() => rpc.mockReset())

  it('sube el del II declarado junto con el del costo promedio', async () => {
    rpc.mockResolvedValue({
      data: {
        success: true,
        compra_id: '221',
        warning_costo_promedio: [{ producto_id: 7, costo_real_anterior: 100, costo_real_nuevo: 120 }],
        warning_ii_declarado: II,
      },
      error: null,
    })
    const { result } = setup(useActualizarCompraMutation)

    const res = await result.current.mutateAsync(edicion)

    expect(res.warningIiDeclarado).toBe(II)
    expect(res.warningCostoPromedio).toHaveLength(1)
  })

  it('sin apertura declarada no hay aviso', async () => {
    // `actualizar_compra_items` no devuelve `warning_descuadre`: no recalcula el
    // total contra el informado, lo recibe ya hecho.
    rpc.mockResolvedValue({ data: { success: true, compra_id: '221' }, error: null })
    const { result } = setup(useActualizarCompraMutation)

    const res = await result.current.mutateAsync(edicion)

    expect(res.warningIiDeclarado).toBeNull()
    expect(res.warningCostoPromedio).toEqual([])
  })
})
