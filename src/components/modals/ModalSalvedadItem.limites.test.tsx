/**
 * B23 de #1603 (decisión del dueño, 18/11): la cantidad de una salvedad fuera de su límite queda en
 * rojo, con su motivo, y no se registra. Antes `NumberInput` recortaba en el blur que produce tocar
 * «Registrar Salvedad»: «50» sobre una línea de 5 guardaba 5 (la línea entera rechazada) y el campo
 * vacío guardaba 1, con lo tipeado a la vista.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries', () => ({
  useSimularSalvedadPromoImpactoQuery: () => ({ data: [] }),
  useSimularSalvedadesComboImpactoQuery: () => ({ data: [] }),
}))

import ModalSalvedadItem from './ModalSalvedadItem'
import type { PedidoItemDB } from '../../types'

const ITEM = {
  id: 'item-1',
  pedido_id: 'pedido-1',
  producto_id: 'prod-1',
  cantidad: 5,
  precio_unitario: 1000,
  producto: { id: 'prod-1', nombre: 'Yerba de prueba', codigo: 'Y1' },
} as unknown as PedidoItemDB

function abrir() {
  const onSave = vi.fn(() => Promise.resolve({ success: true }))
  render(<ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={onSave} onClose={vi.fn()} />)
  return { onSave, user: userEvent.setup() }
}

const cantidad = (): HTMLElement => screen.getByLabelText('Cantidad con problema')
const registrar = (): HTMLElement => screen.getByRole('button', { name: /registrar salvedad/i })

describe('ModalSalvedadItem — la cantidad fuera de su límite (B23)', () => {
  it.each([
    ['50 sobre una línea de 5', '50', 'La línea tiene 5'],
    ['6 sobre una línea de 5', '6', 'La línea tiene 5'],
    ['0', '0', 'El mínimo es 1'],
    ['vacío', '', 'Poné una cantidad'],
  ])('%s: queda en rojo con su motivo y no se registra', async (_caso, texto, motivo) => {
    const { onSave, user } = abrir()
    await user.click(screen.getByText('Cliente Rechaza'))

    await user.clear(cantidad())
    if (texto) await user.type(cantidad(), texto)
    await user.click(registrar())

    expect(onSave).not.toHaveBeenCalled()
    expect(cantidad()).toHaveValue(texto)
    expect(cantidad()).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent(motivo)
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })

  it('dentro del límite registra lo tipeado, sin salir antes del campo', async () => {
    const { onSave, user } = abrir()
    await user.click(screen.getByText('Cliente Rechaza'))

    await user.clear(cantidad())
    await user.type(cantidad(), '3')
    await user.click(registrar())

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0]).toEqual([expect.objectContaining({ cantidadAfectada: 3 })])
  })

  it('los botones − y + siguen poniendo un valor válido', async () => {
    const { onSave, user } = abrir()
    await user.click(screen.getByText('Cliente Rechaza'))

    await user.click(screen.getByRole('button', { name: 'Restar uno' }))
    expect(cantidad()).toHaveValue('4')
    await user.click(registrar())
    expect(onSave.mock.calls[0]).toEqual([expect.objectContaining({ cantidadAfectada: 4 })])
  })
})
