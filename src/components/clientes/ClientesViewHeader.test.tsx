/**
 * Caracterización de ClientesViewHeader: fija el comportamiento ACTUAL del
 * crumb, el título dinámico y el conteo antes de reemplazarlo por un
 * PageHeader común.
 *
 * A diferencia de Pedidos/Productos/Dashboard, este header no deriva el
 * sufijo del título con un util propio: recibe `filtroDescriptivo` ya armado
 * como prop.
 *
 * La fecha del sistema queda fija en martes 21 de abril de 2026 (10:00 hora
 * local) para que el crumb de fecha sea determinista.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import ClientesViewHeader from './ClientesViewHeader'

const AHORA = '2026-04-21T10:00:00'

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date(AHORA))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('ClientesViewHeader', () => {
  it('muestra el crumb de sección, la fecha larga y el título sin sufijo cuando no hay filtroDescriptivo', () => {
    render(<ClientesViewHeader totalClientes={0} loading={false} />)

    expect(screen.getByText('Cartera')).toBeInTheDocument()
    expect(screen.getByText('MARTES 21 DE ABRIL')).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 1, name: 'Clientes' })).toBeInTheDocument()
  })

  it('con filtroDescriptivo "con deuda" el título queda "Clientes con deuda"', () => {
    render(<ClientesViewHeader totalClientes={12} loading={false} filtroDescriptivo="con deuda" />)
    expect(screen.getByRole('heading', { level: 1, name: 'Clientes con deuda' })).toBeInTheDocument()
  })

  it('con filtroDescriptivo de rubro el título refleja el rubro exacto', () => {
    render(
      <ClientesViewHeader
        totalClientes={5}
        loading={false}
        filtroDescriptivo="del rubro Almacén"
      />
    )
    expect(
      screen.getByRole('heading', { level: 1, name: 'Clientes del rubro Almacén' })
    ).toBeInTheDocument()
  })

  it('conteo en singular: "1 CLIENTE"', () => {
    render(<ClientesViewHeader totalClientes={1} loading={false} />)
    expect(screen.getByText('1 CLIENTE')).toBeInTheDocument()
  })

  it('conteo en plural: "649 CLIENTES"', () => {
    render(<ClientesViewHeader totalClientes={649} loading={false} />)
    expect(screen.getByText('649 CLIENTES')).toBeInTheDocument()
  })

  it('conteo en plural con cero clientes: "0 CLIENTES"', () => {
    render(<ClientesViewHeader totalClientes={0} loading={false} />)
    expect(screen.getByText('0 CLIENTES')).toBeInTheDocument()
  })

  it('estado loading muestra "ACTUALIZANDO…" en vez del conteo', () => {
    render(<ClientesViewHeader totalClientes={10} loading />)
    expect(screen.getByText('ACTUALIZANDO…')).toBeInTheDocument()
    expect(screen.queryByText('10 CLIENTES')).not.toBeInTheDocument()
  })

  it('renderiza el slot de actions cuando se provee', () => {
    render(
      <ClientesViewHeader
        totalClientes={0}
        loading={false}
        actions={<button>Nuevo cliente</button>}
      />
    )
    expect(screen.getByRole('button', { name: 'Nuevo cliente' })).toBeInTheDocument()
  })
})
