import { describe, it, expect } from 'vitest'
import { useState } from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { InputMonto } from './InputMonto'

function Campo({ inicial = '' }: { inicial?: string }) {
  const [valor, setValor] = useState(inicial)
  return <InputMonto aria-label="monto" value={valor} onChange={setValor} />
}

describe('InputMonto', () => {
  it('pone los puntos de miles mientras se tipea', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    const input = screen.getByLabelText('monto')

    await user.type(input, '1500000')

    expect(input).toHaveValue('1.500.000')
  })

  it('los puntos tipeados a mano se respetan: «1.500» es mil quinientos', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    const input = screen.getByLabelText('monto')

    await user.type(input, '1.500')
    await user.tab()

    expect(input).toHaveValue('1.500')
  })

  it('el punto del teclado del celular es la coma decimal al salir del campo', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    const input = screen.getByLabelText('monto')

    await user.type(input, '1500.5')
    await user.tab()

    expect(input).toHaveValue('1.500,5')
  })

  it('al borrar no confunde los miles con decimales', async () => {
    const user = userEvent.setup()
    render(<Campo inicial="1.500" />)
    const input = screen.getByLabelText('monto')

    await user.type(input, '{Backspace}')

    expect(input).toHaveValue('150')
  })

  it('tipear en el medio deja el cursor después del dígito', async () => {
    const user = userEvent.setup()
    render(<Campo inicial="1.500" />)
    const input = screen.getByLabelText('monto') as HTMLInputElement

    await user.click(input)
    input.setSelectionRange(1, 1)
    await user.keyboard('2')

    expect(input).toHaveValue('12.500')
    expect(input.selectionStart).toBe(2)
  })

  it('sale con el teclado numérico', () => {
    render(<Campo />)
    expect(screen.getByLabelText('monto')).toHaveAttribute('inputmode', 'decimal')
  })
})
