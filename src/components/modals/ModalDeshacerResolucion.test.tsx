/**
 * ModalDeshacerResolucion (gastos 6): deshacer una resolución pide un motivo obligatorio y se
 * confirma sólo con el botón.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalDeshacerResolucion, { type ModalDeshacerResolucionProps } from './ModalDeshacerResolucion'

function renderModal(props: Partial<ModalDeshacerResolucionProps> = {}) {
  const onDeshacer = vi.fn<ModalDeshacerResolucionProps['onDeshacer']>(() => Promise.resolve())
  const onClose = vi.fn()
  render(
    <ModalDeshacerResolucion
      fecha="2026-10-28"
      transportistaNombre="Tito Transportista"
      guardando={false}
      onDeshacer={onDeshacer}
      onClose={onClose}
      {...props}
    />,
  )
  return { onDeshacer, onClose, user: userEvent.setup() }
}

const BOTON = { name: 'Deshacer resolución' }

describe('ModalDeshacerResolucion', () => {
  it('dice a qué rendición y qué se deshace', () => {
    renderModal()

    expect(screen.getByText('Tito Transportista')).toBeInTheDocument()
    expect(screen.getByText('28/10/2026')).toBeInTheDocument()
    expect(screen.getByText(
      'Se compensan las deudas, se anulan los gastos de la resolución y la rendición vuelve a disconformidad.',
    )).toBeInTheDocument()
  })

  it('sin motivo no deja deshacer', async () => {
    const { user, onDeshacer } = renderModal()

    expect(screen.getByRole('button', BOTON)).toBeDisabled()
    await user.type(screen.getByLabelText(/¿Por qué se deshace\?/), '   ')
    expect(screen.getByRole('button', BOTON)).toBeDisabled()
    expect(onDeshacer).not.toHaveBeenCalled()
  })

  it('manda el motivo sin espacios sobrantes', async () => {
    const { user, onDeshacer } = renderModal()

    await user.type(screen.getByLabelText(/¿Por qué se deshace\?/), '  Me equivoqué de empleado  ')
    await user.click(screen.getByRole('button', BOTON))

    expect(onDeshacer).toHaveBeenCalledWith('Me equivoqué de empleado')
  })

  it('Enter en el campo no confirma', async () => {
    const { user, onDeshacer } = renderModal()

    await user.type(screen.getByLabelText(/¿Por qué se deshace\?/), 'motivo{Enter}')

    expect(onDeshacer).not.toHaveBeenCalled()
  })

  it('mientras guarda no se puede deshacer ni cancelar', () => {
    renderModal({ guardando: true })

    expect(screen.getByRole('button', { name: 'Cancelar' })).toBeDisabled()
  })
})
