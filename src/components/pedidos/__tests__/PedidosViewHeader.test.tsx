/**
 * Caracterización de PedidosViewHeader: fija el comportamiento ACTUAL del
 * crumb, el título dinámico y el conteo antes de reemplazarlo por un
 * PageHeader común.
 *
 * La fecha del sistema queda fija en martes 21 de abril de 2026 (10:00 hora
 * local) para que el crumb de fecha y los períodos "del día" / "del mes"
 * sean deterministas.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import PedidosViewHeader from '../PedidosViewHeader'
import type { FiltrosPedidosState } from '../../../types'

const AHORA = '2026-04-21T10:00:00'

function crearFiltros(overrides: Partial<FiltrosPedidosState> = {}): FiltrosPedidosState {
  return {
    fechaDesde: null,
    fechaHasta: null,
    estado: 'todos',
    estadoPago: 'todos',
    transportistaId: 'todos',
    busqueda: '',
    conSalvedad: 'todos',
    ...overrides,
  }
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date(AHORA))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('PedidosViewHeader', () => {
  it('muestra el crumb de sección, la fecha larga y el título sin período cuando no hay filtros', () => {
    render(<PedidosViewHeader filtros={crearFiltros()} totalCount={0} loading={false} />)

    expect(screen.getByText('Operaciones')).toBeInTheDocument()
    expect(screen.getByText('MARTES 21 DE ABRIL')).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 1, name: 'Pedidos' })).toBeInTheDocument()
  })

  it('conteo en singular: "1 RESULTADO"', () => {
    render(<PedidosViewHeader filtros={crearFiltros()} totalCount={1} loading={false} />)
    expect(screen.getByText('1 RESULTADO')).toBeInTheDocument()
  })

  it('conteo en plural: "649 RESULTADOS"', () => {
    render(<PedidosViewHeader filtros={crearFiltros()} totalCount={649} loading={false} />)
    expect(screen.getByText('649 RESULTADOS')).toBeInTheDocument()
  })

  it('conteo en plural con cero resultados: "0 RESULTADOS"', () => {
    render(<PedidosViewHeader filtros={crearFiltros()} totalCount={0} loading={false} />)
    expect(screen.getByText('0 RESULTADOS')).toBeInTheDocument()
  })

  it('estado loading muestra "ACTUALIZANDO…" en vez del conteo', () => {
    render(<PedidosViewHeader filtros={crearFiltros()} totalCount={5} loading />)
    expect(screen.getByText('ACTUALIZANDO…')).toBeInTheDocument()
    expect(screen.queryByText('5 RESULTADOS')).not.toBeInTheDocument()
  })

  it('rango de un solo día (hoy) → "Pedidos del día"', () => {
    render(
      <PedidosViewHeader
        filtros={crearFiltros({ fechaDesde: '2026-04-21', fechaHasta: '2026-04-21' })}
        totalCount={3}
        loading={false}
      />
    )
    expect(screen.getByRole('heading', { level: 1, name: 'Pedidos del día' })).toBeInTheDocument()
  })

  it('mes completo del mes actual → "Pedidos del mes"', () => {
    render(
      <PedidosViewHeader
        filtros={crearFiltros({ fechaDesde: '2026-04-01', fechaHasta: '2026-04-30' })}
        totalCount={40}
        loading={false}
      />
    )
    expect(screen.getByRole('heading', { level: 1, name: 'Pedidos del mes' })).toBeInTheDocument()
  })

  it('fechaEntregaProgramada = mañana → "Pedidos para entregar mañana", con prioridad sobre fechaDesde/fechaHasta', () => {
    render(
      <PedidosViewHeader
        filtros={crearFiltros({
          fechaDesde: '2026-04-01',
          fechaHasta: '2026-04-30',
          fechaEntregaProgramada: '2026-04-22',
        })}
        totalCount={7}
        loading={false}
      />
    )
    expect(
      screen.getByRole('heading', { level: 1, name: 'Pedidos para entregar mañana' })
    ).toBeInTheDocument()
  })

  it('renderiza el slot de actions cuando se provee', () => {
    render(
      <PedidosViewHeader
        filtros={crearFiltros()}
        totalCount={0}
        loading={false}
        actions={<button>Nuevo pedido</button>}
      />
    )
    expect(screen.getByRole('button', { name: 'Nuevo pedido' })).toBeInTheDocument()
  })
})
