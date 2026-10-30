/**
 * ModalArregloEmpleado (entrega 3 de gastos): cambiar el arreglo de sueldo desde la cuenta.
 */
import { describe, it, expect, vi, type Mock } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalArregloEmpleado from './ModalArregloEmpleado'
import type { ArregloEmpleado, GuardarArregloPayload } from '../../types/personal'

const VIGENTE: ArregloEmpleado = {
  id: 5, vigente_desde: '2026-10-26', vigente_hasta: null, sueldo: 280000, frecuencia: 'semanal', comisiona: false,
}

type OnSave = (a: GuardarArregloPayload) => Promise<void>

function renderModal(vigente: ArregloEmpleado | null = VIGENTE) {
  const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalArregloEmpleado
      empleado={{ id: 42, nombre: 'Martín Sosa' }}
      vigente={vigente}
      hoy="2026-10-29"
      onSave={onSave}
      onClose={onClose}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

describe('ModalArregloEmpleado', () => {
  it('arranca en el inicio del período y manda el arreglo', async () => {
    const { onSave, onClose, user } = renderModal(null)
    expect(screen.getByRole('dialog', { name: 'Cambiar arreglo' })).toBeInTheDocument()
    expect(screen.getByText('Los períodos anteriores conservan el arreglo que tenían.')).toBeInTheDocument()
    expect((screen.getByLabelText(/^Vale desde/) as HTMLInputElement).value).toBe('2026-10-26')

    await user.type(screen.getByLabelText(/^Sueldo fijo/), '300.000')
    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))

    expect(onSave).toHaveBeenCalledWith({
      vigente_desde: '2026-10-26', sueldo: 300000, frecuencia: 'semanal', comisiona: false,
    })
    expect(onClose).toHaveBeenCalled()
  })

  it('la misma fecha que el vigente dice "Corrige el arreglo vigente."', () => {
    renderModal()
    expect(screen.getByText('Corrige el arreglo vigente.')).toBeInTheDocument()
  })

  it('una fecha anterior al vigente no deja guardar y muestra el error', async () => {
    const { onSave, user } = renderModal()
    fireEvent.change(screen.getByLabelText(/^Vale desde/), { target: { value: '2026-10-19' } })
    expect(screen.queryByText('Corrige el arreglo vigente.')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText(/Un arreglo nuevo vale desde después del vigente \(26\/10\/2026\)/)).toBeInTheDocument()
  })

  it('sin sueldo y sin comisión no deja guardar', async () => {
    const { onSave, user } = renderModal(null)
    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Un arreglo sin sueldo fijo tiene que comisionar')).toBeInTheDocument()
  })

  it('parte del arreglo vigente: sueldo, frecuencia y comisión, y los manda si sólo cambia la fecha', async () => {
    const vigente: ArregloEmpleado = {
      id: 6, vigente_desde: '2026-09-01', vigente_hasta: null, sueldo: 150000, frecuencia: 'mensual', comisiona: true,
    }
    const { onSave, user } = renderModal(vigente)
    expect((screen.getByLabelText(/^Sueldo fijo/) as HTMLInputElement).value).toBe('150000')
    expect(screen.getByRole('button', { name: 'Mensual' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: 'Semanal' })).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByLabelText('Comisiona')).toBeChecked()
    // La fecha sigue a la frecuencia heredada: inicio del mes de hoy.
    expect((screen.getByLabelText(/^Vale desde/) as HTMLInputElement).value).toBe('2026-10-01')

    fireEvent.change(screen.getByLabelText(/^Vale desde/), { target: { value: '2026-10-15' } })
    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))

    expect(onSave).toHaveBeenCalledWith({
      vigente_desde: '2026-10-15', sueldo: 150000, frecuencia: 'mensual', comisiona: true,
    })
  })

  it('la fecha sigue a la frecuencia hasta que se la toca a mano', async () => {
    const { user } = renderModal(null)
    const desde = screen.getByLabelText(/^Vale desde/) as HTMLInputElement
    await user.click(screen.getByRole('button', { name: 'Mensual' }))
    expect(desde.value).toBe('2026-10-01')
  })

  it('si guardar falla muestra el error y no cierra', async () => {
    const onSave = vi.fn(() => Promise.reject(new Error('El server dijo que no')))
    const onClose = vi.fn()
    render(
      <ModalArregloEmpleado
        empleado={{ id: 42, nombre: 'Martín Sosa' }} vigente={null} hoy="2026-10-29" onSave={onSave} onClose={onClose}
      />,
    )
    const user = userEvent.setup()
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '1000')
    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))
    expect(await screen.findByText('El server dijo que no')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })
})
