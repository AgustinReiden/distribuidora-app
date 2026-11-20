/**
 * H6(a) de la revisión de C7: en las dos notas de crédito, si lo que queda por acreditar baja a 0 con un
 * valor ya cargado (otra nota entró mientras el modal estaba abierto y las notas se volvieron a leer), el
 * campo queda en rojo (H5) y estaba DESHABILITADO por `max <= 0`: «Ir al campo» no podía darle el foco y no
 * se podía corregir el valor. Un campo con un valor en rojo no puede quedar deshabilitado: sólo se
 * deshabilita el que no tiene nada cargado.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

let notasPedido: unknown[] = []
vi.mock('../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaPedidoQuery: () => ({ data: notasPedido, isLoading: false }),
  useCrearNotaCreditoVentaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../hooks/queries/useImputarCreditoQuery', () => ({
  usePedidosParaImputarQuery: () => ({ data: [], isLoading: false, error: null }),
  usePedidoOrigenNCQuery: () => ({ data: undefined, isLoading: false }),
  useImputarCreditoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ModalNotaCreditoVenta from './ModalNotaCreditoVenta'
import ModalNotaCredito from './ModalNotaCredito'
import type { ModalNotaCreditoProps } from './ModalNotaCredito'
import type { PedidoDB } from '../../types'

const pedido = {
  id: '100',
  cliente_id: '200',
  estado: 'entregado',
  cliente: { nombre_fantasia: 'Kiosco de prueba' },
  items: [
    { id: '300', producto_id: '11', cantidad: 2, precio_unitario: 5600, producto: { nombre: 'Arroz' } },
    { id: '301', producto_id: '12', cantidad: 3, precio_unitario: 1000, producto: { nombre: 'Fideos' } },
  ],
} as unknown as PedidoDB

const compra: ModalNotaCreditoProps['compra'] = {
  id: '313',
  numero_factura: 'A-0001-00000001',
  tipo_factura: 'FC',
  impuestos_internos: 0,
  items: [
    { id: '1', producto_id: '10', producto: { id: '10', nombre: 'Agua' }, cantidad: 10, costo_unitario: 100, subtotal: 1000, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
  ],
}

beforeEach(() => {
  notasPedido = []
})

describe('ModalNotaCreditoVenta · el límite baja a 0 con un valor cargado (H6a)', () => {
  it('el campo queda en rojo y se puede corregir (no está deshabilitado)', async () => {
    const user = userEvent.setup()
    const { rerender } = render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    await user.selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
    const input = screen.getByLabelText('Cantidad a acreditar de Arroz')
    await user.clear(input)
    await user.type(input, '2')
    await user.tab()
    expect(input).not.toHaveAttribute('aria-invalid', 'true')

    // Otra nota acreditó las 2 unidades mientras el modal estaba abierto.
    notasPedido = [{ id: '1', fecha: '2026-11-10', anulada: false, items: [{ pedido_item_id: '300', cantidad: 2, subtotal: 11200 }] }]
    rerender(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)

    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(input).toBeEnabled()
    await user.clear(input)
    await user.type(input, '0')
    await user.tab()
    expect(input).not.toHaveAttribute('aria-invalid', 'true')
  })

  it('sin nada cargado, una línea sin disponible sigue deshabilitada', async () => {
    notasPedido = [{ id: '1', fecha: '2026-11-10', anulada: false, items: [{ pedido_item_id: '300', cantidad: 2, subtotal: 11200 }] }]
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    await userEvent.setup().selectOptions(screen.getByRole('combobox'), 'cliente_rechaza')
    expect(screen.getByLabelText('Cantidad a acreditar de Arroz')).toBeDisabled()
  })
})

describe('ModalNotaCredito (compra) · el límite baja a 0 con un valor cargado (H6a)', () => {
  const notaQueAcredita = (cantidad: number) => [{
    id: '9', compra_id: '313', fecha: '2026-11-10', subtotal: 100 * cantidad, iva: 0, total: 100 * cantidad,
    tipo: 'devolucion', items: [{ producto_id: '10', cantidad }],
  }] as unknown as ModalNotaCreditoProps['notasExistentes']

  it('el campo queda en rojo y se puede corregir (no está deshabilitado)', async () => {
    const user = userEvent.setup()
    const props = { compra, onSave: vi.fn(), onClose: () => {} }
    const { rerender } = render(<ModalNotaCredito {...props} notasExistentes={[]} />)
    const input = screen.getByLabelText('Cantidad a acreditar de Agua')
    await user.clear(input)
    await user.type(input, '4')
    await user.tab()
    expect(input).not.toHaveAttribute('aria-invalid', 'true')

    rerender(<ModalNotaCredito {...props} notasExistentes={notaQueAcredita(10)} />)

    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(input).toBeEnabled()
    await user.clear(input)
    await user.type(input, '0')
    await user.tab()
    expect(input).not.toHaveAttribute('aria-invalid', 'true')
  })

  it('sin nada cargado, una línea sin disponible sigue deshabilitada', () => {
    render(<ModalNotaCredito compra={compra} notasExistentes={notaQueAcredita(10)} onSave={vi.fn()} onClose={() => {}} />)
    expect(screen.getByLabelText('Cantidad a acreditar de Agua')).toBeDisabled()
  })
})
