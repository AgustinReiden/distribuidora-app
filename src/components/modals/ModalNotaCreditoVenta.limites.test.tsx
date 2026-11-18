/**
 * B23 de #1603 (decisión del dueño, 18/11): la cantidad a acreditar de una nota de crédito de venta
 * sobre lo que queda de la línea queda en rojo, con lo que queda en el motivo, y la nota no se
 * emite. Antes el blur del toque en «Emitir nota de crédito» la recortaba a lo disponible.
 *
 * Archivo aparte del test del modal (que cambia otra tarjeta, B22): sólo el límite.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mutateAsync = vi.fn()
vi.mock('../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaPedidoQuery: () => ({ data: [], isLoading: false }),
  useCrearNotaCreditoVentaMutation: () => ({ mutateAsync, isPending: false }),
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
import type { PedidoDB } from '../../types'

const pedido = {
  id: '100',
  cliente_id: '200',
  estado: 'entregado',
  cliente: { nombre_fantasia: 'Kiosco de prueba' },
  items: [
    { id: '300', producto_id: '11', cantidad: 2, precio_unitario: 5600, producto: { nombre: 'Arroz' } },
  ],
} as unknown as PedidoDB

const emitir = (): HTMLElement => screen.getByRole('button', { name: /Emitir nota de crédito/ })

describe('ModalNotaCreditoVenta — la cantidad fuera de su límite (B23)', () => {
  beforeEach(() => {
    mutateAsync.mockReset()
    mutateAsync.mockResolvedValue({ nota_credito_id: 1, pago_id: 901, total: 11200 })
  })

  it('más de lo que queda de la línea queda en rojo, lo dice y no se emite', async () => {
    const user = userEvent.setup()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    const input = screen.getByLabelText('Cantidad a acreditar de Arroz')

    await user.clear(input)
    await user.type(input, '5')
    await user.click(emitir())

    expect(mutateAsync).not.toHaveBeenCalled()
    expect(input).toHaveValue('5')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Quedan 2 para acreditar')
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })

  it('hasta lo que queda emite lo tipeado, sin salir antes del campo', async () => {
    const user = userEvent.setup()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    const input = screen.getByLabelText('Cantidad a acreditar de Arroz')

    await user.clear(input)
    await user.type(input, '2')
    await user.click(emitir())

    expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ items: [{ pedido_item_id: 300, cantidad: 2 }] }))
  })
})
