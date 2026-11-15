/**
 * 1544-b6: sin los pagos del cliente no se sabe cuánto crédito de una NC queda libre.
 * Calcularlo con `pagos = []` daba «Crédito disponible: $ 0»; ahora dice que no está
 * disponible, y no ofrece imputar.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

vi.mock('../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaClienteQuery: () => ({
    data: [{ id: 9, total: 500, fecha: '2026-11-01', motivo: 'devolucion', pedido_id: 77, anulada: false, items: [] }],
    isLoading: false,
    error: null,
  }),
  useAnularNotaCreditoVentaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))

import NotasCreditoVentaCliente from './NotasCreditoVentaCliente'

describe('NotasCreditoVentaCliente — pagos del cliente no disponibles', () => {
  it('con los pagos cargados muestra el crédito disponible', () => {
    render(<NotasCreditoVentaCliente clienteId="1" puedeAnular={false} pagos={[]} />)
    expect(screen.getByText(/Crédito disponible:/)).toBeTruthy()
    expect(screen.queryByText(/no disponible/)).toBeNull()
  })

  it('si no cargaron, dice «no disponible» y no inventa un crédito de $ 0', () => {
    render(<NotasCreditoVentaCliente clienteId="1" puedeAnular={false} pagos={[]} pagosNoDisponibles />)
    expect(screen.getByText(/no se pudieron cargar los pagos del cliente/)).toBeTruthy()
    expect(screen.getByText('no disponible')).toBeTruthy()
    expect(screen.queryByText(/\$\s*0/)).toBeNull()
  })
})
