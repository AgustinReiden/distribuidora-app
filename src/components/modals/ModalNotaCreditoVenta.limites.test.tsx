/**
 * B23 de #1603 (decisión del dueño, 18/11): la cantidad a acreditar de una nota de crédito de venta
 * sobre lo que queda de la línea queda en rojo, con lo que queda en el motivo, y la nota no se
 * emite. Antes el blur del toque en «Emitir nota de crédito» la recortaba a lo disponible.
 *
 * Archivo aparte del test del modal: sólo el límite. Desde B22 el motivo no viene elegido (sin él
 * «Emitir» está frenado por otra razón), así que cada caso elige uno: con un motivo que mueve
 * mercadería el renglón la pide (`mercaderia: true`).
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
const elegirMotivo = (user: ReturnType<typeof userEvent.setup>, motivo: string) =>
  user.selectOptions(screen.getByRole('combobox'), motivo)

describe('ModalNotaCreditoVenta — la cantidad fuera de su límite (B23)', () => {
  beforeEach(() => {
    mutateAsync.mockReset()
    mutateAsync.mockResolvedValue({ nota_credito_id: 1, pago_id: 901, total: 11200 })
  })

  it('más de lo que queda de la línea queda en rojo, lo dice y no se emite', async () => {
    const user = userEvent.setup()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    await elegirMotivo(user, 'cliente_rechaza')
    const input = screen.getByLabelText('Cantidad a acreditar de Arroz')
    await user.clear(input)
    await user.type(input, '1')
    // Con el motivo y una cantidad que entra, «Emitir» está habilitado: lo que lo frena después es el rojo.
    expect(emitir()).toBeEnabled()

    await user.clear(input)
    await user.type(input, '5')
    await user.click(emitir())

    expect(mutateAsync).not.toHaveBeenCalled()
    expect(emitir()).toBeDisabled()
    expect(input).toHaveValue('5')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Quedan 2 para acreditar')
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })

  it('hasta lo que queda emite lo tipeado, sin salir antes del campo', async () => {
    const user = userEvent.setup()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    await elegirMotivo(user, 'cliente_rechaza')
    const input = screen.getByLabelText('Cantidad a acreditar de Arroz')

    await user.clear(input)
    await user.type(input, '2')
    await user.click(emitir())

    expect(mutateAsync).toHaveBeenCalledTimes(1)
    expect(mutateAsync.mock.calls[0][0]).toMatchObject({
      motivo: 'cliente_rechaza',
      items: [{ pedido_item_id: 300, cantidad: 2, mercaderia: true }],
    })
  })

  it('por monto, más de lo que queda queda en rojo con el aviso y no se emite', async () => {
    const user = userEvent.setup()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    await elegirMotivo(user, 'descuento_comercial')
    const input = screen.getByLabelText('Monto del descuento')

    await user.type(input, '11200,01')
    await user.click(emitir())

    expect(mutateAsync).not.toHaveBeenCalled()
    expect(emitir()).toBeDisabled()
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByText(/Quedan .*11\.200,00 por acreditar/)).toBeInTheDocument()
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })
})
