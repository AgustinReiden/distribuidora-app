/**
 * `ModalSalvedadItem` — aviso del faltante de stock (#827).
 *
 * El faltante parcial se entrega con salvedad `faltante_stock` sobre el renglón
 * que falta. `registrar_salvedad` no le devuelve el stock --las unidades ya
 * salieron al cargar el pedido y no existían--, y el modal tiene que decirlo, y
 * remitir a la cancelación "Falta de stock" cuando no hay de ningún producto.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

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

describe('ModalSalvedadItem — aviso del faltante de stock', () => {
  it('con "Faltante de Stock" avisa que las unidades no vuelven y remite a la cancelación', () => {
    render(<ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={vi.fn()} onClose={vi.fn()} />)
    expect(screen.queryByTestId('aviso-faltante-stock')).not.toBeInTheDocument()

    fireEvent.click(screen.getByText('Faltante de Stock'))
    const aviso = screen.getByTestId('aviso-faltante-stock')
    expect(aviso).toHaveTextContent(/no vuelven al\s+stock/i)
    // #847: tampoco desaparecen sin asiento, quedan como merma.
    expect(aviso).toHaveTextContent(/quedan registradas como merma/i)
    expect(aviso).toHaveTextContent(/"Falta de stock"/)
  })

  it('otro motivo no muestra el aviso', () => {
    render(<ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={vi.fn()} onClose={vi.fn()} />)
    fireEvent.click(screen.getByText('Cliente Rechaza'))
    expect(screen.queryByTestId('aviso-faltante-stock')).not.toBeInTheDocument()
  })
})
