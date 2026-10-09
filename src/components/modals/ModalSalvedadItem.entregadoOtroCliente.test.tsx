/**
 * `ModalSalvedadItem` — "Entregado a otro cliente" (#1015).
 *
 * La mercadería se entregó por error a otro cliente: existe, sólo que está en
 * otra mano. No es faltante ni merma. La salvedad la devuelve al stock, como
 * "Cliente Rechaza", y el modal dice qué hacer después: si se recupera ya está
 * contada, y si se le cobra al otro cliente se agrega a su pedido.
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

describe('ModalSalvedadItem — entregado a otro cliente', () => {
  it('devuelve el stock y dice qué hacer con la mercadería', () => {
    render(<ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={vi.fn()} onClose={vi.fn()} />)
    expect(screen.queryByTestId('aviso-entregado-otro-cliente')).not.toBeInTheDocument()

    fireEvent.click(screen.getByText('Entregado a otro cliente'))
    expect(screen.getByText('El stock se devolvera al inventario')).toBeInTheDocument()
    const aviso = screen.getByTestId('aviso-entregado-otro-cliente')
    expect(aviso).toHaveTextContent(/no es merma/i)
    expect(aviso).toHaveTextContent(/agregalo a su pedido/i)
    // No es el faltante: ese aviso no aparece.
    expect(screen.queryByTestId('aviso-faltante-stock')).not.toBeInTheDocument()
  })

  it('manda el motivo con devolverStock en true', async () => {
    const onSave = vi.fn().mockResolvedValue({ success: true })
    render(<ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={onSave} onClose={vi.fn()} />)

    fireEvent.click(screen.getByText('Entregado a otro cliente'))
    fireEvent.click(screen.getByRole('button', { name: /registrar salvedad/i }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({
      motivo: 'entregado_otro_cliente',
      devolverStock: true,
      cantidadAfectada: 5,
    })
  })
})
