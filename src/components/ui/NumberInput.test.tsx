import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { NumberInput } from './NumberInput'
import { NUMERO_ILEGIBLE } from '../../utils/normalizarNumero'

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

  // D17 (#1560, #1542): la tecla del punto es la coma decimal y se ve como coma. Cambió de regla:
  // antes «1.500» tipeado era mil quinientos.
  it.each([
    ['1.500', '1,500', 1.5],
    ['150.000', '150,000', 150],
    ['1.250', '1,250', 1.25],
    ['150000', '150000', 150000],
    ['1500,50', '1500,50', 1500.5],
    ['1,5', '1,5', 1.5],
    ['0,5', '0,5', 0.5],
    ['12.50', '12,50', 12.5],
  ])('tipeado %j se ve %j y se lee %d al confirmar', async (texto, visto, esperado) => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" value={0} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, texto)
    expect(input).toHaveValue(visto)
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(esperado)
  })

  // Lo pegado no pasa por la tecla del punto: se lee como se muestra la plata.
  it.each([
    ['1.500', 1500],
    ['150.000', 150000],
    ['1.500,50', 1500.5],
    ['1.234.567', 1234567],
    ['12.50', 12.5],
  ])('pegado %j se lee %d', async (texto, esperado) => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" value={0} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.paste(texto)
    expect(input).toHaveValue(texto)
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(esperado)
  })

  it('la tecla del punto en el medio se vuelve coma y el cursor queda en su lugar', async () => {
    const user = userEvent.setup()
    render(<NumberInput aria-label="num" value={0} onChange={vi.fn()} />)
    const input = screen.getByLabelText('num') as HTMLInputElement

    await user.clear(input)
    await user.type(input, '125')
    await user.type(input, '.', { initialSelectionStart: 1, initialSelectionEnd: 1 })
    expect(input).toHaveValue('1,25')
    expect(input.selectionStart).toBe(2)
  })

  it('con commitOnChange, lo último confirmado en vivo es lo tipeado entero', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(
      <NumberInput aria-label="num" commitOnChange min={0} value={0} selectOnFocus={false} onChange={onChange} />
    )
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, '150000')
    expect(onChange).toHaveBeenLastCalledWith(150000)

    await user.clear(input)
    await user.type(input, '1500,50')
    expect(onChange).toHaveBeenLastCalledWith(1500.5)
  })

  // #1560-b2: lo que no se entiende no se guarda como otro número (antes «1,000,50» era 1 y el
  // blur lo confirmaba).
  it.each(['1.000,50', '1..5'])('tipeado %j no se entiende: queda en rojo y no se confirma', async texto => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" min={0} value={7} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, texto)
    await user.tab()

    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(input).toHaveAttribute('title', NUMERO_ILEGIBLE)
    expect(onChange).not.toHaveBeenCalled()

    // Al corregirlo se confirma y deja de estar en rojo.
    await user.clear(input)
    await user.type(input, '1000,5')
    await user.tab()
    expect(onChange).toHaveBeenLastCalledWith(1000.5)
    expect(input).not.toHaveAttribute('aria-invalid', 'true')
  })

  it('con commitOnChange, lo que no se entiende no se manda en vivo', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" commitOnChange min={0} value={0} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.paste('1,234,567')

    expect(onChange).not.toHaveBeenCalled()
    expect(input).toHaveAttribute('aria-invalid', 'true')
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

// #1560: un porcentaje no lleva miles. «12.125» % es doce y pico, no doce mil (que el blur
// clampaba a 100).
describe('NumberInput sinMiles', () => {
  it.each([
    ['12.125', 12.13],
    ['12,5', 12.5],
    ['1.250', 1.25],
    ['0,6', 0.6],
    ['100', 100],
  ])('lee %j como %d', async (texto, esperado) => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="pct" sinMiles min={0} max={100} value={0} onChange={onChange} />)
    const input = screen.getByLabelText('pct')

    await user.clear(input)
    await user.type(input, texto)
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(esperado)
  })

  it('deja un solo separador, el decimal', async () => {
    const user = userEvent.setup()
    render(<NumberInput aria-label="pct" sinMiles value={0} selectOnFocus={false} onChange={vi.fn()} />)
    const input = screen.getByLabelText('pct')

    await user.clear(input)
    await user.type(input, '1.2,5')

    // D17: la tecla del punto se escribe como coma.
    expect(input).toHaveValue('1,25')
  })

  // Un campo con tope 100 es un porcentaje: sin `sinMiles`, «12.125» se lee 12125 y el blur lo
  // deja en 100 sin avisar. Recorre `src/` y pide la opción a todo NumberInput decimal con
  // `max={100}`.
  it('todo NumberInput decimal con max={100} lleva sinMiles', () => {
    const raiz = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
    const sinLaOpcion: string[] = []
    const recorrer = (dir: string): void => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const ruta = path.join(dir, e.name)
        if (e.isDirectory()) recorrer(ruta)
        else if (/\.tsx$/.test(e.name) && !/\.test\.tsx$/.test(e.name)) {
          const texto = fs.readFileSync(ruta, 'utf-8')
          for (const m of texto.matchAll(/<NumberInput\b[\s\S]*?\/>/g)) {
            const tag = m[0]
            if (/max=\{100\}/.test(tag) && !/\binteger\b/.test(tag) && !/\bsinMiles\b/.test(tag)) {
              const linea = texto.slice(0, m.index).split('\n').length
              sinLaOpcion.push(`${path.relative(raiz, ruta)}:${linea}`)
            }
          }
        }
      }
    }
    recorrer(raiz)
    expect(sinLaOpcion).toEqual([])
  })
})

