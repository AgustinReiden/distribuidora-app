/**
 * #1697: antes de confirmar la no entrega, el chofer ve que la entrega pasa a mañana (todos los
 * motivos) o que no cambia («Lo rechazó»).
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ModalNoEntrega from './ModalNoEntrega'

function abrir() {
  render(<ModalNoEntrega abierto clienteNombre="Cliente 1" onCancelar={vi.fn()} onConfirmar={vi.fn()} />)
}

describe('ModalNoEntrega — refechado', () => {
  it('sin motivo elegido no dice nada del refechado', () => {
    abrir()
    expect(screen.queryByText(/Refechado/)).toBeNull()
    expect(screen.queryByText(/no cambia/)).toBeNull()
  })

  it('«Estaba cerrado» avisa que la entrega pasa a mañana', () => {
    abrir()
    fireEvent.click(screen.getByRole('button', { name: /Estaba cerrado/ }))
    expect(screen.getByText(/su entrega pasa a mañana y queda marcado «Refechado»/)).toBeInTheDocument()
  })

  it('«Lo rechazó» avisa que la fecha de entrega no cambia', () => {
    abrir()
    fireEvent.click(screen.getByRole('button', { name: /Lo rechazó/ }))
    expect(screen.getByText(/Con «Lo rechazó» la fecha de entrega no cambia/)).toBeInTheDocument()
    expect(screen.queryByText(/Refechado/)).toBeNull()
  })
})
