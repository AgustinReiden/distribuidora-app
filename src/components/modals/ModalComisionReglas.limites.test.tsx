/**
 * B23 de #1603 (decisión del dueño, 18/11): el porcentaje de una regla de comisión sobre 100 queda en
 * rojo y la regla no se agrega. Antes el blur del toque en «Agregar regla» lo recortaba a 100.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mutateAsync = vi.fn()
vi.mock('../../hooks/queries', () => ({
  useComisionReglasQuery: () => ({ data: [], isLoading: false }),
  useGuardarComisionReglaMutation: () => ({ mutateAsync, isPending: false }),
  useDesactivarComisionReglaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))

import ModalComisionReglas from './ModalComisionReglas'

function abrir() {
  render(<ModalComisionReglas preventistas={[]} comisionPreventista={2} comisionOtros={1} onClose={vi.fn()} />)
  return userEvent.setup()
}

beforeEach(() => {
  mutateAsync.mockReset()
  mutateAsync.mockResolvedValue(undefined)
})

describe('ModalComisionReglas — el porcentaje fuera de su límite (B23)', () => {
  it('150 queda en rojo, dice el tope y la regla no se agrega', async () => {
    const user = abrir()
    const input = screen.getByLabelText('Porcentaje')

    await user.clear(input)
    await user.type(input, '150')
    await user.click(screen.getByRole('button', { name: /agregar regla/i }))

    expect(mutateAsync).not.toHaveBeenCalled()
    expect(input).toHaveValue('150')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('No puede pasar de 100 %')
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })

  it('dentro del límite agrega lo tipeado, sin salir antes del campo', async () => {
    const user = abrir()
    const input = screen.getByLabelText('Porcentaje')

    await user.clear(input)
    await user.type(input, '2,5')
    await user.click(screen.getByRole('button', { name: /agregar regla/i }))

    expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ porcentaje: 2.5 }))
  })
})
