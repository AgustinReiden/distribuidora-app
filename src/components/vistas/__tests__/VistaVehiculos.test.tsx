import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaVehiculos, { type VistaVehiculosProps } from '../VistaVehiculos'
import type { Vehiculo } from '../../../types/gastos'

const PARTNER: Vehiculo = { id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }
const VIEJO: Vehiculo = { id: 8, sucursal_id: 1, patente: 'AB123CD', descripcion: 'Hilux', activo: false }

function renderVista(props: Partial<VistaVehiculosProps> = {}) {
  const handlers = { onNuevoVehiculo: vi.fn(), onEditarVehiculo: vi.fn(), onVerFicha: vi.fn() }
  render(
    <VistaVehiculos
      vehiculos={[PARTNER, VIEJO]}
      gastoDelMes={{ 7: 126000 }}
      loading={false}
      sucursalActual={{ id: 1, nombre: 'Tucumán' }}
      {...handlers}
      {...props}
    />,
  )
  return { ...handlers, user: userEvent.setup() }
}

describe('VistaVehiculos', () => {
  it('título, crumbs y botón de alta', () => {
    renderVista()
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Vehículos')
    expect(screen.getByText('2 VEHÍCULOS')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Nuevo vehículo/ })).toBeInTheDocument()
  })

  it('cada vehículo muestra patente, descripción, estado y gasto del mes', () => {
    renderVista()
    const activo = screen.getByTestId('vehiculo-7')
    expect(activo).toHaveTextContent('AC456EF')
    expect(activo).toHaveTextContent('Partner')
    expect(activo).toHaveTextContent(/126\.000,00/)
    expect(within(activo).queryByText('Inactivo')).not.toBeInTheDocument()

    const inactivo = screen.getByTestId('vehiculo-8')
    expect(within(inactivo).getByText('Inactivo')).toBeInTheDocument()
    expect(inactivo).toHaveTextContent(/0,00/)
  })

  it('lápiz y ver ficha llaman con el vehículo', async () => {
    const { user, onEditarVehiculo, onVerFicha, onNuevoVehiculo } = renderVista()
    const fila = screen.getByTestId('vehiculo-7')
    await user.click(within(fila).getByRole('button', { name: 'Editar vehículo AC456EF' }))
    await user.click(within(fila).getByRole('button', { name: 'Ver ficha' }))
    await user.click(screen.getByRole('button', { name: /Nuevo vehículo/ }))

    expect(onEditarVehiculo).toHaveBeenCalledWith(PARTNER)
    expect(onVerFicha).toHaveBeenCalledWith(PARTNER)
    expect(onNuevoVehiculo).toHaveBeenCalledTimes(1)
  })

  it('sin vehículos avisa', () => {
    renderVista({ vehiculos: [] })
    expect(screen.getByText(/Todavía no hay vehículos/)).toBeInTheDocument()
  })
})
