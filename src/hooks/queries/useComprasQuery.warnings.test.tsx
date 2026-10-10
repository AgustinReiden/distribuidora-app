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

  it('sube el motivo de cada aviso de costo promedio (mig 236)', async () => {
    // Son dos causas distintas y la pantalla las dice distinto. Sin `motivo`
    // las dos caerían en "la compra no es la última", que sobre una compra que
    // SÍ es la última manda al usuario a buscar donde no hay nada.
    rpc.mockResolvedValue({
      data: {
        success: true,
        compra_id: '221',
        warning_costo_promedio: [
          { producto_id: 7, costo_real_anterior: 100, costo_real_nuevo: 120, motivo: 'no_es_la_ultima' },
          { producto_id: 9, motivo: 'sin_cpp_previo' },
        ],
      },
      error: null,
    })
    const { result } = setup(useActualizarCompraMutation)

    const res = await result.current.mutateAsync(edicion)

    expect(res.warningCostoPromedio.map(w => w.motivo)).toEqual(['no_es_la_ultima', 'sin_cpp_previo'])
    // El del snapshot faltante no trae costos: no hay "antes" que mostrar.
    expect(res.warningCostoPromedio[1].costo_real_anterior).toBeUndefined()
  })
})

describe('el costo de reposicion que la factura vieja no piso (mig 236)', () => {
  beforeEach(() => rpc.mockReset())

  it('sube warning_costo_reposicion del alta', async () => {
    // Una factura traspapelada suma stock y pesa en el promedio, pero NO
    // devuelve el costo de reposición a su fecha. De ese costo salen los
    // precios de venta: el silencio era lo peligroso.
    rpc.mockResolvedValue({
      data: {
        success: true,
        compra_id: '226',
        warning_costo_reposicion: [
          { producto_id: 7, fecha_compra: '2026-08-19', fecha_ultima_compra: '2026-09-10' },
        ],
      },
      error: null,
    })
    const { result } = setup(useRegistrarCompraMutation)

    const res = await result.current.mutateAsync(compra)

    expect(res.warningCostoReposicion).toHaveLength(1)
    expect(res.warningCostoReposicion?.[0].fecha_ultima_compra).toBe('2026-09-10')
  })

  it('sin compra posterior no hay aviso', async () => {
    rpc.mockResolvedValue({ data: { success: true, compra_id: '226' }, error: null })
    const { result } = setup(useRegistrarCompraMutation)

    const res = await result.current.mutateAsync(compra)

    expect(res.warningCostoReposicion).toEqual([])
  })
})

describe('el payload de p_items al registrar (#1077)', () => {
  beforeEach(() => rpc.mockReset())

  type ItemRPC = { subtotal: number }
  const sumaItems = (items: ItemRPC[]) => items.reduce((acc, i) => acc + i.subtotal, 0)

  it('una linea bonificada al 100% manda subtotal 0 y la cabecera cierra con los items', async () => {
    // El subtotal es NETO: una linea al 100% vale 0. Con `||` el 0 se tomaba
    // por "falta" y se reemplazaba por el bruto (10 x 800), y la cabecera
    // (200) dejaba de ser la suma de los items (8200). La base rechaza eso.
    rpc.mockResolvedValue({ data: { success: true, compra_id: '226' }, error: null })
    const { result } = setup(useRegistrarCompraMutation)

    await result.current.mutateAsync({
      ...compra,
      subtotal: 200,
      items: [
        { productoId: '7', cantidad: 2, costoUnitario: 100, bonificacion: 0, subtotal: 200 },
        { productoId: '8', cantidad: 10, costoUnitario: 800, bonificacion: 100, subtotal: 0 },
      ],
    })

    const args = rpc.mock.calls.find(c => c[0] === 'registrar_compra_completa')![1] as {
      p_subtotal: number
      p_items: ItemRPC[]
    }
    expect(args.p_items[1].subtotal).toBe(0)
    expect(args.p_subtotal).toBe(sumaItems(args.p_items))
    expect(args.p_subtotal).toBe(200)
  })

  it('una linea sin subtotal (llamador viejo) sigue cayendo a cantidad x costo', async () => {
    rpc.mockResolvedValue({ data: { success: true, compra_id: '226' }, error: null })
    const { result } = setup(useRegistrarCompraMutation)

    await result.current.mutateAsync({
      ...compra,
      subtotal: 300,
      items: [{ productoId: '7', cantidad: 3, costoUnitario: 100 }],
    })

    const args = rpc.mock.calls.find(c => c[0] === 'registrar_compra_completa')![1] as { p_items: ItemRPC[] }
    expect(args.p_items[0].subtotal).toBe(300)
  })
})

