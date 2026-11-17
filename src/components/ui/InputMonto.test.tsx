import { describe, it, expect } from 'vitest'
import { useState } from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { InputMonto } from './InputMonto'
import { parseMonto } from '../../utils/personal'

function Campo({ inicial = '' }: { inicial?: string }) {
  const [valor, setValor] = useState(inicial)
  return <InputMonto aria-label="monto" value={valor} onChange={setValor} />
}

// B20 (D17, cambió de regla): el punto y la coma tipeados son decimales, y el punto de miles lo
// pone el campo. Antes «1.500» tipeado era mil quinientos.
describe('InputMonto', () => {
  it('pone los puntos de miles mientras se tipea', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    const input = screen.getByLabelText('monto')

    await user.type(input, '1500000')

    expect(input).toHaveValue('1.500.000')
    expect(parseMonto((input as HTMLInputElement).value)).toBe(1500000)
  })

  it.each([
    ['1250,5', '1.250,5', 1250.5],
    ['1250.5', '1.250,5', 1250.5],
    ['150000', '150.000', 150000],
  ])('tipear %j se ve %j y se lee %d', async (teclas, visto, leido) => {
    const user = userEvent.setup()
    render(<Campo />)
    const input = screen.getByLabelText('monto')

    await user.type(input, teclas)

    expect(input).toHaveValue(visto)
    expect(parseMonto(visto)).toBe(leido)
  })

  it('el punto tipeado es la coma decimal: «1.500» se ve «1,500», en rojo (tres decimales)', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    const input = screen.getByLabelText('monto')

    await user.type(input, '1.500')

    expect(input).toHaveValue('1,500')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(parseMonto('1,500')).toBeNull()
  })

  it('pegar «1.250,50» se lee 1250,5', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    const input = screen.getByLabelText('monto')

    await user.click(input)
    await user.paste('1.250,50')

    expect(input).toHaveValue('1.250,50')
    expect(parseMonto('1.250,50')).toBe(1250.5)
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

  it('con dígitos repetidos, 1.000 → 1.500 (no 1.005)', async () => {
    const user = userEvent.setup()
    render(<Campo inicial="1.000" />)
    const input = screen.getByLabelText('monto') as HTMLInputElement

    await user.click(input)
    input.setSelectionRange(3, 3)
    await user.keyboard('{Backspace}5')

    expect(input).toHaveValue('1.500')
  })

  it('sale con el teclado numérico', () => {
    render(<Campo />)
    expect(screen.getByLabelText('monto')).toHaveAttribute('inputmode', 'decimal')
  })
})
