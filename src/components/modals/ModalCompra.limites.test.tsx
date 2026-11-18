/**
 * B23 de #1603 (decisión del dueño, 18/11): en la carga de una compra, la cantidad de un renglón
 * vacía o en 0 y una bonificación sobre 100 % quedan en rojo, con su motivo, y la compra no se
 * registra. Antes el blur del toque en «Registrar compra» recortaba: la bonificación de 150 se
 * guardaba 100 % y la cantidad vacía se guardaba 1. La bonificación global tampoco se aplica en rojo.
 *
 * Datos sintéticos.
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB, ProveedorDBExtended } from '../../types'

vi.mock('../../lib/supabase', () => ({
  supabase: { storage: { from: vi.fn() }, rpc: vi.fn(), from: vi.fn() },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null, isSuccess: true }),
  useCostosAnterioresQuery: () => ({ data: undefined }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
}))
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  const medidas: unknown[] = [], ficha = {}, conceptos: unknown[] = []
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

type OnSave = NonNullable<ModalCompraProps['onSave']>
type Usuario = ReturnType<typeof userEvent.setup>

const PRODUCTOS = [
  { id: 'p1', nombre: 'Soda de prueba', codigo: 'S1', stock: 0, costo_sin_iva: 1500, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
] as unknown as ProductoDB[]
const PROVEEDORES = [{ id: 'prov-1', nombre: 'Proveedor de prueba', cuit: null }] as unknown as ProveedorDBExtended[]

function renderModal() {
  const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
  render(<ModalCompra productos={PRODUCTOS} proveedores={PROVEEDORES} onSave={onSave} onClose={vi.fn()} />)
  return { onSave, user: userEvent.setup() }
}

async function cargarRenglon(user: Usuario) {
  const combo = screen.getByRole('combobox', { name: 'Proveedor de la factura' })
  await user.click(combo)
  await user.type(combo, 'Proveedor')
  await user.click(within(screen.getByRole('listbox', { name: 'Proveedor de la factura' })).getByRole('option', { name: /Proveedor de prueba/ }))
  await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
  await user.click(screen.getByRole('button', { name: /Soda de prueba/ }))
}

const registrar = (): HTMLElement => screen.getByRole('button', { name: /registrar compra/i })

beforeEach(() => localStorage.clear())

describe('ModalCompra — la cantidad y la bonificación fuera de su límite (B23)', () => {
  it.each([
    ['cantidad vacía', 'Cantidad de Soda de prueba', '', 'Poné una cantidad'],
    ['cantidad 0', 'Cantidad de Soda de prueba', '0', 'El mínimo es 1'],
    ['bonificación 150', 'Bonificación de Soda de prueba', '150', 'No puede pasar de 100 %'],
  ])('%s: queda en rojo con su motivo y la compra no se registra', async (_caso, campo, texto, motivo) => {
    const { onSave, user } = renderModal()
    await cargarRenglon(user)
    const input = screen.getAllByLabelText(campo)[0]

    await user.clear(input)
    if (texto) await user.type(input, texto)
    await user.click(registrar())

    expect(onSave).not.toHaveBeenCalled()
    expect(input).toHaveValue(texto)
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent(motivo)
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })

  it('dentro del límite registra lo tipeado, sin salir antes del campo', async () => {
    const { onSave, user } = renderModal()
    await cargarRenglon(user)

    await user.clear(screen.getAllByLabelText('Cantidad de Soda de prueba')[0])
    await user.type(screen.getAllByLabelText('Cantidad de Soda de prueba')[0], '40')
    await user.clear(screen.getAllByLabelText('Bonificación de Soda de prueba')[0])
    await user.type(screen.getAllByLabelText('Bonificación de Soda de prueba')[0], '100')
    await user.click(registrar())

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0].items[0]).toMatchObject({ cantidad: 40, bonificacion: 100 })
  })

  it('la bonificación global sobre 100 % queda en rojo y «Aplicar» no aplica el valor de antes', async () => {
    const { user } = renderModal()
    await cargarRenglon(user)
    const global = screen.getByLabelText('Bonificación global (%)')

    await user.clear(global)
    await user.type(global, '150')

    expect(global).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('No puede pasar de 100 %')
    expect(screen.getByRole('button', { name: 'Aplicar' })).toBeDisabled()
  })
})
