/**
 * #867 (mig 280) — ModalNotaCredito: la devolución muestra y manda el II de lo
 * devuelto, y el ajuste sin mercadería arma su payload sin items (FC: neto, IVA
 * e II; ZZ: sólo el total) y exige motivo. Datos sintéticos.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalNotaCredito from './ModalNotaCredito'
import type { ModalNotaCreditoProps } from './ModalNotaCredito'

// A: 10 u. x 100, tasa II 10% (teórico 100) · B: 5 u. x 200 sin II · cabecera 105
const compraFC: ModalNotaCreditoProps['compra'] = {
  id: '313',
  numero_factura: 'A-0001-00000001',
  tipo_factura: 'FC',
  impuestos_internos: 105,
  items: [
    { id: '1', producto_id: '10', producto: { id: '10', nombre: 'Agua' }, cantidad: 10, costo_unitario: 100, subtotal: 1000, impuestos_internos: 10, porcentaje_iva: 21, condicion_iva: 'gravado' },
    { id: '2', producto_id: '11', producto: { id: '11', nombre: 'Soda' }, cantidad: 5, costo_unitario: 200, subtotal: 1000, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
  ],
}

function renderModal(compra = compraFC) {
  const onSave = vi.fn().mockResolvedValue(undefined)
  render(<ModalNotaCredito compra={compra} notasExistentes={[]} onSave={onSave} onClose={() => {}} />)
  return onSave
}

const guardar = () => screen.getByRole('button', { name: 'Guardar' })

describe('ModalNotaCredito — devolución', () => {
  it('muestra el II de lo devuelto y lo suma al total', async () => {
    const onSave = renderModal()
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Agua'), { target: { value: '4' } })
    // 4/10 de A -> 40% de la cabecera (105) = 42
    expect(screen.getByTestId('nc-ii')).toHaveTextContent('42')
    // 400 + 84 IVA + 42 II
    expect(screen.getByTestId('nc-total')).toHaveTextContent('526')
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({
      compraId: '313', subtotal: 400, iva: 84, impuestosInternos: 42, total: 526,
      items: [{ productoId: '10', cantidad: 4, costoUnitario: 100, subtotal: 400 }],
    })
  })

  it('un producto sin II no muestra la fila', () => {
    renderModal()
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Soda'), { target: { value: '1' } })
    expect(screen.queryByTestId('nc-ii')).toBeNull()
  })

  it('sin cantidades no se puede guardar', () => {
    renderModal()
    expect(guardar()).toBeDisabled()
  })
})

describe('ModalNotaCredito — ajuste sin mercadería', () => {
  it('FC: neto, IVA (21% por defecto) e II, sin items, y exige motivo', async () => {
    const onSave = renderModal()
    fireEvent.click(screen.getByRole('button', { name: 'Ajuste sin mercadería' }))
    expect(screen.queryByLabelText('Cantidad a acreditar de Agua')).toBeNull()

    fireEvent.change(screen.getByLabelText('Neto'), { target: { value: '1000' } })
    fireEvent.change(screen.getByLabelText('Impuestos internos'), { target: { value: '50' } })
    // 1000 + 210 + 50
    expect(screen.getByTestId('nc-total')).toHaveTextContent('1.260')
    expect(guardar()).toBeDisabled()

    fireEvent.change(screen.getByLabelText('Motivo (obligatorio)'), { target: { value: 'II mal liquidado' } })
    expect(guardar()).toBeEnabled()
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({
      compraId: '313', motivo: 'II mal liquidado',
      subtotal: 1000, iva: 210, impuestosInternos: 50, total: 1260, items: [],
    })
  })

  it('FC: el IVA tipeado a mano gana sobre el 21%', async () => {
    const onSave = renderModal()
    fireEvent.click(screen.getByRole('button', { name: 'Ajuste sin mercadería' }))
    fireEvent.change(screen.getByLabelText('Neto'), { target: { value: '1000' } })
    fireEvent.change(screen.getByLabelText('IVA'), { target: { value: '105' } })
    fireEvent.change(screen.getByLabelText('Motivo (obligatorio)'), { target: { value: 'Descuento' } })
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({ subtotal: 1000, iva: 105, total: 1105 })
  })

  it('ZZ: sólo el total, sin IVA ni II', async () => {
    const onSave = renderModal({ ...compraFC, tipo_factura: 'ZZ', impuestos_internos: 0 })
    fireEvent.click(screen.getByRole('button', { name: 'Ajuste sin mercadería' }))
    expect(screen.queryByLabelText('IVA')).toBeNull()
    fireEvent.change(screen.getByLabelText('Total que acredita el proveedor'), { target: { value: '300' } })
    fireEvent.change(screen.getByLabelText('Motivo (obligatorio)'), { target: { value: 'Bonificación fin de mes' } })
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({
      subtotal: 300, iva: 0, impuestosInternos: 0, total: 300, items: [],
    })
  })
})
