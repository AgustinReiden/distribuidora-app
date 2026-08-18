/**
 * Tests del campo de fecha opcional de ModalConfirmacion (mig 180 / PR de
 * integridad de ruta).
 *
 * EL INCIDENTE
 * ------------
 * "Marcar entregado" individual estampaba `fecha_entrega` SIEMPRE con la fecha
 * de hoy (`usePedidosQuery.ts`, hardcodeado). El uso real es al revés: el chofer
 * sale el lunes y el encargado marca las entregas el martes a la mañana. Con la
 * fecha fija en hoy, la rendición del lunes quedaba vacía y la del martes
 * inflada con mercadería que no salió ese día. Las entregas MASIVAS ya tenían su
 * selector de fecha desde siempre; la individual no, y nadie lo había notado
 * porque el bug no rompe nada visible: solo mueve la plata de día.
 *
 * Lo que estos tests fijan: que la fecha elegida llegue al `onConfirm` tal cual,
 * que sin campo el modal siga comportándose como antes (17 call sites lo usan
 * sin fecha), y que no se pueda confirmar con la fecha vacía.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ModalConfirmacion, { type ModalConfirmacionConfig } from './ModalConfirmacion'

function renderModal(overrides: Partial<ModalConfirmacionConfig> = {}, onConfirm = vi.fn()) {
  const config: ModalConfirmacionConfig = {
    visible: true,
    tipo: 'success',
    titulo: 'Confirmar entrega',
    mensaje: '¿Confirmar entrega del pedido #4900?',
    onConfirm,
    ...overrides,
  }
  render(<ModalConfirmacion config={config} onClose={vi.fn()} />)
  return { onConfirm }
}

const CAMPO = {
  label: 'Fecha de entrega',
  valorInicial: '2026-08-18',
  max: '2026-08-18',
  ayuda: 'Si estás cargando la entrega de un día anterior, cambiala.',
}

describe('ModalConfirmacion · campo de fecha', () => {
  it('sin campoFecha no muestra ningún input y confirma sin argumento', () => {
    const { onConfirm } = renderModal()

    expect(screen.queryByLabelText(/fecha de entrega/i)).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: /confirmar/i }))
    expect(onConfirm).toHaveBeenCalledWith(undefined)
  })

  it('con campoFecha arranca en el valor inicial y lo devuelve al confirmar', () => {
    const { onConfirm } = renderModal({ campoFecha: CAMPO })

    const input = screen.getByLabelText(/fecha de entrega/i) as HTMLInputElement
    expect(input.value).toBe('2026-08-18')

    fireEvent.click(screen.getByRole('button', { name: /confirmar/i }))
    expect(onConfirm).toHaveBeenCalledWith('2026-08-18')
  })

  it('devuelve la fecha que el usuario eligió, no la de hoy — el caso del incidente', () => {
    const { onConfirm } = renderModal({ campoFecha: CAMPO })

    const input = screen.getByLabelText(/fecha de entrega/i)
    // El encargado marca el martes las entregas que el chofer hizo el lunes.
    fireEvent.change(input, { target: { value: '2026-08-17' } })
    fireEvent.click(screen.getByRole('button', { name: /confirmar/i }))

    expect(onConfirm).toHaveBeenCalledWith('2026-08-17')
  })

  it('no deja confirmar con la fecha vacía', () => {
    const { onConfirm } = renderModal({ campoFecha: CAMPO })

    fireEvent.change(screen.getByLabelText(/fecha de entrega/i), { target: { value: '' } })

    const boton = screen.getByRole('button', { name: /confirmar/i })
    expect((boton as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(boton)
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('no permite elegir una fecha futura', () => {
    renderModal({ campoFecha: CAMPO })
    expect(screen.getByLabelText(/fecha de entrega/i).getAttribute('max')).toBe('2026-08-18')
  })

  it('muestra el texto de ayuda cuando viene', () => {
    renderModal({ campoFecha: CAMPO })
    expect(screen.getByText(/cargando la entrega de un día anterior/i)).toBeTruthy()
  })
})
