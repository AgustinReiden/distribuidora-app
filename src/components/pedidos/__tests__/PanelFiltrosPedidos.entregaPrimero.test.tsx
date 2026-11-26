/**
 * #1697: en la lista de pedidos, el filtro de fecha que se usa para armar el reparto muestra
 * primero la fecha de entrega y después la de carga. Lo tienen quienes arman el reparto: admin
 * y encargado. Un preventista sigue viendo sólo la fecha de carga.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import PanelFiltrosPedidos from '../PanelFiltrosPedidos'

const FILTROS = { estado: 'todos', fechaDesde: null, fechaHasta: null, fechaEntregaProgramada: null }

function etiquetas(): string[] {
  return ['Entrega programada', 'Fecha de carga']
    .filter(t => screen.queryByText(t))
    .sort((a, b) => {
      const ea = screen.getByText(a)
      const eb = screen.getByText(b)
      return ea.compareDocumentPosition(eb) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1
    })
}

describe('PanelFiltrosPedidos — la fecha de entrega va primero (#1697)', () => {
  it('el encargado ve la entrega programada antes que la fecha de carga', () => {
    render(<PanelFiltrosPedidos filtros={FILTROS} isAdmin={false} puedeFiltrarEntrega onFiltrosChange={vi.fn()} />)
    expect(etiquetas()).toEqual(['Entrega programada', 'Fecha de carga'])
    expect(screen.getByLabelText('Fecha de entrega programada')).toBeInTheDocument()
  })

  it('el admin, igual (sin pasar el dato, como antes)', () => {
    render(<PanelFiltrosPedidos filtros={FILTROS} isAdmin onFiltrosChange={vi.fn()} />)
    expect(etiquetas()).toEqual(['Entrega programada', 'Fecha de carga'])
  })

  it('un preventista no tiene el filtro de entrega', () => {
    render(<PanelFiltrosPedidos filtros={FILTROS} isAdmin={false} onFiltrosChange={vi.fn()} />)
    expect(etiquetas()).toEqual(['Fecha de carga'])
  })
})
