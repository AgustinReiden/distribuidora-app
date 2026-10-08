/**
 * `ModalSalvedadItem` — motivo "Otro" (#1022).
 *
 * "Otro" devuelve el stock (decisión del dueño, 08/10): casi todas las que hay
 * son "no se cargó en el camión", mercadería que nunca salió del depósito. Y
 * exige una descripción, que es lo único que dice qué pasó.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'

vi.mock('../../hooks/queries', () => ({
  useSimularSalvedadPromoImpactoQuery: () => ({ data: [] }),
}))

import ModalSalvedadItem from './ModalSalvedadItem'
import type { PedidoItemDB } from '../../types'

const ITEM = {
  id: 'item-1',
  pedido_id: 'pedido-1',
  producto_id: 'prod-1',
  cantidad: 5,
  precio_unitario: 1000,
  producto: { id: 'prod-1', nombre: 'Yerba', codigo: 'Y1' },
} as unknown as PedidoItemDB

describe('ModalSalvedadItem — motivo "Otro"', () => {
  it('sin descripción no se registra', async () => {
    const onSave = vi.fn().mockResolvedValue({ success: true })
    render(<ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={onSave} onClose={vi.fn()} />)

    fireEvent.click(screen.getByText('Otro'))
    fireEvent.click(screen.getByRole('button', { name: /registrar salvedad/i }))

    // La frena el `required` del textarea (y, detrás, la validación de 10
    // caracteres del submit y la del servidor).
    expect(screen.getByPlaceholderText(/detalle adicional/i)).toBeInvalid()
    await new Promise(r => setTimeout(r, 50))
    expect(onSave).not.toHaveBeenCalled()
  })

  it('con descripción devuelve el stock', async () => {
    const onSave = vi.fn().mockResolvedValue({ success: true })
    render(<ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={onSave} onClose={vi.fn()} />)

    fireEvent.click(screen.getByText('Otro'))
    expect(screen.getByText('El stock se devolvera al inventario')).toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText(/detalle adicional/i), {
      target: { value: 'No se cargó en el camión' },
    })
    fireEvent.click(screen.getByRole('button', { name: /registrar salvedad/i }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({
      motivo: 'otro',
      devolverStock: true,
      descripcion: 'No se cargó en el camión',
    })
  })
})
