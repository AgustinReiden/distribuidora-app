/**
 * ModalMovimientoEmpleado (entrega 3 de gastos): adelanto en efectivo o ajuste manual.
 */
import { describe, it, expect, vi, type Mock } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalMovimientoEmpleado from './ModalMovimientoEmpleado'
import type { MovimientoManualPayload } from '../../types/personal'

type OnSave = (m: MovimientoManualPayload) => Promise<void>

function renderModal() {
  const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalMovimientoEmpleado
      empleado={{ id: 42, nombre: 'Martín Sosa' }}
      hoy="2026-10-29"
      onSave={onSave}
      onClose={onClose}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

describe('ModalMovimientoEmpleado', () => {
  it('un adelanto de 20000 manda { tipo: adelanto, monto: 20000, fecha: hoy, observacion: null }', async () => {
    const { onSave, onClose, user } = renderModal()
    expect(screen.getByRole('dialog', { name: 'Nuevo movimiento' })).toBeInTheDocument()
    expect(
      screen.getByText('Plata que se le da a cuenta del sueldo. Sale de la oficina y se descuenta al liquidar.'),
    ).toBeInTheDocument()
    const fecha = screen.getByLabelText(/^Fecha/) as HTMLInputElement
    expect(fecha.value).toBe('2026-10-29')
    expect(fecha.max).toBe('2026-10-29')

    await user.type(screen.getByLabelText(/^Monto/), '20000')
    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))

    expect(onSave).toHaveBeenCalledWith({ tipo: 'adelanto', monto: 20000, fecha: '2026-10-29', observacion: null })
    expect(onClose).toHaveBeenCalled()
  })

  it('un ajuste En contra 3000 manda monto: -3000, y sin "Por qué" no deja', async () => {
    const { onSave, user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Ajuste' }))
    expect(
      screen.getByText('A su favor suma a lo que la empresa le debe; en contra, a lo que él le debe a la empresa.'),
    ).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'En contra' }))
    await user.type(screen.getByLabelText(/^Monto/), '3000')

    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('El ajuste necesita una observación que diga por qué')).toBeInTheDocument()

    await user.type(screen.getByLabelText(/^Por qué/), 'Faltante de caja')
    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
    expect(onSave).toHaveBeenCalledWith({
      tipo: 'ajuste', monto: -3000, fecha: '2026-10-29', observacion: 'Faltante de caja',
    })
  })

  it('un ajuste A su favor manda el monto positivo', async () => {
    const { onSave, user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Ajuste' }))
    await user.type(screen.getByLabelText(/^Monto/), '1.500')
    await user.type(screen.getByLabelText(/^Por qué/), 'Diferencia')
    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ tipo: 'ajuste', monto: 1500 })
  })

  it('un adelanto sin monto no deja', async () => {
    const { onSave, user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('El monto tiene que ser mayor a cero')).toBeInTheDocument()
  })

  it('si guardar falla muestra el error y no cierra', async () => {
    const onSave = vi.fn(() => Promise.reject(new Error('Sin permisos')))
    const onClose = vi.fn()
    render(
      <ModalMovimientoEmpleado
        empleado={{ id: 42, nombre: 'Martín Sosa' }} hoy="2026-10-29" onSave={onSave} onClose={onClose}
      />,
    )
    const user = userEvent.setup()
    await user.type(screen.getByLabelText(/^Monto/), '500')
    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
    expect(await screen.findByText('Sin permisos')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })
})
