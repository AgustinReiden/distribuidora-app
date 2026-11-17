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
  it('FC: neto, IVA cargado e II, sin items, y exige motivo', async () => {
    const onSave = renderModal()
    fireEvent.click(screen.getByRole('button', { name: 'Ajuste sin mercadería' }))
    expect(screen.queryByLabelText('Cantidad a acreditar de Agua')).toBeNull()

    fireEvent.change(screen.getByLabelText('Neto'), { target: { value: '1000' } })
    fireEvent.change(screen.getByLabelText('IVA'), { target: { value: '210' } })
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

  it('FC: el IVA no se propone (#1380): vacío, avisa qué falta y no deja guardar', () => {
    renderModal()
    fireEvent.click(screen.getByRole('button', { name: 'Ajuste sin mercadería' }))
    fireEvent.change(screen.getByLabelText('Neto'), { target: { value: '1000' } })
    fireEvent.change(screen.getByLabelText('Motivo (obligatorio)'), { target: { value: 'Descuento' } })
    expect(screen.getByLabelText('IVA')).toHaveValue('')
    expect(screen.getByRole('alert')).toHaveTextContent('Falta cargar el IVA')
    // Sin los 210 que proponía el 21%: el total es el neto.
    expect(screen.getByTestId('nc-total')).toHaveTextContent('1.000')
    expect(guardar()).toBeDisabled()
  })

  it('FC: el IVA cargado en 0 (compra exenta) se guarda en 0', async () => {
    const onSave = renderModal()
    fireEvent.click(screen.getByRole('button', { name: 'Ajuste sin mercadería' }))
    fireEvent.change(screen.getByLabelText('Neto'), { target: { value: '1000' } })
    fireEvent.change(screen.getByLabelText('IVA'), { target: { value: '0' } })
    fireEvent.change(screen.getByLabelText('Motivo (obligatorio)'), { target: { value: 'Bonificación' } })
    expect(guardar()).toBeEnabled()
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({ subtotal: 1000, iva: 0, total: 1000 })
  })

  it('FC al 10,5: guarda el IVA que se cargó, no el 21%', async () => {
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

describe('ModalNotaCredito — tope del ajuste (#1557, CMP-2)', () => {
  // ZZ de 10 x 121 = 1.210, con una nota de 1.000 ya cargada: le quedan 210.
  const compraZZ: ModalNotaCreditoProps['compra'] = {
    ...compraFC, tipo_factura: 'ZZ', impuestos_internos: 0, total: 1210,
  }
  const notas = [{ id: '9', compra_id: '313', fecha: '2026-11-12', subtotal: 1000, iva: 0, total: 1000, tipo: 'ajuste' as const }]

  function renderAjuste() {
    const onSave = vi.fn().mockResolvedValue(undefined)
    render(<ModalNotaCredito compra={compraZZ} notasExistentes={notas} onSave={onSave} onClose={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: 'Ajuste sin mercadería' }))
    fireEvent.change(screen.getByLabelText('Motivo (obligatorio)'), { target: { value: 'Diferencia de precio' } })
    return onSave
  }

  it('un ajuste mayor que lo que le queda a la compra no se puede guardar, y lo dice', () => {
    const onSave = renderAjuste()
    fireEvent.change(screen.getByLabelText('Total que acredita el proveedor'), { target: { value: '50000' } })
    expect(screen.getByTestId('nc-ajuste-restante')).toHaveTextContent('Supera lo que le queda a la compra')
    expect(screen.getByTestId('nc-ajuste-restante')).toHaveTextContent('210')
    expect(guardar()).toBeDisabled()
    fireEvent.click(guardar())
    expect(onSave).not.toHaveBeenCalled()
  })

  it('hasta lo que le queda, se guarda', async () => {
    const onSave = renderAjuste()
    fireEvent.change(screen.getByLabelText('Total que acredita el proveedor'), { target: { value: '210' } })
    expect(screen.getByTestId('nc-ajuste-restante')).toHaveTextContent('Le quedan')
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({ total: 210, items: [] })
  })
})

describe('ModalNotaCredito — aviso de la devolución cuando hay un ajuste (#1590-c)', () => {
  // 10 u. x 100 sin IVA = 1.000. Con un ajuste de 800 le quedan 200: la devolución no puede pasarlos.
  const compra: ModalNotaCreditoProps['compra'] = {
    id: '400', numero_factura: 'A-0001-00000400', tipo_factura: 'FC', impuestos_internos: 0, total: 1000,
    items: [
      { id: '1', producto_id: '10', producto: { id: '10', nombre: 'Agua' }, cantidad: 10, costo_unitario: 100, subtotal: 1000, impuestos_internos: 0, porcentaje_iva: 0, condicion_iva: 'exento' },
    ],
  }
  const nota = (tipo: 'ajuste' | 'devolucion', total: number) =>
    ({ id: '9', compra_id: '400', fecha: '2026-11-12', subtotal: total, iva: 0, total, tipo })

  function renderDevolucion(notas: ReturnType<typeof nota>[]) {
    const onSave = vi.fn().mockResolvedValue(undefined)
    render(<ModalNotaCredito compra={compra} notasExistentes={notas} onSave={onSave} onClose={() => {}} />)
    return onSave
  }
  const cantidad = (n: string) =>
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Agua'), { target: { value: n } })

  it('muestra lo que le queda a la compra y avisa si el total parece pasarlo, sin bloquear', async () => {
    const onSave = renderDevolucion([nota('ajuste', 800)])
    expect(screen.getByTestId('nc-devolucion-restante')).toHaveTextContent('Le quedan')
    expect(screen.getByTestId('nc-devolucion-restante')).toHaveTextContent('200')

    cantidad('3')
    expect(screen.getByTestId('nc-devolucion-restante')).toHaveTextContent('Puede superar lo que le queda a la compra')
    // Decide el server (neto de descuentos): el modal no bloquea.
    expect(guardar()).toBeEnabled()
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
  })

  it('con un descuento de cabecera el total bruto parece pasar, pero el server mide el neto y acepta: se puede guardar', async () => {
    // ZZ de 10 x 100 con un descuento de -150 en factura (total 850) y un ajuste de 100: le quedan 750.
    // Devolver 8 u. son 800 brutos (> 750), 680 netos (el server multiplica por 0,85): entra.
    const conDescuento: ModalNotaCreditoProps['compra'] = {
      ...compra, id: '401', tipo_factura: 'ZZ', total: 850,
    }
    const onSave = vi.fn().mockResolvedValue(undefined)
    render(<ModalNotaCredito compra={conDescuento} notasExistentes={[nota('ajuste', 100)]} onSave={onSave} onClose={() => {}} />)
    cantidad('8')
    expect(screen.getByTestId('nc-devolucion-restante')).toHaveTextContent('Puede superar')
    expect(guardar()).toBeEnabled()
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({ compraId: '401', total: 800 })
  })

  it('hasta lo que le queda, se guarda', async () => {
    const onSave = renderDevolucion([nota('ajuste', 800)])
    cantidad('2')
    expect(screen.getByTestId('nc-devolucion-restante')).toHaveTextContent('Le quedan')
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({ total: 200 })
  })

  it('sin un ajuste en la compra el tope no rige: devolver toda la mercadería entra siempre', async () => {
    const onSave = renderDevolucion([nota('devolucion', 100)])
    expect(screen.queryByTestId('nc-devolucion-restante')).toBeNull()
    cantidad('9')
    expect(guardar()).toBeEnabled()
    fireEvent.click(guardar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
  })
})
