/**
 * ModalBajaEmpleado (entrega 3 de gastos): la baja del empleado con su fecha.
 */
import { describe, it, expect, vi, type Mock } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalBajaEmpleado from './ModalBajaEmpleado'
import { formatPrecio } from '../../utils/formatters'
import type { Empleado } from '../../types/personal'

const EMPLEADO: Empleado = {
  id: 42, nombre: 'Martín Sosa', puesto: 'transportista', sucursal_id: 1, de_las_dos: false,
  cuil: null, fecha_ingreso: null, telefono: null, activo: true, fecha_baja: null,
  usuario: null, cliente: null, vehiculo: null, arreglo: null, arranque: null, saldo: 0, es_propio: false,
}

function renderModal(empleado: Empleado = EMPLEADO) {
  const onConfirmar: Mock<(fecha: string) => Promise<void>> = vi.fn(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(<ModalBajaEmpleado empleado={empleado} hoy="2026-10-29" onConfirmar={onConfirmar} onClose={onClose} />)
  return { onConfirmar, onClose, user: userEvent.setup() }
}

describe('ModalBajaEmpleado', () => {
  it('sin saldo sólo dice que la cuenta queda', () => {
    renderModal()
    expect(screen.getByRole('dialog', { name: 'Dar de baja a Martín Sosa' })).toBeInTheDocument()
    expect(screen.getByText('Su cuenta y su historial quedan. Se puede reactivar.')).toBeInTheDocument()
    expect(screen.queryByText(/Tiene un saldo/)).not.toBeInTheDocument()
    const fecha = screen.getByLabelText(/^Fecha de baja/) as HTMLInputElement
    expect(fecha.value).toBe('2026-10-29')
    expect(fecha.max).toBe('2026-10-29')
  })

  it('con saldo -5000 avisa "en contra"; confirmar manda la fecha', async () => {
    const { onConfirmar, onClose, user } = renderModal({ ...EMPLEADO, saldo: -5000 })
    expect(
      screen.getByText(`Tiene un saldo de ${formatPrecio(5000)} en contra: queda en su cuenta.`.replace(/\s/g, ' ')),
    ).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Dar de baja' }))
    expect(onConfirmar).toHaveBeenCalledWith('2026-10-29')
    expect(onClose).toHaveBeenCalled()
  })

  it('con saldo a favor lo dice', () => {
    renderModal({ ...EMPLEADO, saldo: 1200 })
    expect(
      screen.getByText(`Tiene un saldo de ${formatPrecio(1200)} a su favor: queda en su cuenta.`.replace(/\s/g, ' ')),
    ).toBeInTheDocument()
  })

  it('si la baja falla muestra el error y no cierra', async () => {
    const onConfirmar = vi.fn(() => Promise.reject(new Error('No se pudo')))
    const onClose = vi.fn()
    render(<ModalBajaEmpleado empleado={EMPLEADO} hoy="2026-10-29" onConfirmar={onConfirmar} onClose={onClose} />)
    await userEvent.setup().click(screen.getByRole('button', { name: 'Dar de baja' }))
    expect(await screen.findByText('No se pudo')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })
})
