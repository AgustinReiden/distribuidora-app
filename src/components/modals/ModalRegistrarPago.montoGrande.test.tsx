/**
 * 1559-b15 (#1559, decisión del dueño D22): el pago a cuenta no tiene tope en el server, pero
 * si pasa el doble de la deuda la pantalla pide confirmar el monto antes de registrarlo. Un
 * cero de más ("100000" por "10000") quedaba a favor del cliente sin que nadie lo viera.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
  useFechasMinimasPorCobrador: () => new Map(),
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import type { ClienteDB, RegistrarPagoFifoResult } from '../../types'

const CLIENTE = { id: '1', nombre_fantasia: 'Almacén de Prueba' } as unknown as ClienteDB

function montar(saldoPendiente: number) {
  const onConfirmarFIFO = vi.fn<NonNullable<ModalRegistrarPagoProps['onConfirmarFIFO']>>().mockResolvedValue({
    pagoIds: [1], sobrante: 0, montoTotal: 0, aplicaciones: [], creditoAplicado: 0, idempotentReplay: false,
  } as RegistrarPagoFifoResult)
  render(
    <ModalRegistrarPago
      cliente={CLIENTE}
      saldoPendiente={saldoPendiente}
      pedidos={[]}
      onClose={vi.fn()}
      onConfirmar={vi.fn()}
      onConfirmarFIFO={onConfirmarFIFO}
    />,
  )
  return { onConfirmarFIFO }
}

const campoMonto = (): HTMLInputElement => screen.getAllByPlaceholderText('0.00')[0] as HTMLInputElement
const registrar = (): HTMLButtonElement => screen.getByRole('button', { name: 'Registrar' }) as HTMLButtonElement

describe('ModalRegistrarPago · pago a cuenta de más del doble de la deuda', () => {
  it('hasta el doble no pide nada', async () => {
    const user = userEvent.setup()
    const { onConfirmarFIFO } = montar(10000)
    await user.type(campoMonto(), '20000')
    expect(screen.queryByText(/más del doble/)).toBeNull()
    await user.click(registrar())
    expect(onConfirmarFIFO).toHaveBeenCalledTimes(1)
  })

  it('con un cero de más pide confirmar, y con la confirmación registra', async () => {
    const user = userEvent.setup()
    const { onConfirmarFIFO } = montar(10000)
    await user.type(campoMonto(), '100000')
    expect(screen.getByText(/más del doble de lo que debe el cliente/)).toBeInTheDocument()
    expect(registrar()).toBeDisabled()

    await user.click(screen.getByRole('checkbox', { name: 'Sí, el monto es correcto' }))
    expect(registrar()).toBeEnabled()
    await user.click(registrar())
    expect(onConfirmarFIFO).toHaveBeenCalledTimes(1)
    expect(onConfirmarFIFO.mock.calls[0][0]).toMatchObject({ monto: 100000 })
  })

  it('cambiar el monto después de confirmar vuelve a pedir la confirmación', async () => {
    const user = userEvent.setup()
    montar(10000)
    await user.type(campoMonto(), '100000')
    await user.click(screen.getByRole('checkbox', { name: 'Sí, el monto es correcto' }))
    await user.clear(campoMonto())
    await user.type(campoMonto(), '200000')
    expect(registrar()).toBeDisabled()
    expect(screen.getByRole('checkbox', { name: 'Sí, el monto es correcto' })).not.toBeChecked()
  })

  it('sin deuda, todo el pago queda a favor: también pide confirmar', async () => {
    const user = userEvent.setup()
    montar(0)
    await user.type(campoMonto(), '500')
    expect(screen.getByText(/no debe nada/)).toBeInTheDocument()
    expect(registrar()).toBeDisabled()
  })
})
