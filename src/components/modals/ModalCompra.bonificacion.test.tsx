/**
 * ModalCompra · #908: la sugerencia de la bonificación que el proveedor no
 * descontó de la base del impuesto interno, de punta a punta en la carga.
 *
 * Datos sintéticos.
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB, ProveedorDBExtended } from '../../types'
import type { ConceptoCargo } from '../../utils/medidasCargo'

const mocks = vi.hoisted(() => ({
  conceptos: [] as unknown[],
  plantillas: {} as Record<string, unknown>,
}))

vi.mock('../../lib/supabase', () => ({
  supabase: { storage: { from: vi.fn() }, rpc: vi.fn(), from: vi.fn() },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: (proveedorId: string | null) => {
    const data = proveedorId ? mocks.plantillas[String(proveedorId)] : undefined
    return { data: data ?? null, isSuccess: !!proveedorId }
  },
  useCostosAnterioresQuery: () => ({ data: undefined }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
}))
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  const medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: mocks.conceptos }),
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

type OnSave = NonNullable<ModalCompraProps['onSave']>
type Usuario = ReturnType<typeof userEvent.setup>

const CONCEPTOS: ConceptoCargo[] = [
  { id: '13', nombre: 'Bonificación', signo: -1, condicionIva: 'gravado', enFactura: true, prorrateaAlCosto: true, baseProrrateo: 'monto', medidaId: null, activo: true },
]
const PRODUCTOS = [
  { id: 'p1', nombre: 'Cola 3L x6', codigo: 'C3', stock: 0, costo_sin_iva: 5000, impuestos_internos: 8.6957, porcentaje_iva: 21, condicion_iva: 'gravado' },
  { id: 'p2', nombre: 'Soda 2L x6', codigo: 'S2', stock: 0, costo_sin_iva: 1500, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
] as unknown as ProductoDB[]
const PROVEEDORES = [{ id: 'prov-1', nombre: 'Refrescos del Norte', cuit: null }] as unknown as ProveedorDBExtended[]

// Cola 3L: 100 × 5.000 = 500.000. El proveedor liquida el II sobre 520.000
// (la bonificación de 20.000 no bajó la base): 520.000 × 8,6957% = 45.217,64.
const DECLARADO = '45217,64'

function renderModal() {
  const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
  render(<ModalCompra productos={PRODUCTOS} proveedores={PROVEEDORES} onSave={onSave} onClose={vi.fn()} />)
  return { onSave, user: userEvent.setup() }
}

async function cargarFactura(user: Usuario) {
  const combo = screen.getByRole('combobox', { name: 'Proveedor de la factura' })
  await user.click(combo)
  await user.type(combo, 'Refrescos')
  await user.click(within(screen.getByRole('listbox', { name: 'Proveedor de la factura' })).getByRole('option', { name: /Refrescos/ }))
  for (const [nombre, cantidad] of [['Cola 3L x6', 100], ['Soda 2L x6', 40]] as const) {
    await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
    await user.click(screen.getByRole('button', { name: new RegExp(nombre) }))
    const input = screen.getAllByLabelText(`Cantidad de ${nombre}`)[0]
    await user.clear(input)
    await user.type(input, String(cantidad))
  }
  await user.click(screen.getByRole('button', { name: /control contra factura/i }))
  await user.type(screen.getByTitle('Lo que la factura declara de impuesto interno para esta alícuota'), DECLARADO)
}

beforeEach(() => {
  mocks.conceptos = CONCEPTOS
  mocks.plantillas = {}
  localStorage.clear()
})

describe('ModalCompra · bonificación no descontada (#908)', () => {
  it('sugiere la bonificación en la sección de cargos y, al aceptarla, la agrega sólo sobre la Cola', async () => {
    const { user, onSave } = renderModal()
    await cargarFactura(user)

    const tarjeta = await screen.findByRole('status', { name: /bonificación no descontada al 8,6957%/i })
    expect(tarjeta).toHaveTextContent(/parece una bonificación no descontada de \$\s?20\.000/)
    expect(tarjeta).toHaveTextContent('Cola 3L x6')
    expect(tarjeta).not.toHaveTextContent('Soda')

    await user.click(within(tarjeta).getByRole('button', { name: 'Agregar bonificación' }))
    expect(screen.queryByRole('status', { name: /bonificación no descontada/i })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))
    expect(onSave).toHaveBeenCalledTimes(1)
    const cargos = onSave.mock.calls[0][0].cargos!
    expect(cargos).toHaveLength(1)
    expect(cargos[0]).toMatchObject({
      concepto: 'Bonificación', conceptoId: '13', condicionIva: 'gravado', enFactura: true,
      baseProrrateo: 'monto', afectaBaseII: false,
    })
    expect(Math.abs(cargos[0].monto + 20_000)).toBeLessThan(0.1)
    // Índice 0 = Cola (pesa su neto), índice 1 = Soda (fuera).
    expect(cargos[0].pesos).toEqual({ 0: 500_000, 1: 0 })
  })

  it('"Descartar" la oculta y no agrega nada', async () => {
    const { user, onSave } = renderModal()
    await cargarFactura(user)

    const tarjeta = await screen.findByRole('status', { name: /bonificación no descontada/i })
    await user.click(within(tarjeta).getByRole('button', { name: 'Descartar' }))
    expect(screen.queryByRole('status', { name: /bonificación no descontada/i })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0].cargos ?? []).toEqual([])
  })
})
