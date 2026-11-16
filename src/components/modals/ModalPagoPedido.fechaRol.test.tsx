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

const inputFecha = (): HTMLInputElement => screen.getByLabelText(/fecha de (entrega y )?pago/i) as HTMLInputElement
const inputMonto = (): HTMLInputElement =>
  screen.getAllByPlaceholderText(/0[.,]00/i)[0] as HTMLInputElement

/** `dias` días antes de hoy, en el mismo formato que `fechaLocalISO`. */
function diasAtras(dias: number): string {
  const d = new Date(`${fechaLocalISO()}T12:00:00`)
  d.setDate(d.getDate() - dias)
  return fechaLocalISO(d)
}
const ayer = (): string => diasAtras(1)

afterEach(cleanup)

describe('ModalPagoPedido — la fecha del cobro según el rol (FRV-2)', () => {
  it('al registrar un pago, quien no es admin ve la fecha de hoy y no puede cambiarla', () => {
    renderModal({ isAdmin: false, modoEntregaTransportista: false, onEntregarSinPago: undefined })
    const input = inputFecha()
    expect(input.value).toBe(fechaLocalISO())
    expect(input.disabled).toBe(true)
    expect(input.min).toBe(fechaLocalISO())
    expect(input.max).toBe(fechaLocalISO())
    expect(screen.getByText(/solo podés registrar el cobro con la fecha de hoy/i)).toBeTruthy()
  })

  it('sin el prop se asume que no es admin', () => {
    renderModal({ modoEntregaTransportista: false, onEntregarSinPago: undefined })
    expect(inputFecha().disabled).toBe(true)
  })

  it('el cobro de quien no es admin viaja con la fecha de hoy', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, onConfirmar })
    await waitFor(() => expect(inputMonto().value).toBe('21600'))
    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))

    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].fechaPago).toBe(fechaLocalISO())
  })

  it('con otra fecha que hoy, quien no es admin no cobra: se le dice cómo hacerlo', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, onConfirmar })
    await waitFor(() => expect(inputMonto().value).toBe('21600'))
    fireEvent.change(inputFecha(), { target: { value: ayer() } })
    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))

    await waitFor(() => expect(screen.getByText(/el cobro va con la fecha de hoy\. si la entrega fue otro día/i)).toBeTruthy())
    expect(onConfirmar).not.toHaveBeenCalled()
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

/**
 * L6 (#1603): la entrega sin cobro tiene su propio rango (`fechaEntrega.ts`, GTO-15): quien
 * no es admin la fecha hasta `dias_atras_fecha_pedido` días atrás. El modal la dejaba fija en
 * hoy, junto con el cobro: el chofer que entregó ayer, fiado, no podía marcarlo.
 */
describe('ModalPagoPedido — la fecha de una entrega a cuenta corriente (L6)', () => {
  it('quien no es admin elige la fecha de la entrega dentro de su rango', () => {
    renderModal({ isAdmin: false, diasAtrasFechaEntrega: 3 })
    const input = inputFecha()
    expect(input.disabled).toBe(false)
    expect(input.min).toBe(diasAtras(3))
    expect(input.max).toBe(fechaLocalISO())
    expect(screen.getByText(/el cobro va con la fecha de hoy\. una entrega a cuenta corriente puede ir hasta 3 días atrás/i)).toBeTruthy()
  })

  it('la entrega a cuenta corriente de quien no es admin va con la fecha elegida', async () => {
    const onEntregarSinPago = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, diasAtrasFechaEntrega: 7, onEntregarSinPago })
    fireEvent.change(inputFecha(), { target: { value: ayer() } })
    fireEvent.click(screen.getByRole('button', { name: /^entregar a cuenta corriente$/i }))

    await waitFor(() => expect(onEntregarSinPago).toHaveBeenCalledTimes(1))
    expect(onEntregarSinPago.mock.calls[0][0].fechaEntrega).toBe(ayer())
  })

  it('fuera del rango no se entrega, con el motivo del server', async () => {
    const onEntregarSinPago = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, diasAtrasFechaEntrega: 0, onEntregarSinPago })
    fireEvent.change(inputFecha(), { target: { value: ayer() } })
    fireEvent.click(screen.getByRole('button', { name: /^entregar a cuenta corriente$/i }))

    await waitFor(() => expect(screen.getByText(/no puede ser anterior a hoy\. si la entrega es de antes, la carga un admin/i)).toBeTruthy())
    expect(onEntregarSinPago).not.toHaveBeenCalled()
  })

  it('sin tocar la fecha, la entrega va con hoy', async () => {
    const onEntregarSinPago = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, onEntregarSinPago })
    fireEvent.click(screen.getByRole('button', { name: /^entregar a cuenta corriente$/i }))

    await waitFor(() => expect(onEntregarSinPago).toHaveBeenCalledTimes(1))
    expect(onEntregarSinPago.mock.calls[0][0].fechaEntrega).toBe(fechaLocalISO())
  })
})

/**
 * L7 (#1603): para quien no es admin la fecha del cobro es "hoy", y se recalculaba en
 * cada render. Un cobro de las 23:59 cuya respuesta se perdió, reintentado a las 00:01
 * con el modal abierto, cambiaba de huella y viajaba con otra clave: un parcial podía
 * entrar dos veces. Ahora hoy es el de la apertura, y si cambió el día se avisa.
 */
describe('ModalPagoPedido — el día cambia con el modal abierto (L7)', () => {
  afterEach(() => vi.useRealTimers())

  it('no cobra con otra clave: pide cerrar y volver a abrir', async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-16T23:59:00-03:00'))
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ isAdmin: false, onConfirmar, modoEntregaTransportista: false, onEntregarSinPago: undefined })
    await waitFor(() => expect(inputMonto().value).toBe('21600'))
    expect(inputFecha().value).toBe('2026-11-16')

    vi.setSystemTime(new Date('2026-11-17T00:01:00-03:00'))
    fireEvent.click(screen.getByRole('button', { name: /^registrar pago$/i }))

    await waitFor(() => expect(screen.getByText(/cambió el día desde que abriste esta pantalla/i)).toBeTruthy())
    expect(onConfirmar).not.toHaveBeenCalled()
    expect(inputFecha().value).toBe('2026-11-16')
  })
})
