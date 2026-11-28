/**
 * cobros-B3 (tanda 6 de #1603): el cobro desde la ficha ofrecía elegir la fecha a cualquiera, y el
 * server rechaza la de otro día de un encargado («Encargado solo puede registrar pagos con fecha
 * de hoy»). Ahora sólo el admin la elige; el resto cobra con hoy, y no ve un campo que no puede
 * usar. Es el gemelo de lo que ya hace `ModalPagoPedido`.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
  useFechasMinimasPorCobrador: () => new Map(),
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import type { ClienteDB, Pedido } from '../../types'
import { fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'
import { fechaLocalISO } from '../../utils/formatters'

beforeEach(() => { fijarUsuarioRequestIds('u-ana') })

const CLIENTE = { id: '303', nombre_fantasia: 'MARCOS CHOFER' } as unknown as ClienteDB
const BOLETA = { id: '7001', cliente_id: '303', total: 5000, monto_pagado: 3000, estado_pago: 'parcial' } as unknown as Pedido

function montar(props: Partial<ModalRegistrarPagoProps> = {}) {
  const onConfirmar = vi.fn().mockResolvedValue({ id: 1, monto: 2000 })
  render(
    <ModalRegistrarPago
      cliente={CLIENTE}
      saldoPendiente={20000}
      pedidos={[BOLETA]}
      onClose={vi.fn()}
      onConfirmar={onConfirmar}
      {...props}
    />,
  )
  return onConfirmar
}

const campoFecha = (): HTMLInputElement => document.querySelector('input[type="date"]') as HTMLInputElement

describe('ModalRegistrarPago — la fecha del cobro según el rol (cobros-B3)', () => {
  it('un encargado (no admin) no puede elegir otra fecha: el campo está bloqueado en hoy', () => {
    montar({ isAdmin: false })
    expect(campoFecha()).toBeDisabled()
    expect(campoFecha().value).toBe(fechaLocalISO())
  })

  it('un encargado cobra con la fecha de hoy', async () => {
    const user = userEvent.setup()
    const onConfirmar = montar({ isAdmin: false })
    await user.selectOptions(screen.getByRole('combobox'), '7001')
    await user.type(screen.getByPlaceholderText(/0[.,]00/), '2000')
    await user.click(screen.getByRole('button', { name: 'Registrar' }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalled())
    expect(onConfirmar.mock.calls[0][0]).toMatchObject({ fecha: fechaLocalISO() })
  })

  it('un admin sí elige la fecha, y es la que se manda', async () => {
    const user = userEvent.setup()
    const onConfirmar = montar({ isAdmin: true })
    expect(campoFecha()).not.toBeDisabled()
    const ayer = new Date(); ayer.setDate(ayer.getDate() - 1)
    const ayerISO = fechaLocalISO(ayer)
    fireEvent.change(campoFecha(), { target: { value: ayerISO } })
    await user.selectOptions(screen.getByRole('combobox'), '7001')
    await user.type(screen.getByPlaceholderText(/0[.,]00/), '2000')
    await user.click(screen.getByRole('button', { name: 'Registrar' }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalled())
    expect(onConfirmar.mock.calls[0][0]).toMatchObject({ fecha: ayerISO })
  })
})
