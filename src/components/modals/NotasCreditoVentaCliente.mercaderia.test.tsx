/**
 * B22 (decisiones del dueño del 17 y 18/11): la ficha lista un descuento sin unidades
 * («Descuento · producto», no «0 × producto»), dice si la nota reingresó mercadería o la
 * dejó como merma, y al anular avisa que eso se deshace.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const notas = [
  {
    id: 11, total: 100, fecha: '2026-11-18', motivo: 'descuento_comercial', pedido_id: 77, anulada: false,
    items: [
      { id: 1, producto_id: 5, producto: { nombre: 'Fideos' }, cantidad: 0, precio_unitario: 121, subtotal: 53.07, lotes_devueltos: null, merma_id: null },
      { id: 2, producto_id: 6, producto: { nombre: 'Arroz' }, cantidad: 0, precio_unitario: 110.5, subtotal: 46.93, lotes_devueltos: null, merma_id: null },
    ],
  },
  {
    id: 12, total: 400, fecha: '2026-11-18', motivo: 'cliente_rechaza', pedido_id: 78, anulada: false,
    items: [{ id: 3, producto_id: 5, producto: { nombre: 'Fideos' }, cantidad: 4, precio_unitario: 100, subtotal: 400,
              lotes_devueltos: [{ lote_id: 9, cantidad: 4, huella: 4 }], merma_id: null }],
  },
  {
    id: 13, total: 300, fecha: '2026-11-18', motivo: 'producto_vencido', pedido_id: 79, anulada: true,
    anulada_at: '2026-11-18T15:00:00Z',
    items: [{ id: 4, producto_id: 6, producto: { nombre: 'Arroz' }, cantidad: 3, precio_unitario: 100, subtotal: 300,
              lotes_devueltos: [], merma_id: '55' }],
  },
]

vi.mock('../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaClienteQuery: () => ({ data: notas, isLoading: false, error: null }),
  useAnularNotaCreditoVentaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))

import NotasCreditoVentaCliente from './NotasCreditoVentaCliente'

describe('NotasCreditoVentaCliente — la mercadería y el descuento por monto (B22)', () => {
  it('un renglón por monto se lista como descuento, sin «0 ×»', () => {
    render(<NotasCreditoVentaCliente clienteId="1" puedeAnular={false} />)
    expect(screen.getAllByText(/Descuento · Fideos/).length).toBe(1)
    expect(screen.getByText(/Descuento · Arroz/)).toBeInTheDocument()
    expect(screen.queryByText(/^0 ×/)).toBeNull()
    expect(screen.getByText(/4 × Fideos/)).toBeInTheDocument()
  })

  it('dice si la nota reingresó la mercadería o la dejó como merma, y si se deshizo', () => {
    render(<NotasCreditoVentaCliente clienteId="1" puedeAnular={false} />)
    expect(screen.getByText('La mercadería reingresó al stock')).toBeInTheDocument()
    expect(screen.getByText('La mercadería quedó como merma (se deshizo al anularla)')).toBeInTheDocument()
  })

  it('al anular una nota que reingresó, avisa que lo reingresado vuelve a salir', () => {
    render(<NotasCreditoVentaCliente clienteId="1" puedeAnular />)
    const anular = screen.getAllByRole('button', { name: 'Anular' })
    // La segunda nota vigente es la del rechazo (la primera, el descuento).
    fireEvent.click(anular[1])
    expect(screen.getByText(/Lo que reingresó al stock vuelve a salir/)).toBeInTheDocument()
  })
})
