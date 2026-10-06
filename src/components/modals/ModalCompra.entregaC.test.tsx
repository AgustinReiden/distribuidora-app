/**
 * ModalCompra, entrega C (mig 278): catálogo de conceptos, base 'medida',
 * "guardar en la ficha" y la plantilla automática del proveedor.
 *
 * Datos sintéticos.
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PlantillaCargosProveedor, ProductoDB, ProveedorDBExtended } from '../../types'
import type { ConceptoCargo, MedidaCargo, MedidasPorProducto } from '../../utils/medidasCargo'

const mocks = vi.hoisted(() => ({
  conceptos: [] as unknown[],
  medidas: [] as unknown[],
  ficha: {} as Record<string, Record<string, number>>,
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
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => ({
  useCargoConceptosQuery: () => ({ data: mocks.conceptos }),
  useCargoMedidasQuery: () => ({ data: mocks.medidas }),
  useProductoMedidasQuery: () => ({ data: mocks.ficha }),
}))
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('./ModalProveedor', () => ({ default: () => null }))
vi.mock('./ModalImportarCompra', () => ({ default: () => null }))

import ModalCompra, { type ModalCompraProps } from './ModalCompra'

type OnSave = NonNullable<ModalCompraProps['onSave']>

const MEDIDAS: MedidaCargo[] = [
  { id: '1', nombre: 'Pallet', unidadSingular: 'pallet', medidaBaseId: null, activo: true },
  { id: '2', nombre: 'Separador', unidadSingular: 'separador', medidaBaseId: null, activo: true },
  { id: '3', nombre: 'Lugar en el flete', unidadSingular: 'lugar', medidaBaseId: '1', activo: true },
]
const CONCEPTOS: ConceptoCargo[] = [
  { id: '10', nombre: 'Flete', signo: 1, condicionIva: 'no_gravado', enFactura: false, prorrateaAlCosto: true, baseProrrateo: 'medida', medidaId: '3', activo: true },
  { id: '11', nombre: 'Pallets', signo: 1, condicionIva: 'no_gravado', enFactura: true, prorrateaAlCosto: true, baseProrrateo: 'medida', medidaId: '1', activo: true },
  { id: '13', nombre: 'Bonificación', signo: -1, condicionIva: 'gravado', enFactura: true, prorrateaAlCosto: true, baseProrrateo: 'monto', medidaId: null, activo: true },
]

const PRODUCTOS = [
  { id: 'p1', nombre: 'Agua 600 x12', codigo: 'A600', stock: 0, costo_sin_iva: 100, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
  { id: 'p2', nombre: 'Agua 2L x6', codigo: 'A2L', stock: 0, costo_sin_iva: 200, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
] as unknown as ProductoDB[]
const PROVEEDORES = [
  { id: 'prov-1', nombre: 'Aguas del Sur', cuit: null },
  { id: 'prov-2', nombre: 'Otro Proveedor', cuit: null },
] as unknown as ProveedorDBExtended[]

function renderModal() {
  const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
  render(<ModalCompra productos={PRODUCTOS} proveedores={PROVEEDORES} onSave={onSave} onClose={vi.fn()} />)
  // `delay: null` (molde #821, ModalCompra.markup): sin el `setTimeout(0)` entre
  // tecla y tecla. Estos tests tipean decenas de campos sobre el modal entero
  // y tardan 3-6 s solos; con la máquina cargada pasaban de los 15 s de
  // `testTimeout` (#940).
  return { onSave, user: userEvent.setup({ delay: null }) }
}

type Usuario = ReturnType<typeof userEvent.setup>

async function elegirProveedor(user: Usuario, nombre: string) {
  const combo = screen.getByRole('combobox', { name: 'Proveedor de la factura' })
  await user.click(combo)
  await user.type(combo, nombre)
  await user.click(within(screen.getByRole('listbox', { name: 'Proveedor de la factura' })).getByRole('option', { name: new RegExp(nombre) }))
}

async function agregarProducto(user: Usuario, nombre: string, cantidad: number) {
  await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
  await user.click(screen.getByRole('button', { name: new RegExp(nombre) }))
  const input = screen.getAllByLabelText(`Cantidad de ${nombre}`)[0]
  await user.clear(input)
  await user.type(input, String(cantidad))
}

async function elegirConcepto(user: Usuario, nombre: string) {
  const combos = screen.getAllByRole('combobox', { name: 'Concepto del cargo' })
  const combo = combos[combos.length - 1]
  await user.click(combo)
  await user.type(combo, nombre)
  await user.click(within(screen.getByRole('listbox', { name: 'Concepto del cargo' })).getByRole('option', { name: new RegExp(`^${nombre}`) }))
}

const registrar = (user: Usuario) => user.click(screen.getByRole('button', { name: /registrar compra/i }))

beforeEach(() => {
  mocks.conceptos = CONCEPTOS
  mocks.medidas = MEDIDAS
  mocks.ficha = { p1: { '1': 120 } } as MedidasPorProducto<number>
  mocks.plantillas = {}
  localStorage.clear()
})

describe('ModalCompra · catálogo de conceptos (mig 278)', () => {
  it('elegir un concepto precarga sus defaults y todo queda editable', async () => {
    const { user, onSave } = renderModal()
    await elegirProveedor(user, 'Otro Proveedor')
    await agregarProducto(user, 'Agua 600 x12', 240)
    await user.click(screen.getByRole('button', { name: /cargos y prorrateo/i }))
    await user.click(screen.getByRole('button', { name: /agregar cargo/i }))
    await elegirConcepto(user, 'Bonificación')

    // El toggle quedó en "−" y la condición en gravado.
    expect(screen.getByRole('button', { name: '−', pressed: true })).toBeInTheDocument()
    expect(screen.getByDisplayValue('Gravado')).toBeInTheDocument()

    // Editable: se cambia la condición a mano después de elegir.
    const monto = screen.getByLabelText('Monto de Bonificación')
    await user.clear(monto)
    await user.type(monto, '50')
    await user.selectOptions(screen.getByDisplayValue('Gravado'), 'exento')
    await registrar(user)

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0].cargos).toEqual([
      expect.objectContaining({ concepto: 'Bonificación', conceptoId: '13', monto: -50, condicionIva: 'exento', baseProrrateo: 'monto' }),
    ])
  })
})

describe('ModalCompra · base medida (mig 278)', () => {
  async function conPallets(user: Usuario) {
    await elegirProveedor(user, 'Otro Proveedor')
    await agregarProducto(user, 'Agua 600 x12', 240)
    await agregarProducto(user, 'Agua 2L x6', 160)
    await user.click(screen.getByRole('button', { name: /cargos y prorrateo/i }))
    await user.click(screen.getByRole('button', { name: /agregar cargo/i }))
    await elegirConcepto(user, 'Pallets')
    const monto = screen.getByLabelText('Monto de Pallets')
    await user.clear(monto)
    await user.type(monto, '1000')
  }

  it('una línea sin medida bloquea el guardado; con u/pallet tipeadas pasa y va a la ficha', async () => {
    const { user, onSave } = renderModal()
    await conPallets(user)

    // La línea con ficha ya muestra sus pallets; la otra pide el dato.
    expect(screen.getByTestId('medida-linea')).toHaveTextContent('2 pallets (120 u/pallet)')
    expect(screen.getByTestId('medida-faltante')).toBeInTheDocument()

    await registrar(user)
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText(/no sabe cuántas unidades entran de "Agua 2L x6"/)).toBeInTheDocument()

    // u/pallet para el 2L: la ficha no tenía, así que "guardar en la ficha" arranca marcado.
    const u = screen.getByLabelText('Unidades por pallet de Agua 2L x6')
    await user.clear(u)
    await user.type(u, '80')
    const guardar = screen.getByRole('checkbox', { name: /guardar en la ficha/ })
    expect(guardar).toBeChecked()

    await registrar(user)
    expect(onSave).toHaveBeenCalledTimes(1)
    const payload = onSave.mock.calls[0][0]
    expect(payload.cargos).toEqual([
      expect.objectContaining({ concepto: 'Pallets', baseProrrateo: 'medida', medidaId: '1', conceptoId: '11', pesos: { 0: 2, 1: 2 } }),
    ])
    expect(payload.medidasFicha).toEqual([{ productoId: 'p2', medidaId: '1', unidadesPor: 80 }])
  })

  it('tipear los pallets deriva las u/pallet; si la ficha tenía valor, el check arranca desmarcado', async () => {
    const { user, onSave } = renderModal()
    await conPallets(user)

    // Excluir el 2L con 0 (la salida explícita) y tipear 3 pallets para el 600.
    const pesos = screen.getAllByLabelText(/^Pallets de /)
    // Dos layouts (mobile, desktop) por línea: [600m, 2Lm, 600d, 2Ld] → por label.
    const del2L = screen.getAllByLabelText('Pallets de Agua 2L x6')[0]
    await user.clear(del2L)
    await user.type(del2L, '0')
    const del600 = screen.getAllByLabelText('Pallets de Agua 600 x12')[0]
    await user.clear(del600)
    await user.type(del600, '3')
    expect(pesos.length).toBe(4)

    const guardar = screen.getByRole('checkbox', { name: /guardar en la ficha/ })
    expect(guardar).not.toBeChecked()

    await registrar(user)
    expect(onSave).toHaveBeenCalledTimes(1)
    const payload = onSave.mock.calls[0][0]
    expect(payload.cargos?.[0].pesos).toEqual({ 0: 3, 1: 0 })
    // Desmarcado: no reescribe la ficha.
    expect(payload.medidasFicha).toEqual([])
  })
})

describe('ModalCompra · plantilla automática del proveedor (mig 278)', () => {
  const plantilla: PlantillaCargosProveedor = {
    compraId: '900',
    numeroFactura: 'A-0001-00000123',
    fechaCompra: '2026-09-01',
    cargos: [
      { concepto: 'Flete', conceptoId: '10', medidaId: '3', condicionIva: 'no_gravado', enFactura: false, prorrateaAlCosto: true, afectaBaseII: false, baseProrrateo: 'medida', pesosPorProducto: { p1: 2 } },
      { concepto: 'Separadores', condicionIva: 'no_gravado', enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, baseProrrateo: 'cantidad', pesosPorProducto: { p1: 5, p2: 5 } },
    ],
  }

  it('precarga los cargos al elegir el proveedor y pregunta por los que quedaron sin monto', async () => {
    mocks.plantillas = { 'prov-1': plantilla }
    const { user, onSave } = renderModal()
    await elegirProveedor(user, 'Aguas del Sur')
    await agregarProducto(user, 'Agua 600 x12', 240)
    await agregarProducto(user, 'Agua 2L x6', 160)
    await user.click(screen.getByRole('button', { name: /cargos y prorrateo/i }))
    expect(screen.getByText(/Precargados de la factura A-0001-00000123/)).toBeInTheDocument()
    expect(screen.getAllByRole('combobox', { name: 'Concepto del cargo' }).map(c => (c as HTMLInputElement).value))
      .toEqual(['Flete', 'Separadores'])

    // Al flete se le pone monto; Separadores queda en 0.
    const monto = screen.getByLabelText('Monto de Flete')
    await user.clear(monto)
    await user.type(monto, '900')
    await registrar(user)
    expect(onSave).not.toHaveBeenCalled()
    const pregunta = screen.getByRole('alertdialog', { name: 'Cargos sin monto' })
    expect(pregunta).toHaveTextContent('Separadores sin monto: ¿quitar?')

    await user.click(within(pregunta).getByRole('button', { name: 'Quitar y registrar' }))
    expect(onSave).toHaveBeenCalledTimes(1)
    // Sólo el flete, que pesa en el 600 (2 pallets, de la ficha vía la base) y
    // NO en el 2L, que no estaba en la plantilla.
    expect(onSave.mock.calls[0][0].cargos).toEqual([
      expect.objectContaining({ concepto: 'Flete', conceptoId: '10', medidaId: '3', baseProrrateo: 'medida', pesos: { 0: 2, 1: 0 } }),
    ])
  })

  it('cambiar de proveedor reemplaza sólo los cargos de plantilla sin tocar', async () => {
    mocks.plantillas = { 'prov-1': plantilla, 'prov-2': { ...plantilla, cargos: [] } }
    const { user } = renderModal()
    await elegirProveedor(user, 'Aguas del Sur')
    await agregarProducto(user, 'Agua 600 x12', 240)
    await user.click(screen.getByRole('button', { name: /cargos y prorrateo/i }))
    const monto = screen.getByLabelText('Monto de Flete')
    await user.clear(monto)
    await user.type(monto, '900')

    await elegirProveedor(user, 'Otro Proveedor')
    expect(screen.getAllByRole('combobox', { name: 'Concepto del cargo' }).map(c => (c as HTMLInputElement).value))
      .toEqual(['Flete'])
  })
})
