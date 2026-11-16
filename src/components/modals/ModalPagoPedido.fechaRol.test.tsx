/**
 * FRV-2 (#1598): el server sólo deja a un admin registrar un cobro con otra fecha
 * que hoy («Solo un admin puede registrar un pago con otra fecha que hoy»). El modal
 * se la ofrecía igual al encargado, y en «Entregar y registrar pago» la entrega ya
 * había quedado marcada cuando el cobro fallaba. Quien no es admin ve la fecha de hoy
 * fija; el admin la elige, dentro de lo que ya dejaba el modal.
 */
import React from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, waitFor, fireEvent, cleanup } from '@testing-library/react'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalPagoPedido, { type ModalPagoPedidoProps } from './ModalPagoPedido'
import { fechaLocalISO } from '../../utils/formatters'
import type { PedidoDB } from '../../types'

const pedido = { id: '4625', cliente_id: '1', total: 21600 } as unknown as PedidoDB

function renderModal(extra: Partial<ModalPagoPedidoProps> = {}) {
  return render(
    <ModalPagoPedido
      pedido={pedido}
      pagosPrevios={[]}
      onConfirmar={vi.fn().mockResolvedValue(undefined)}
      onEntregarSinPago={vi.fn().mockResolvedValue(undefined)}
      modoEntregaTransportista
      onClose={vi.fn()}
      guardando={false}
      {...extra}
    />,
  )
}

const inputFecha = (): HTMLInputElement => screen.getByLabelText(/fecha de entrega y pago/i) as HTMLInputElement
const inputMonto = (): HTMLInputElement =>
  screen.getAllByPlaceholderText(/0[.,]00/i)[0] as HTMLInputElement

/** Un día anterior a hoy, en el mismo formato que `fechaLocalISO`. */
function ayer(): string {
  const d = new Date(`${fechaLocalISO()}T12:00:00`)
  d.setDate(d.getDate() - 1)
  return fechaLocalISO(d)
}

afterEach(cleanup)

describe('ModalPagoPedido — la fecha del cobro según el rol (FRV-2)', () => {
  it('quien no es admin ve la fecha de hoy y no puede cambiarla', () => {
    renderModal({ isAdmin: false })
    const input = inputFecha()
    expect(input.value).toBe(fechaLocalISO())
    expect(input.disabled).toBe(true)
    expect(input.min).toBe(fechaLocalISO())
    expect(input.max).toBe(fechaLocalISO())
    expect(screen.getByText(/solo podés registrar el cobro con la fecha de hoy/i)).toBeTruthy()
  })

  it('sin el prop se asume que no es admin', () => {
    renderModal()
    expect(inputFecha().disabled).toBe(true)
  })

  it('el cobro de quien no es admin viaja con la fecha de hoy', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, onConfirmar })
    await waitFor(() => expect(inputMonto().value).toBe('21600'))
    // Aunque alguien fuerce el valor del input, la fecha que viaja es la de hoy.
    fireEvent.change(inputFecha(), { target: { value: ayer() } })
    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))

    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].fechaPago).toBe(fechaLocalISO())
  })

  it('la entrega a cuenta corriente de quien no es admin también va con hoy', async () => {
    const onEntregarSinPago = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, onEntregarSinPago })
    fireEvent.change(inputFecha(), { target: { value: ayer() } })
    fireEvent.click(screen.getByRole('button', { name: /^entregar a cuenta corriente$/i }))

    await waitFor(() => expect(onEntregarSinPago).toHaveBeenCalledTimes(1))
    expect(onEntregarSinPago.mock.calls[0][0].fechaEntrega).toBe(fechaLocalISO())
  })

  it('el admin elige la fecha, hasta hoy', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: true, onConfirmar })
    const input = inputFecha()
    expect(input.disabled).toBe(false)
    expect(input.max).toBe(fechaLocalISO())
    expect(screen.queryByText(/solo podés registrar el cobro con la fecha de hoy/i)).toBeNull()

    await waitFor(() => expect(inputMonto().value).toBe('21600'))
    fireEvent.change(input, { target: { value: ayer() } })
    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))

    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].fechaPago).toBe(ayer())
  })
})
