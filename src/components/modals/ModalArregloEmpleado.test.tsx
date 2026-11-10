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

const ANTERIOR: ArregloEmpleado = {
  id: 4, vigente_desde: '2026-10-05', vigente_hasta: '2026-10-25', sueldo: 250000, frecuencia: 'semanal', comisiona: false,
}

function renderModal(vigente: ArregloEmpleado | null = VIGENTE, anterior: ArregloEmpleado | null = ANTERIOR) {
  const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalArregloEmpleado
      empleado={{ id: 42, nombre: 'Martín Sosa' }}
      vigente={vigente}
      anterior={anterior}
      hoy="2026-10-29"
      onSave={onSave}
      onClose={onClose}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

/**
 * Envía el formulario sin pasar por la validación nativa de `min`/`max` del input de fecha (que en
 * el navegador, y en jsdom, frena el clic en «Guardar»): lo que se prueba es la regla del modal.
 */
const enviar = () => fireEvent.submit(screen.getByRole('button', { name: 'Guardar arreglo' }).closest('form') as HTMLFormElement)

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

  it('la ayuda de la fecha dice el tope de 60 días y el input lo lleva', () => {
    renderModal()
    expect(screen.getByText('La fecha va hasta 60 días antes o después de hoy.')).toBeInTheDocument()
    const desde = screen.getByLabelText(/^Vale desde/) as HTMLInputElement
    expect(desde.min).toBe('2026-08-30')
    expect(desde.max).toBe('2026-12-28')
  })

  it('el tope se ensancha hasta el vigente cuando éste quedó afuera, para poder corregir sus montos', () => {
    renderModal({ ...VIGENTE, vigente_desde: '2026-01-05' }, null)
    expect((screen.getByLabelText(/^Vale desde/) as HTMLInputElement).min).toBe('2026-01-05')
  })

  it('una fecha más allá del tope no deja guardar y muestra el error', async () => {
    const { onSave } = renderModal()
    fireEvent.change(screen.getByLabelText(/^Vale desde/), { target: { value: '2026-12-29' } })
    enviar()

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'El arreglo vale desde una fecha entre el 30/08/2026 y el 28/12/2026 (hasta 60 días antes o después de hoy)',
    )
  })

  it('sin vigente no hay modo: no ofrece corregir', () => {
    renderModal(null, null)
    expect(screen.queryByRole('group', { name: 'Qué se hace con el arreglo' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Corregir el vigente' })).not.toBeInTheDocument()
  })

  describe('Corregir el vigente', () => {
    it('arranca en «Arreglo nuevo» y al pasar a corregir la fecha vuelve a la del vigente', async () => {
      const { user } = renderModal()
      expect(screen.getByRole('button', { name: 'Arreglo nuevo' })).toHaveAttribute('aria-pressed', 'true')
      expect(screen.getByRole('button', { name: 'Corregir el vigente' })).toHaveAttribute('aria-pressed', 'false')

      const desde = screen.getByLabelText(/^Vale desde/) as HTMLInputElement
      fireEvent.change(desde, { target: { value: '2026-11-02' } })
      await user.click(screen.getByRole('button', { name: 'Corregir el vigente' }))

      expect(screen.getByRole('button', { name: 'Corregir el vigente' })).toHaveAttribute('aria-pressed', 'true')
      expect(desde.value).toBe('2026-10-26')
      expect(screen.getByText('Corrige el arreglo vigente.')).toBeInTheDocument()
    })

    it('al volver a «Arreglo nuevo» se descarta la fecha tocada a mano', async () => {
      const { user } = renderModal()
      await user.click(screen.getByRole('button', { name: 'Corregir el vigente' }))
      const desde = screen.getByLabelText(/^Vale desde/) as HTMLInputElement
      fireEvent.change(desde, { target: { value: '2026-10-20' } })
      await user.click(screen.getByRole('button', { name: 'Arreglo nuevo' }))
      expect(desde.value).toBe('2026-10-26')
    })

    it('manda el id del vigente y la fecha nueva', async () => {
      const { onSave, onClose, user } = renderModal()
      await user.click(screen.getByRole('button', { name: 'Corregir el vigente' }))
      fireEvent.change(screen.getByLabelText(/^Vale desde/), { target: { value: '2026-10-20' } })
      await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))

      expect(onSave).toHaveBeenCalledWith({
        id: 5, vigente_desde: '2026-10-20', sueldo: 280000, frecuencia: 'semanal', comisiona: false,
      })
      expect(onClose).toHaveBeenCalled()
    })

    it('sin tocar la fecha corrige los montos del vigente con su id', async () => {
      const { onSave, user } = renderModal()
      await user.click(screen.getByRole('button', { name: 'Corregir el vigente' }))
      await user.click(screen.getByLabelText('Comisiona'))
      await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))

      expect(onSave).toHaveBeenCalledWith({
        id: 5, vigente_desde: '2026-10-26', sueldo: 280000, frecuencia: 'semanal', comisiona: true,
      })
    })

    it('un arreglo nuevo no manda id', async () => {
      const { onSave, user } = renderModal()
      fireEvent.change(screen.getByLabelText(/^Vale desde/), { target: { value: '2026-11-02' } })
      await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))
      expect(Object.keys(onSave.mock.calls[0][0])).not.toContain('id')
    })

    it('una fecha fuera del tope muestra el error y no guarda', async () => {
      const { onSave, user } = renderModal()
      await user.click(screen.getByRole('button', { name: 'Corregir el vigente' }))
      fireEvent.change(screen.getByLabelText(/^Vale desde/), { target: { value: '2027-02-01' } })
      enviar()

      expect(onSave).not.toHaveBeenCalled()
      expect(await screen.findByRole('alert')).toHaveTextContent(/hasta 60 días antes o después de hoy/)
    })

    it('una fecha que no pasa el arreglo anterior muestra el error y no guarda', async () => {
      const { onSave, user } = renderModal()
      await user.click(screen.getByRole('button', { name: 'Corregir el vigente' }))
      fireEvent.change(screen.getByLabelText(/^Vale desde/), { target: { value: '2026-10-05' } })
      enviar()

      expect(onSave).not.toHaveBeenCalled()
      expect(await screen.findByRole('alert')).toHaveTextContent('El arreglo corregido vale desde después del anterior (05/10/2026)')
    })
  })

  it('sueldo 0 y sin comisión no deja guardar', async () => {
    const { onSave, user } = renderModal(null)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '0')
    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Un arreglo sin sueldo fijo tiene que comisionar')).toBeInTheDocument()
  })

  it('un sueldo en blanco no se guarda como 0: avisa que falta', async () => {
    const { onSave, user } = renderModal(null)
    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Falta el sueldo: poné 0 si es sólo comisión')).toBeInTheDocument()
  })

  it('un sueldo que no se entiende no se guarda y dice cómo escribirlo', async () => {
    const { onSave, user } = renderModal(null)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280,000')
    await user.click(screen.getByRole('button', { name: 'Guardar arreglo' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Escribí el monto con números, por ejemplo 280.000 o 280.000,50')).toBeInTheDocument()
  })

  it('parte del arreglo vigente: sueldo, frecuencia y comisión, y los manda si sólo cambia la fecha', async () => {
    const vigente: ArregloEmpleado = {
      id: 6, vigente_desde: '2026-09-01', vigente_hasta: null, sueldo: 150000, frecuencia: 'mensual', comisiona: true,
    }
    const { onSave, user } = renderModal(vigente)
    expect((screen.getByLabelText(/^Sueldo fijo/) as HTMLInputElement).value).toBe('150.000')
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
