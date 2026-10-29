import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalVehiculo, { modalVehiculoSchema } from './ModalVehiculo'
import type { Vehiculo } from '../../types/gastos'

function renderModal(vehiculo?: Vehiculo, onSave = vi.fn(() => Promise.resolve())) {
  const onClose = vi.fn()
  render(<ModalVehiculo vehiculo={vehiculo} onSave={onSave} onClose={onClose} />)
  return { onSave, onClose, user: userEvent.setup() }
}

describe('ModalVehiculo', () => {
  it('normaliza la patente que se ve y manda patente y descripción', async () => {
    const { user, onSave, onClose } = renderModal()
    await user.type(screen.getByLabelText(/Patente/), ' ac 456-ef ')
    expect(screen.getByLabelText(/Patente/)).toHaveValue('AC456EF')

    await user.type(screen.getByLabelText(/Modelo o descripción/), 'Partner')
    await user.click(screen.getByRole('button', { name: 'Guardar vehículo' }))

    expect(onSave).toHaveBeenCalledWith({ patente: 'AC456EF', descripcion: 'Partner' })
    await vi.waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
  })

  it('una patente corta o sin descripción no guarda', async () => {
    const { user, onSave } = renderModal()
    await user.type(screen.getByLabelText(/Patente/), 'AC1')
    await user.click(screen.getByRole('button', { name: 'Guardar vehículo' }))
    expect(screen.getByText('La patente tiene entre 6 y 8 letras o números')).toBeInTheDocument()

    await user.clear(screen.getByLabelText(/Patente/))
    await user.type(screen.getByLabelText(/Patente/), 'AC456EF')
    await user.click(screen.getByRole('button', { name: 'Guardar vehículo' }))
    expect(screen.getByText('Escribí el modelo o una descripción del vehículo')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('edita con id y activo', async () => {
    const { user, onSave } = renderModal({ id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true })
    expect(screen.getByText('Editar vehículo')).toBeInTheDocument()
    await user.click(screen.getByRole('checkbox', { name: 'Activo' }))
    await user.click(screen.getByRole('button', { name: 'Guardar vehículo' }))

    expect(onSave).toHaveBeenCalledWith({ id: 7, patente: 'AC456EF', descripcion: 'Partner', activo: false })
  })

  it('la patente repetida que rechaza el server se muestra', async () => {
    const { user, onClose } = renderModal(
      undefined,
      vi.fn(() => Promise.reject(new Error('Ya existe un vehículo con esa patente'))),
    )
    await user.type(screen.getByLabelText(/Patente/), 'AC456EF')
    await user.type(screen.getByLabelText(/Modelo o descripción/), 'Partner')
    await user.click(screen.getByRole('button', { name: 'Guardar vehículo' }))

    expect(await screen.findByText('Ya existe un vehículo con esa patente')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })
})

describe('modalVehiculoSchema', () => {
  it('acepta una patente de 6 a 8 caracteres en mayúsculas', () => {
    expect(modalVehiculoSchema.safeParse({ patente: 'AC456EF', descripcion: 'x' }).success).toBe(true)
    expect(modalVehiculoSchema.safeParse({ patente: 'ac456ef', descripcion: 'x' }).success).toBe(false)
    expect(modalVehiculoSchema.safeParse({ patente: 'AC45', descripcion: 'x' }).success).toBe(false)
  })
})
