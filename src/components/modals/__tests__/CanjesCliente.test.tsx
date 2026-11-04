/**
 * Ficha del cliente, pestaña "Canjes" (#1370): la diferencia de precio de cada canje se
 * ve, con su sentido, y se aclara que es informativa (no está en la cuenta del cliente).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import type { CambioProductoCliente } from '../../../hooks/queries/useCambiosProductosQuery'

const { estado } = vi.hoisted(() => ({
  estado: { data: [] as CambioProductoCliente[], isLoading: false, error: null as Error | null },
}))

vi.mock('../../../hooks/queries/useCambiosProductosQuery', () => ({
  useCambiosProductosClienteQuery: () => estado,
}))

import CanjesCliente from '../CanjesCliente'

const CANJE = (id: number, diferencia: number): CambioProductoCliente => ({
  id,
  created_at: '2026-11-02T15:00:00-03:00',
  motivo: 'erroneo',
  observaciones: null,
  cantidad_devuelta: 2,
  precio_devuelto: 1000,
  cantidad_entregada: 1,
  precio_entregado: 2000 + diferencia,
  diferencia_monto: diferencia,
  producto_devuelto: { nombre: 'Gaseosa 2L' },
  producto_entregado: { nombre: 'Agua 6L' },
})

describe('CanjesCliente (#1370)', () => {
  it('muestra la diferencia de cada canje y de qué lado queda', () => {
    estado.data = [CANJE(5, 8000), CANJE(4, -1500)]
    render(<CanjesCliente clienteId="9" />)

    expect(screen.getByText('Canje #5')).toBeInTheDocument()
    expect(screen.getByText(/se hace un pedido/)).toBeInTheDocument()
    expect(screen.getByText('Canje #4')).toBeInTheDocument()
    expect(screen.getByText(/no quedó saldo a favor/)).toBeInTheDocument()
    expect(screen.getAllByText(/Devolvió: 2 × Gaseosa 2L/)).toHaveLength(2)
    expect(screen.getAllByText(/Se llevó: 1 × Agua 6L/)).toHaveLength(2)
    expect(screen.getByText(/es informativa: no está en la cuenta del cliente/)).toBeInTheDocument()
  })

  it('sin canjes lo dice', () => {
    estado.data = []
    render(<CanjesCliente clienteId="9" />)
    expect(screen.getByText('No hay canjes')).toBeInTheDocument()
  })

  it('si la consulta falla, lo dice', () => {
    estado.data = []
    estado.error = new Error('x')
    render(<CanjesCliente clienteId="9" />)
    expect(screen.getByText('No se pudieron cargar los canjes.')).toBeInTheDocument()
    estado.error = null
  })
})
