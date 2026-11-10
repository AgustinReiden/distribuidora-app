/**
 * COB-5 y COB-6 (#1512): con una boleta elegida el cobro se mide contra lo que FALTA de
 * esa boleta, no contra el saldo del cliente; y las formas de pago salen del espejo de
 * `formas_pago()`.
 *
 * Con una boleta, pasarse NO deja saldo a favor: `registrar_pagos_pedido` rechaza el
 * cobro que pasa lo que falta. Antes el modal decía «La diferencia quedará como saldo a
 * favor» y dejaba confirmar un cobro que el server iba a rechazar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import { FORMAS_PAGO_SELECCIONABLES } from '../../constants/formasPago'
import type { ClienteDB, Pedido } from '../../types'
import { fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'

beforeEach(() => {
  fijarUsuarioRequestIds('u-ana')
})

const CLIENTE = { id: '303', nombre_fantasia: 'MARCOS CHOFER' } as unknown as ClienteDB
// Una boleta que debe 2.000 de 5.000, de un cliente que en total debe 20.000.
const BOLETA = { id: '7001', cliente_id: '303', total: 5000, monto_pagado: 3000, estado_pago: 'parcial' } as unknown as Pedido

function montar(props: Partial<ModalRegistrarPagoProps> = {}) {
  return render(
    <ModalRegistrarPago
      cliente={CLIENTE}
      saldoPendiente={20000}
      pedidos={[BOLETA]}
      onClose={vi.fn()}
      onConfirmar={vi.fn()}
      {...props}
    />,
  )
}

const campoMonto = (): HTMLElement => screen.getByPlaceholderText(/0[.,]00/)
const registrar = (): HTMLButtonElement => screen.getByRole('button', { name: 'Registrar' }) as HTMLButtonElement

describe('ModalRegistrarPago — con una boleta elegida se mide contra lo que falta (COB-5)', () => {
  it('pasarse de lo que falta avisa que se rechaza, dice el máximo y no deja confirmar', async () => {
    const user = userEvent.setup()
    montar()
    await user.selectOptions(screen.getByRole('combobox'), '7001')
    await user.type(campoMonto(), '3000')

    const aviso = screen.getByRole('alert')
    expect(aviso).toHaveTextContent(/se va a rechazar/)
    expect(aviso).toHaveTextContent(/Cobrá hasta \$\s*2\.000/)
    expect(aviso).toHaveTextContent(/Pago a cuenta general/)
    expect(screen.queryByText(/quedará como saldo a favor/)).toBeNull()
    expect(registrar().disabled).toBe(true)
  })

  it('cobrar justo lo que falta deja confirmar', async () => {
    const user = userEvent.setup()
    montar()
    await user.selectOptions(screen.getByRole('combobox'), '7001')
    await user.type(campoMonto(), '2000')

    expect(screen.queryByRole('alert')).toBeNull()
    expect(registrar().disabled).toBe(false)
  })

  it('los porcentajes salen de lo que falta de la boleta, no del saldo del cliente', async () => {
    const user = userEvent.setup()
    montar()
    await user.selectOptions(screen.getByRole('combobox'), '7001')

    await user.click(screen.getByRole('button', { name: '50%' }))
    expect(campoMonto()).toHaveValue('1000')
    await user.click(screen.getByRole('button', { name: 'Total' }))
    expect(campoMonto()).toHaveValue('2000')
    expect(registrar().disabled).toBe(false)
  })

  it('sin boleta (pago a cuenta general) todo sigue contra el saldo del cliente y el sobrante queda a favor', async () => {
    const user = userEvent.setup()
    montar({ saldoPendiente: 1000, onConfirmarFIFO: vi.fn() })
    await user.type(campoMonto(), '3000')

    expect(screen.getByText(/La diferencia quedará como saldo a favor/)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).toBeNull()
    expect(registrar().disabled).toBe(false)

    await user.click(screen.getByRole('button', { name: '50%' }))
    expect(campoMonto()).toHaveValue('500')
  })

  it('el pago dividido también muestra lo que falta de la boleta y se frena si lo pasa', async () => {
    const user = userEvent.setup()
    montar({ onConfirmarDividido: vi.fn() })
    await user.selectOptions(screen.getByRole('combobox'), '7001')
    await user.click(screen.getByLabelText(/Pago dividido/))
    const montos = screen.getAllByPlaceholderText('0.00')
    await user.clear(montos[0]); await user.type(montos[0], '1500')
    await user.clear(montos[1]); await user.type(montos[1], '1000')

    expect(screen.getByText(/Falta de la boleta:/)).toHaveTextContent(/excede lo que falta/)
    expect(screen.queryByText(/Saldo pendiente: /)).toBeNull()
    expect(screen.getByRole('alert')).toHaveTextContent(/se va a rechazar/)
    expect(registrar().disabled).toBe(true)

    await user.clear(montos[1]); await user.type(montos[1], '500')
    expect(screen.queryByRole('alert')).toBeNull()
    expect(registrar().disabled).toBe(false)
  })

  it('con pedidoIdFijo (parada del chofer) el tope es el saldo vivo de esa boleta y no ofrece el pago a cuenta general', async () => {
    const user = userEvent.setup()
    montar({ saldoPendiente: 1000, pedidos: [], pedidoIdFijo: '4625' })
    await user.type(campoMonto(), '1500')

    const aviso = screen.getByRole('alert')
    expect(aviso).toHaveTextContent(/Cobrá hasta \$\s*1\.000,00\.$/)
    expect(aviso).not.toHaveTextContent(/Pago a cuenta general/)
    expect(registrar().disabled).toBe(true)
  })
})

describe('ModalRegistrarPago — las formas de pago salen del espejo de formas_pago() (COB-6)', () => {
  it('ofrece exactamente las seleccionables, sin cuenta corriente ni otros', () => {
    montar({ pedidos: [] })
    const esperadas = FORMAS_PAGO_SELECCIONABLES.map(m => m.label)

    for (const label of esperadas) {
      expect(screen.getByRole('button', { name: label })).toBeInTheDocument()
    }
    expect(screen.queryByRole('button', { name: /cuenta corriente/i })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Otros' })).toBeNull()
    expect(screen.queryByRole('button', { name: /adelanto de sueldo/i })).toBeNull()
  })

  it('el adelanto de sueldo se suma sólo desde la ficha y sin boleta, como antes', () => {
    montar({ pedidos: [], permitirAdelantoSueldo: true, clienteEsEmpleado: true })
    expect(screen.getByRole('button', { name: 'Adelanto de sueldo' })).toBeInTheDocument()
  })
})
