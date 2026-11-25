/**
 * GTO-5 (ola 3 de #1603, T9): una lectura de km cargada a mano se corrige o se borra desde la ficha
 * (corregir_lectura_km). La de una carga de combustible no: se corrige editando su gasto.
 */
import { describe, it, expect, vi } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalFichaVehiculo from './ModalFichaVehiculo'
import type { Vehiculo } from '../../types/gastos'
import type { LecturaKm } from '../../utils/vehiculos'

const VEHICULO: Vehiculo = { id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }
const LECTURAS: LecturaKm[] = [
  { id: 41, fecha: '2026-10-05', km: 184500, origen: 'manual', gasto_id: null },
  { id: 42, fecha: '2026-10-10', km: 184630, origen: 'carga', gasto_id: 2 },
]

function renderFicha(onCorregirKm = vi.fn(() => Promise.resolve())) {
  render(
    <ModalFichaVehiculo
      vehiculo={VEHICULO}
      gastos={[]}
      lecturas={LECTURAS}
      loading={false}
      mes="2026-10-01"
      usadoPor={[]}
      onRegistrarKm={vi.fn(() => Promise.resolve())}
      onCorregirKm={onCorregirKm}
      onClose={vi.fn()}
    />,
  )
  return { onCorregirKm, user: userEvent.setup() }
}

describe('ModalFichaVehiculo · corregir una lectura de km', () => {
  it('sólo la lectura manual ofrece corregir y borrar', () => {
    renderFicha()
    expect(screen.getByRole('button', { name: 'Corregir la lectura del 05/10/2026' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Borrar la lectura del 05/10/2026' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Corregir la lectura del 10/10/2026' })).not.toBeInTheDocument()
  })

  it('corregir abre el formulario con la lectura y manda la fecha y los km nuevos', async () => {
    const { user, onCorregirKm } = renderFicha()
    await user.click(screen.getByRole('button', { name: 'Corregir la lectura del 05/10/2026' }))
    const form = screen.getByRole('form', { name: 'Corregir la lectura del 05/10/2026' })
    expect(within(form).getByLabelText('Km del tablero')).toHaveValue('184.500')
    expect(within(form).getByLabelText('Fecha')).toHaveValue('2026-10-05')

    fireEvent.change(within(form).getByLabelText('Fecha'), { target: { value: '2026-10-06' } })
    await user.clear(within(form).getByLabelText('Km del tablero'))
    await user.type(within(form).getByLabelText('Km del tablero'), '184550')
    await user.click(within(form).getByRole('button', { name: 'Guardar corrección' }))

    expect(onCorregirKm).toHaveBeenCalledWith(41, '2026-10-06', 184550, false)
  })

  it('borrar pregunta antes y manda el borrado', async () => {
    const { user, onCorregirKm } = renderFicha()
    await user.click(screen.getByRole('button', { name: 'Borrar la lectura del 05/10/2026' }))
    const aviso = screen.getByRole('alertdialog', { name: 'Borrar la lectura de km' })
    expect(aviso).toHaveTextContent('¿Borrar la lectura del 05/10/2026 (184.500 km)?')
    expect(onCorregirKm).not.toHaveBeenCalled()

    await user.click(within(aviso).getByRole('button', { name: 'Sí, borrar' }))
    expect(onCorregirKm).toHaveBeenCalledWith(41, null, null, true)
  })

  it('el rechazo del server se muestra', async () => {
    const { user } = renderFicha(vi.fn(() => Promise.reject(new Error('Los km no pueden bajar: el 10/10/2026 el vehículo marcaba 184.630 km'))))
    await user.click(screen.getByRole('button', { name: 'Corregir la lectura del 05/10/2026' }))
    const form = screen.getByRole('form', { name: 'Corregir la lectura del 05/10/2026' })
    await user.clear(within(form).getByLabelText('Km del tablero'))
    await user.type(within(form).getByLabelText('Km del tablero'), '190000')
    await user.click(within(form).getByRole('button', { name: 'Guardar corrección' }))
    expect(await screen.findByText(/Los km no pueden bajar/)).toBeInTheDocument()
  })
})
