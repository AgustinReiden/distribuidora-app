import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalAnularGasto from './ModalAnularGasto'
import type { Gasto } from '../../types/gastos'

const GASTO = {
  id: 7, monto_total: 8500, rubro: { id: 3, nombre: 'Librería', grupo: 'administracion' },
} as unknown as Gasto

function renderModal(onConfirm = vi.fn(() => Promise.resolve())) {
  const onClose = vi.fn()
  render(<ModalAnularGasto gasto={GASTO} onConfirm={onConfirm} onClose={onClose} />)
  return { onConfirm, onClose, user: userEvent.setup() }
}

describe('ModalAnularGasto', () => {
  it('sin motivo no anula y dice qué hacer', async () => {
    const { user, onConfirm } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Anular gasto' }))

    expect(onConfirm).not.toHaveBeenCalled()
    expect(screen.getByText('Escribí por qué se anula')).toBeInTheDocument()
  })

  it('manda el motivo sin espacios sobrantes y se cierra', async () => {
    const { user, onConfirm, onClose } = renderModal()
    await user.type(screen.getByLabelText(/Motivo/), '  Cargado dos veces ')
    await user.click(screen.getByRole('button', { name: 'Anular gasto' }))

    expect(onConfirm).toHaveBeenCalledWith('Cargado dos veces')
    await vi.waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
  })

  it('el rechazo del server se muestra y no se cierra', async () => {
    const { user, onClose } = renderModal(vi.fn(() => Promise.reject(new Error('El encargado sólo edita los gastos que cargó'))))
    await user.type(screen.getByLabelText(/Motivo/), 'Error')
    await user.click(screen.getByRole('button', { name: 'Anular gasto' }))

    expect(await screen.findByText('El encargado sólo edita los gastos que cargó')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('Cancelar cierra sin anular', async () => {
    const { user, onClose, onConfirm } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))

    expect(onClose).toHaveBeenCalled()
    expect(onConfirm).not.toHaveBeenCalled()
  })
})
