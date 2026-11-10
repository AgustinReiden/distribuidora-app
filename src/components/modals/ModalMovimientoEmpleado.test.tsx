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

  it('un monto que no se entiende no se guarda y dice cómo escribirlo', async () => {
    const { onSave, user } = renderModal()
    await user.type(screen.getByLabelText(/^Monto/), '1,234.56')
    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Escribí el monto con números, por ejemplo 280.000 o 280.000,50')).toBeInTheDocument()
  })

  it('un monto negativo tipeado no se guarda: el signo lo dan los botones', async () => {
    const { onSave, user } = renderModal()
    await user.type(screen.getByLabelText(/^Monto/), '-3000')
    await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Escribí el monto con números, por ejemplo 280.000 o 280.000,50')).toBeInTheDocument()
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

  describe('tope del pago por el saldo', () => {
    function renderConSaldo(saldo: number) {
      const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
      render(
        <ModalMovimientoEmpleado
          empleado={{ id: 42, nombre: 'Martín Sosa' }}
          hoy="2026-10-29"
          saldo={saldo}
          onSave={onSave}
          onClose={vi.fn()}
        />,
      )
      return { onSave, user: userEvent.setup() }
    }

    it('un pago mayor que el saldo muestra el error y no guarda', async () => {
      const { onSave, user } = renderConSaldo(1000)
      await user.click(screen.getByRole('button', { name: 'Pago' }))
      await user.type(screen.getByLabelText(/^Monto/), '1500')
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))

      expect(onSave).not.toHaveBeenCalled()
      expect(await screen.findByText(
        'No se le puede pagar más de lo que se le debe: si le adelantás plata, cargá un adelanto',
      )).toBeInTheDocument()
    })

    it('un pago igual al saldo guarda, y la ayuda dice cuánto se le debe', async () => {
      const { onSave, user } = renderConSaldo(1000)
      await user.click(screen.getByRole('button', { name: 'Pago' }))
      expect(screen.getByText(/^Se le debe .*1\.000,00: más que eso es un adelanto\.$/)).toBeInTheDocument()
      await user.type(screen.getByLabelText(/^Monto/), '1000')
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ tipo: 'pago', monto: 1000 }))
    })

    it('con saldo en contra no se le paga nada, pero el adelanto no tiene tope', async () => {
      const { onSave, user } = renderConSaldo(-300)
      await user.type(screen.getByLabelText(/^Monto/), '50000')
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ tipo: 'adelanto', monto: 50000 }))

      await user.click(screen.getByRole('button', { name: 'Pago' }))
      expect(screen.getByText(/^Se le debe .*0,00: más que eso es un adelanto\.$/)).toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(await screen.findByText(/No se le puede pagar más de lo que se le debe/)).toBeInTheDocument()
      expect(onSave).toHaveBeenCalledTimes(1)
    })
  })

  describe('pago', () => {
    const TRANSPORTISTAS = [{ id: 'u-9', nombre: 'Martín Sosa' }, { id: 'u-10', nombre: 'Pablo Ríos' }]

    function renderConPlata() {
      const onSave: Mock<OnSave> = vi.fn<OnSave>(() => Promise.resolve())
      const onClose: Mock<() => void> = vi.fn()
      render(
        <ModalMovimientoEmpleado
          empleado={{ id: 42, nombre: 'Martín Sosa' }}
          hoy="2026-10-29"
          transportistas={TRANSPORTISTAS}
          onSave={onSave}
          onClose={onClose}
        />,
      )
      return { onSave, onClose, user: userEvent.setup() }
    }

    it("la pastilla 'Pago' va entre el adelanto y el ajuste, con su ayuda", async () => {
      const { user } = renderConPlata()
      const nombres = screen.getAllByRole('button', { pressed: false }).map(b => b.textContent)
      expect(nombres.indexOf('Pago')).toBeGreaterThan(-1)

      await user.click(screen.getByRole('button', { name: 'Pago' }))
      expect(screen.getByText('Plata que se le paga de lo que tiene a favor.')).toBeInTheDocument()
    })

    it('un pago de 50000 manda { tipo: pago, monto, fecha: hoy, observacion: null, origen_pago: oficina }', async () => {
      const { onSave, onClose, user } = renderConPlata()
      await user.click(screen.getByRole('button', { name: 'Pago' }))
      await user.type(screen.getByLabelText(/^Monto/), '50000')
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))

      expect(onSave).toHaveBeenCalledWith({
        tipo: 'pago',
        monto: 50000,
        fecha: '2026-10-29',
        observacion: null,
        origen_pago: 'oficina',
        rendicion_transportista_id: null,
        rendicion_fecha: null,
      })
      expect(onClose).toHaveBeenCalled()
    })

    it('la observación del pago es opcional', async () => {
      const { onSave, user } = renderConPlata()
      await user.click(screen.getByRole('button', { name: 'Pago' }))
      expect(screen.queryByLabelText(/^Por qué/)).not.toBeInTheDocument()
      await user.type(screen.getByLabelText(/^Observación/), 'Aguinaldo')
      await user.type(screen.getByLabelText(/^Monto/), '1000')
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ tipo: 'pago', observacion: 'Aguinaldo' }))
    })

    it('con una rendición pide transportista y día', async () => {
      const { onSave, user } = renderConPlata()
      await user.click(screen.getByRole('button', { name: 'Pago' }))
      await user.type(screen.getByLabelText(/^Monto/), '50000')
      await user.click(screen.getByRole('button', { name: 'Con la plata de una rendición' }))

      // El día de la rendición reemplaza a la fecha.
      expect(screen.queryByLabelText(/^Fecha/)).not.toBeInTheDocument()
      expect(screen.getByLabelText('Día de la rendición')).toHaveValue('2026-10-29')

      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(onSave).not.toHaveBeenCalled()
      expect(await screen.findByText('Elegí de qué rendición sale la plata: el transportista y el día')).toBeInTheDocument()

      await user.click(screen.getByRole('combobox', { name: 'Transportista' }))
      await user.click(screen.getByRole('option', { name: 'Martín Sosa' }))
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(onSave).toHaveBeenCalledWith({
        tipo: 'pago',
        monto: 50000,
        fecha: '2026-10-29',
        observacion: null,
        origen_pago: 'rendicion',
        rendicion_transportista_id: 'u-9',
        rendicion_fecha: '2026-10-29',
      })
    })

    it('un adelanto no ofrece la rendición ni manda sus campos', async () => {
      const { onSave, user } = renderConPlata()
      expect(screen.queryByRole('button', { name: 'Con la plata de una rendición' })).not.toBeInTheDocument()
      await user.type(screen.getByLabelText(/^Monto/), '20000')
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(onSave).toHaveBeenCalledWith({ tipo: 'adelanto', monto: 20000, fecha: '2026-10-29', observacion: null })
      expect(Object.keys(onSave.mock.calls[0][0])).toEqual(['tipo', 'monto', 'fecha', 'observacion'])
    })

    it('Escape con la lista de choferes abierta cierra sólo la lista, no el modal', async () => {
      const { onClose, user } = renderConPlata()
      await user.click(screen.getByRole('button', { name: 'Pago' }))
      await user.click(screen.getByRole('button', { name: 'Con la plata de una rendición' }))
      await user.click(screen.getByRole('combobox', { name: 'Transportista' }))
      expect(screen.getByRole('combobox', { name: 'Transportista' })).toHaveAttribute('aria-expanded', 'true')

      await user.keyboard('{Escape}')
      expect(onClose).not.toHaveBeenCalled()
      expect(screen.getByRole('combobox', { name: 'Transportista' })).toHaveAttribute('aria-expanded', 'false')
    })

    it('un ajuste no ofrece la rendición', async () => {
      const { user } = renderConPlata()
      await user.click(screen.getByRole('button', { name: 'Ajuste' }))
      expect(screen.queryByRole('button', { name: 'Con la plata de una rendición' })).not.toBeInTheDocument()
    })

    it('un pago de 0 no deja', async () => {
      const { onSave, user } = renderConPlata()
      await user.click(screen.getByRole('button', { name: 'Pago' }))
      await user.type(screen.getByLabelText(/^Monto/), '0')
      await user.click(screen.getByRole('button', { name: 'Registrar movimiento' }))
      expect(onSave).not.toHaveBeenCalled()
      expect(await screen.findByText('El monto tiene que ser mayor a cero')).toBeInTheDocument()
    })
  })
})
