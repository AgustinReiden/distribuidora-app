/**
 * #1560: el cobrador escribe la plata como la app la muestra («150.000», «1.500,50») y ve el
 * monto leído debajo del campo antes de confirmar. Antes «150.000» se registraba como $150.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { type ModalRegistrarPagoProps } from './ModalRegistrarPago'
import type { ClienteDB } from '../../types'

type PagoRegistrado = Awaited<ReturnType<ModalRegistrarPagoProps['onConfirmar']>>

const CLIENTE = { id: '1', nombre_fantasia: 'Almacén Don Ramón' } as unknown as ClienteDB

function montar() {
  const onConfirmar = vi.fn<ModalRegistrarPagoProps['onConfirmar']>().mockResolvedValue({
    id: 'p-1', cliente_id: '1', monto: 150000, forma_pago: 'efectivo', fecha: '2026-11-12',
  } as PagoRegistrado)
  render(
    <ModalRegistrarPago cliente={CLIENTE} saldoPendiente={300000} pedidos={[]} onClose={vi.fn()} onConfirmar={onConfirmar} />,
  )
  return { onConfirmar }
}

const campoMonto = (): HTMLInputElement => screen.getAllByPlaceholderText('0.00')[0] as HTMLInputElement

describe('ModalRegistrarPago · el monto leído', () => {
  // D17 (#1560, #1542; cambió de regla): la tecla del punto es la coma decimal y se ve como coma,
  // así que «150.000» tipeado queda «150,000» y es $150, y el cobrador lo ve en «Se registra». Lo
  // pegado se lee como la app muestra la plata.
  it.each([
    ['150000', 'tipea', /150\.000,00/, 150000],
    ['1500,50', 'tipea', /1\.500,50/, 1500.5],
    ['12.50', 'tipea', /12,50/, 12.5],
    ['150.000', 'tipea', /\$\s?150,00/, 150],
    ['150.000', 'pega', /150\.000,00/, 150000],
    ['1.500,50', 'pega', /1\.500,50/, 1500.5],
  ])('«%s» que se %s se muestra leído y se registra así', async (texto, como, leido, monto) => {
    const user = userEvent.setup()
    const { onConfirmar } = montar()

    await user.clear(campoMonto())
    if (como === 'tipea') await user.type(campoMonto(), texto)
    else await user.paste(texto)

    expect(screen.getByText(/Se registra:/)).toHaveTextContent(leido)

    await user.click(screen.getByRole('button', { name: 'Registrar' }))
    expect(onConfirmar).toHaveBeenCalledTimes(1)
    expect(onConfirmar.mock.calls[0][0]).toMatchObject({ monto })
  })

  it('sin monto no muestra nada', () => {
    montar()
    expect(screen.queryByText(/Se registra:/)).toBeNull()
  })
})
