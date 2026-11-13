import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { NumberInput } from './NumberInput'

describe('NumberInput', () => {
  it('permite vaciar el campo y no fuerza 0 mientras se edita', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" integer value={5} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)

    expect(input).toHaveValue('')
    // Por defecto recién confirma en blur: vaciar no dispara onChange todavía.
    expect(onChange).not.toHaveBeenCalled()
  })

  it('no deja el cero adelante al escribir junto a un 0', async () => {
    const user = userEvent.setup()
    render(
      <NumberInput aria-label="num" integer value={0} selectOnFocus={false} onChange={vi.fn()} />
    )
    const input = screen.getByLabelText('num')

    await user.type(input, '5') // el DOM ve "05", se sanitiza a "5"

    expect(input).toHaveValue('5')
  })

  it('ignora caracteres no numéricos en modo entero', async () => {
    const user = userEvent.setup()
    render(
      <NumberInput aria-label="num" integer value={0} selectOnFocus={false} onChange={vi.fn()} />
    )
    const input = screen.getByLabelText('num')

    await user.type(input, '1a2')

    expect(input).toHaveValue('12')
  })

  it('confirma el mínimo (emptyValue) cuando queda vacío al salir', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" integer min={1} value={3} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.tab() // blur

    expect(onChange).toHaveBeenLastCalledWith(1)
  })

  it('clampa al máximo al confirmar', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" integer max={10} value={5} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, '50')
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(10)
  })

  it('parsea decimales con coma', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" value={0} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, '12,5')
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(12.5)
  })

  it('confirma con Enter', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" integer value={2} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, '9{Enter}')

    expect(onChange).toHaveBeenLastCalledWith(9)
  })

  it('con commitOnChange confirma en vivo', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(
      <NumberInput
        aria-label="num"
        integer
        commitOnChange
        value={0}
        selectOnFocus={false}
        onChange={onChange}
      />
    )
    const input = screen.getByLabelText('num')

    await user.type(input, '7')

    expect(onChange).toHaveBeenCalledWith(7)
  })

  // #1560: el punto de miles y la coma decimal, como la app muestra la plata.
  it.each([
    ['1.500', 1500],
    ['150.000', 150000],
    ['1.500,50', 1500.5],
    ['1,5', 1.5],
    ['0,5', 0.5],
    ['12.50', 12.5],
    ['1.234.567', 1234567],
  ])('lee %j como %d al confirmar', async (texto, esperado) => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" value={0} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, texto)
    expect(input).toHaveValue(texto)
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(esperado)
  })

  it('con commitOnChange, lo último confirmado en vivo es lo tipeado entero', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(
      <NumberInput aria-label="num" commitOnChange min={0} value={0} selectOnFocus={false} onChange={onChange} />
    )
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, '150.000')
    expect(onChange).toHaveBeenLastCalledWith(150000)

    await user.clear(input)
    await user.type(input, '1.500,50')
    expect(onChange).toHaveBeenLastCalledWith(1500.5)
  })

  it('muestra el valor con coma decimal: sumarle ceros no lo vuelve miles', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" value={1.5} selectOnFocus={false} onChange={onChange} />)
    const input = screen.getByLabelText('num')
    expect(input).toHaveValue('1,5')

    await user.type(input, '00')
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(1.5)
  })
})

