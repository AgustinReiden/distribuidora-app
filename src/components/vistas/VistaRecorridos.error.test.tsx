/**
 * Un error de carga no es «no hay recorridos» (#1549, B3).
 *
 * `useRecorridos` dejaba la lista en [] ante un error del server o un timeout, y la vista
 * decía «No hay recorridos registrados para esta fecha»: el encargado lo leía como un día
 * sin rutas cuando en realidad no se pudo ver ninguna.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries', () => ({
  useDepositoCoords: () => null,
}))

vi.mock('../recorridos/PanelNoEntregados', () => ({
  default: () => null,
}))

import VistaRecorridos from './VistaRecorridos'

const baseProps = {
  recorridos: [],
  loading: false,
  fechaSeleccionada: '2020-01-01',
  estadisticas: null,
  onFechaChange: vi.fn(),
}

describe('VistaRecorridos — error de carga (#1549)', () => {
  it('con la carga fallida y la lista vacía, muestra el error con Reintentar y no «No hay recorridos»', async () => {
    const onRefresh = vi.fn()
    render(<VistaRecorridos {...baseProps} error onRefresh={onRefresh} />)

    expect(screen.getByRole('alert')).toHaveTextContent('No se pudo cargar')
    expect(screen.queryByText(/No hay recorridos/)).not.toBeInTheDocument()

    await userEvent.setup().click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(onRefresh).toHaveBeenCalledTimes(1)
  })

  it('sin error y con la lista vacía, sigue diciendo que no hay recorridos para esa fecha', () => {
    render(<VistaRecorridos {...baseProps} onRefresh={vi.fn()} />)

    expect(screen.getByText('No hay recorridos registrados para esta fecha.')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('mientras carga, no muestra el error', () => {
    render(<VistaRecorridos {...baseProps} error loading onRefresh={vi.fn()} />)

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('con recorridos en la lista (por ejemplo, falló sólo la estadística), la lista manda', () => {
    const recorridos = [{
      id: '7', fecha: '2020-01-01', estado: 'en_curso', total_pedidos: 1, pedidos_entregados: 0,
      total_facturado: 1000, total_cobrado: 0, transportista: { nombre: 'Rulo' }, pedidos: [],
    }] as any
    render(<VistaRecorridos {...baseProps} recorridos={recorridos} error onRefresh={vi.fn()} />)

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getAllByText(/Rulo/).length).toBeGreaterThan(0)
  })
})