describe('editar una compra sincroniza los lotes siempre', () => {
  beforeEach(() => rpc.mockReset())

  it('llama a sincronizar_lotes_compra aunque ninguna línea traiga vencimientos', async () => {
    // La RPC recibe la FOTO completa de los lotes de la factura: una lista
    // vacía es la forma de borrar los que había. En el alta, sin vencimientos
    // ni se llama; en la edición se llama siempre (forzar = true).
    rpc.mockResolvedValue({ data: { success: true, compra_id: '221' }, error: null })
    const { result } = setup(useActualizarCompraMutation)

    await result.current.mutateAsync({ ...edicion, items: [{ ...edicion.items[0], vencimientos: [] }] })

    expect(rpc.mock.calls.map(c => c[0])).toEqual(['actualizar_compra_items', 'sincronizar_lotes_compra'])
    expect(rpc.mock.calls[1][1]).toEqual({ p_compra_id: '221', p_lotes: [] })
  })
})

describe('lo que el escaner aprende va despues de la compra y no la bloquea (mig 292)', () => {
  beforeEach(() => rpc.mockReset())

  const equivalenciasEscaneo = [{ producto_id: '7', codigo_proveedor: 'AB12', descripcion: 'AGUA VILLAM S/G 600X12' }]

  it('manda las equivalencias con el proveedor de la compra, despues de registrarla', async () => {
    rpc.mockImplementation((nombre: string) => Promise.resolve(nombre === 'registrar_compra_completa'
      ? { data: { success: true, compra_id: '226' }, error: null }
      : { data: { success: true, insertadas: 1, actualizadas: 0 }, error: null }))
    const { result } = setup(useRegistrarCompraMutation)

    const res = await result.current.mutateAsync({ ...compra, equivalenciasEscaneo })

    const nombres = rpc.mock.calls.map(c => c[0])
    expect(nombres.indexOf('registrar_equivalencias_proveedor')).toBeGreaterThan(nombres.indexOf('registrar_compra_completa'))
    expect(rpc).toHaveBeenCalledWith('registrar_equivalencias_proveedor', { p_proveedor_id: '3', p_items: equivalenciasEscaneo })
    expect(res.warningEquivalencias).toBeNull()
  })

  it('si falla, la compra queda registrada y vuelve un aviso', async () => {
    rpc.mockImplementation((nombre: string) => Promise.resolve(nombre === 'registrar_compra_completa'
      ? { data: { success: true, compra_id: '226' }, error: null }
      : { data: null, error: { message: 'boom' } }))
    const { result } = setup(useRegistrarCompraMutation)

    const res = await result.current.mutateAsync({ ...compra, equivalenciasEscaneo })

    expect(res.success).toBe(true)
    expect(res.compraId).toBe('226')
    expect(res.warningEquivalencias).toMatch(/La compra se registró.*boom/)
  })

  it('sin proveedor existente (nombre tipeado) no hay a quien colgarlas: no llama', async () => {
    rpc.mockResolvedValue({ data: { success: true, compra_id: '226' }, error: null })
    const { result } = setup(useRegistrarCompraMutation)

    const res = await result.current.mutateAsync({ ...compra, proveedorId: null, proveedorNombre: 'Nuevo', equivalenciasEscaneo })

    expect(rpc.mock.calls.map(c => c[0])).not.toContain('registrar_equivalencias_proveedor')
    expect(res.warningEquivalencias).toBeNull()
  })
})
