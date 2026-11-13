/**
 * #1560: cada línea de cobro muestra el monto leído antes de confirmar. Antes «150.000» se
 * registraba como $150 y la boleta quedaba casi entera sin cobrar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor, fireEvent, within } from '@testing-library/react'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalPagoPedido from './ModalPagoPedido'
import type { PedidoDB, PerfilDB } from '../../types'

const pedido = { id: '4625', cliente_id: '1', total: 300000 } as unknown as PedidoDB
const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]

const inputMonto = (): HTMLInputElement => screen.getAllByPlaceholderText(/0[.,]00/i)[0] as HTMLInputElement

describe('ModalPagoPedido · el monto leído', () => {
  it('«150.000» se muestra como $ 150.000,00 y se registra 150000', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    render(
      <ModalPagoPedido
        pedido={pedido}
        pagosPrevios={[]}
        onConfirmar={onConfirmar}
        modoEntregaTransportista
        onEntregarSinPago={vi.fn()}
        transportistas={choferes}
        permitirRetiro
        onClose={vi.fn()}
        guardando={false}
      />,
    )
    await waitFor(() => expect(inputMonto().value).toBe('300000'))

    fireEvent.change(inputMonto(), { target: { value: '150.000' } })

    const linea = inputMonto().closest('div.flex-1') as HTMLElement
    expect(within(linea).getByText(/Se registra:/)).toHaveTextContent(/150\.000,00/)

    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].pagos).toEqual([{ formaPago: 'efectivo', monto: 150000 }])
  })
})
