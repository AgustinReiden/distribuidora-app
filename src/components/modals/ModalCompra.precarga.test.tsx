/**
 * ModalCompra · la precarga del neto de lista + bonificación (a7e0dc41) con la
 * query REAL de costos anteriores, no un mock que devuelve una referencia fija.
 *
 * El 2026-10-20 agregar un producto a una compra clavaba el navegador
 * ("Maximum update depth exceeded", React #185) y no se podía cargar ninguna
 * compra. Los demás tests del modal mockean `useCostosAnterioresQuery` con
 * `data: undefined`, así que el efecto de la precarga nunca corría en ellos.
 *
 * Datos sintéticos.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ReactElement } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ProductoDB, ProveedorDBExtended } from '../../types'

const mocks = vi.hoisted(() => ({ filas: [] as unknown[] }))

// `from('compra_items')` arma la consulta encadenada y la resuelve con `mocks.filas`.
vi.mock('../../lib/supabase', () => {
  const consulta = (): Record<string, unknown> => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'in', 'not', 'neq', 'lte', 'eq', 'order', 'limit']) q[m] = () => q
    q.then = (ok: (r: unknown) => unknown, ko?: (e: unknown) => unknown) =>
      Promise.resolve({ data: mocks.filas, error: null }).then(ok, ko)
    return q
  }
  return {
    supabase: { storage: { from: vi.fn() }, rpc: vi.fn(), from: vi.fn(() => consulta()) },
    setSucursalHeader: vi.fn(),
    getSucursalHeader: vi.fn(() => null),
  }
})
vi.mock('../../contexts/SucursalContext', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../contexts/SucursalContext')>()),
  useSucursal: () => ({ currentSucursalId: 1 }),
}))
vi.mock('../../hooks/queries/useComprasQuery', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../hooks/queries/useComprasQuery')>()),
  useCargosPlantillaProveedorQuery: () => ({ data: null }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
}))
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  const conceptos: unknown[] = [], medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('./ModalProveedor', () => ({ default: () => null }))
vi.mock('./ModalImportarCompra', () => ({ default: () => null }))

import ModalCompra, { type ModalCompraProps } from './ModalCompra'
import type { ActualizarCompraItemsInput } from '../../hooks/queries/useComprasQuery'
import { compraTestigoEdicion } from '../../test/fixtures/compraTestigoEdicion'

type OnSave = NonNullable<ModalCompraProps['onSave']>

// Papas: la última factura decía 1.000 de lista con 10% → costo_sin_iva 900.
// Galletitas: la última factura no tenía bonificación.
const PRODUCTOS = [
  { id: 'p1', nombre: 'Papas Cebolla 150g', codigo: 'PC', stock: 0, costo_sin_iva: 900, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
  { id: 'p2', nombre: 'Galletitas Agua', codigo: 'GA', stock: 0, costo_sin_iva: 500, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
] as unknown as ProductoDB[]
const PROVEEDORES = [{ id: 'prov-1', nombre: 'Snacks del Norte', cuit: null }] as unknown as ProveedorDBExtended[]

function fila(productoId: string, costoUnitario: number, bonificacion: number) {
  return {
    producto_id: productoId, compra_id: 10, costo_real_unitario: costoUnitario * (1 - bonificacion / 100) * 1.21,
    costo_unitario: costoUnitario, bonificacion,
    compra: { id: 10, fecha_compra: '2026-09-01', numero_factura: '0001-00000010', tipo_factura: 'FC', letra_comprobante: 'A', estado: 'recibida' },
  }
}

const conQueryClient = (ui: ReactElement) => (
  <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>{ui}</QueryClientProvider>
)

function renderModal() {
  const onSave = vi.fn<OnSave>(() => Promise.resolve())
  render(conQueryClient(<ModalCompra productos={PRODUCTOS} proveedores={PROVEEDORES} onSave={onSave} onClose={vi.fn()} />))
  return { onSave, user: userEvent.setup() }
}

beforeEach(() => {
  mocks.filas = [fila('p1', 1000, 10), fila('p2', 500, 0)]
  localStorage.clear()
})

describe('ModalCompra · precarga con la compra anterior (React #185)', () => {
  it('agregar productos con compra anterior no entra en loop, precarga el neto de lista y registra', async () => {
    const { user, onSave } = renderModal()
    const combo = screen.getByRole('combobox', { name: 'Proveedor de la factura' })
    await user.click(combo)
    await user.type(combo, 'Snacks')
    await user.click(within(screen.getByRole('listbox', { name: 'Proveedor de la factura' })).getByRole('option', { name: /Snacks/ }))

    for (const nombre of ['Papas Cebolla 150g', 'Galletitas Agua']) {
      await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
      await user.click(screen.getByRole('button', { name: new RegExp(nombre) }))
    }

    // La precarga llega con la query: Papas pasa al neto de lista + 10%.
    await waitFor(() => expect(screen.getAllByDisplayValue(/^1\.?000(,00)?$/).length).toBeGreaterThan(0))

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))
    expect(onSave).toHaveBeenCalledTimes(1)
    const items = onSave.mock.calls[0][0].items
    expect(items).toEqual([
      expect.objectContaining({ productoId: 'p1', costoUnitario: 1000, bonificacion: 10 }),
      expect.objectContaining({ productoId: 'p2', costoUnitario: 500, bonificacion: 0 }),
    ])
  })
})

describe("ModalCompra 'editar' · precarga con la compra anterior (React #185)", () => {
  it('abre con costos anteriores, agrega una línea con la precarga y guarda', async () => {
    // La 304 (fixture) tiene compra anterior en sus líneas; el producto nuevo,
    // 400 de lista con 25% → costo_sin_iva 300.
    mocks.filas = [fila('501', 1000, 0), fila('777', 400, 25)]
    const onGuardarEdicion = vi.fn<(input: ActualizarCompraItemsInput) => Promise<void>>(() => Promise.resolve())
    const productoNuevo = {
      id: '777', nombre: 'Soda 1,5L', codigo: 'S15', stock: 12, costo_sin_iva: 300,
      impuestos_internos: 4.5, porcentaje_iva: 21, condicion_iva: 'gravado', activo: true,
    }
    render(conQueryClient(
      <ModalCompra
        modo="editar" compra={compraTestigoEdicion()} productos={[productoNuevo as never]} proveedores={[]}
        onClose={vi.fn()} onGuardarEdicion={onGuardarEdicion} onCambiarProveedor={vi.fn()}
        canCambiarProveedor usuarioId="u1" sucursalId={1} lotes={[]}
      />
    ))
    const user = userEvent.setup()

    await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
    await user.click(screen.getByRole('button', { name: /Soda 1,5L/ }))
    await waitFor(() => expect(screen.getAllByDisplayValue(/^400(,00)?$/).length).toBeGreaterThan(0))

    await user.click(screen.getByRole('button', { name: /Guardar cambios/ }))
    expect(onGuardarEdicion).toHaveBeenCalledTimes(1)
    const { items } = onGuardarEdicion.mock.calls[0][0]
    expect(items).toHaveLength(5)
    expect(items[4]).toMatchObject({ productoId: '777', costoUnitario: 400, bonificacion: 25 })
  })
})
