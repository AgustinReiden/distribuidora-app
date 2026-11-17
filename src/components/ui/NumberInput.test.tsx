import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { useState } from 'react'
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

  // D17 (#1560, #1542): el punto y la coma tipeados son decimales (la tecla del punto se ve como
  // coma) y el punto de miles lo pone el campo. Cambió de regla: antes «1.500» tipeado era mil
  // quinientos; ahora para eso se escribe «1500» y se ve «1.500».
  it.each([
    ['1.500', '1,500', 1.5],
    ['150.000', '150,000', 150],
    ['1.250', '1,250', 1.25],
    ['150000', '150.000', 150000],
    ['1500,50', '1.500,50', 1500.5],
    ['1234567', '1.234.567', 1234567],
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
    ['1.500', '1.500', 1500],
    ['150.000', '150.000', 150000],
    ['1.500,50', '1.500,50', 1500.5],
    ['1.234.567', '1.234.567', 1234567],
    ['1500,5', '1.500,5', 1500.5],
    ['12.50', '12,50', 12.5],
  ])('pegado %j se ve %j y se lee %d', async (texto, visto, esperado) => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" value={0} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.paste(texto)
    expect(input).toHaveValue(visto)
    await user.tab()

    expect(onChange).toHaveBeenLastCalledWith(esperado)
  })

  it('el valor del padre se muestra con los miles', () => {
    render(<NumberInput aria-label="num" value={1500.5} onChange={vi.fn()} />)
    expect(screen.getByLabelText('num')).toHaveValue('1.500,5')
  })

  it('en modo entero también pone los miles, y una coma no es una cantidad', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" integer value={0} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, '12500')
    expect(input).toHaveValue('12.500')
    await user.tab()
    expect(onChange).toHaveBeenLastCalledWith(12500)

    await user.clear(input)
    await user.type(input, '1.5')
    expect(input).toHaveValue('1,5')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Las cantidades van sin coma')
    await user.tab()
    // No se confirma: vuelve a lo que tiene el padre, y lo dice.
    expect(onChange).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('alert')).toHaveTextContent('No se entendió «1,5»')
  })

  describe('el cursor y los puntos de miles', () => {
    const montar = (value: number) => {
      render(<NumberInput aria-label="num" value={value} selectOnFocus={false} onChange={vi.fn()} />)
      return screen.getByLabelText('num') as HTMLInputElement
    }

    // H2 de la lente de #1644: con dígitos repetidos el cursor saltaba y la tecla siguiente caía en
    // otro lugar (1.000 → 1.500 terminaba en 1.005). Tecla por tecla: lo que se ve, con el cursor.
    it.each([
      [1000, 3, ['{Backspace}', '5'], ['1|00', '1.5|00'], 1500],
      [10000, 4, ['{Backspace}', '5'], ['1.0|00', '10.5|00'], 10500],
      [1000, 3, ['0', '5'], ['10.0|00', '100.5|00'], 100500],
      [22222, 1, ['2', '3'], ['22|2.222', '2.23|2.222'], 2232222],
      [111111, 5, ['{Backspace}', '9'], ['11.1|11', '111.9|11'], 111911],
      [2222, 3, ['{Delete}', '7'], ['22|2', '2.27|2'], 2272],
      [100000, 2, ['{Delete}', '5'], ['10|.000', '105|.000'], 105000],
    ])('%d con el cursor en %d, %j: se ve %j y se guarda %d', async (valor, pos, teclas, vistos, guardado) => {
      const user = userEvent.setup()
      const onChange = vi.fn()
      render(<NumberInput aria-label="num" commitOnChange min={0} value={valor} selectOnFocus={false} onChange={onChange} />)
      const input = screen.getByLabelText('num') as HTMLInputElement
      await user.click(input)
      input.setSelectionRange(pos, pos)
      const paso: string[] = []
      for (const t of teclas) {
        await user.keyboard(t)
        const c = input.selectionStart ?? 0
        paso.push(`${input.value.slice(0, c)}|${input.value.slice(c)}`)
      }
      expect(paso).toEqual(vistos)
      await user.tab()
      expect(onChange).toHaveBeenLastCalledWith(guardado)
    })

    it('un dígito en el medio queda donde se tipeó aunque entre un punto', async () => {
      const user = userEvent.setup()
      const input = montar(1000)
      // «1|.000» + 5 → «15|.000»
      await user.type(input, '5', { initialSelectionStart: 1, initialSelectionEnd: 1 })
      expect(input).toHaveValue('15.000')
      expect(input.selectionStart).toBe(2)
    })

    it('tipear al final de «150» lo agrupa y el cursor queda al final', async () => {
      const user = userEvent.setup()
      const input = montar(150)
      await user.type(input, '0', { initialSelectionStart: 3, initialSelectionEnd: 3 })
      expect(input).toHaveValue('1.500')
      expect(input.selectionStart).toBe(5)
    })

    it('borrar un cero de «1.500» da «150»', async () => {
      const user = userEvent.setup()
      const input = montar(1500)
      await user.type(input, '{Backspace}', { initialSelectionStart: 5, initialSelectionEnd: 5 })
      expect(input).toHaveValue('150')
      expect(input.selectionStart).toBe(3)
    })

    it('Backspace justo después de un punto de miles borra el dígito de antes', async () => {
      const user = userEvent.setup()
      const input = montar(15000)
      // «15.|000»
      await user.type(input, '{Backspace}', { initialSelectionStart: 3, initialSelectionEnd: 3 })
      expect(input).toHaveValue('1.000')
      expect(input.selectionStart).toBe(1)
    })

    it('Supr justo antes de un punto de miles borra el dígito de después', async () => {
      const user = userEvent.setup()
      const input = montar(1500)
      // «1|.500»
      await user.type(input, '{Delete}', { initialSelectionStart: 1, initialSelectionEnd: 1 })
      expect(input).toHaveValue('100')
      expect(input.selectionStart).toBe(1)
    })

    it('seleccionar todo y tipear reemplaza', async () => {
      const user = userEvent.setup()
      const onChange = vi.fn()
      render(<NumberInput aria-label="num" value={1500.5} onChange={onChange} />)
      const input = screen.getByLabelText('num')
      await user.click(input) // selectOnFocus: selecciona todo
      await user.keyboard('7')
      expect(input).toHaveValue('7')
      await user.tab()
      expect(onChange).toHaveBeenLastCalledWith(7)
    })

    it('el campo vacío queda vacío', async () => {
      const user = userEvent.setup()
      const input = montar(5)
      await user.type(input, '{Backspace}', { initialSelectionStart: 1, initialSelectionEnd: 1 })
      expect(input).toHaveValue('')
    })
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
  // Mientras se edita, lo que no se entiende queda en rojo con el motivo escrito debajo (H7: no
  // sólo en un `title`, que en el celular no se ve).
  it.each(['1.000,50', '1..5'])('tipeado %j no se entiende: rojo, con el motivo a la vista, y no se manda', async texto => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" min={0} value={7} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.type(input, texto)

    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent(NUMERO_ILEGIBLE)
    expect(input).toHaveAccessibleDescription(NUMERO_ILEGIBLE)
    expect(input.className).toContain('!border-red-500')
    expect(onChange).not.toHaveBeenCalled()

    // Al corregirlo se confirma y deja de estar en rojo.
    await user.clear(input)
    await user.type(input, '1000,5')
    await user.tab()
    expect(onChange).toHaveBeenLastCalledWith(1000.5)
    expect(input).not.toHaveAttribute('aria-invalid', 'true')
    expect(screen.queryByRole('alert')).toBeNull()
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

  // H4: un negativo pegado donde el campo no los lleva no le llega al padre.
  it('pegar «-50» no le manda -50 al padre: queda en rojo y lo dice', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<NumberInput aria-label="num" commitOnChange min={0} value={10} onChange={onChange} />)
    const input = screen.getByLabelText('num')

    await user.clear(input)
    await user.paste('-50')

    expect(onChange).not.toHaveBeenCalled()
    expect(input).toHaveValue('-50')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Este campo no lleva números negativos')
  })

  // H1: lo que se ve es lo que se guarda.
  describe('al salir con algo que no se entiende, vuelve al valor del padre y lo avisa', () => {
    function ConGuardar({ inicial, commitOnChange = false, onGuardar, onValidez }: {
      inicial: number
      commitOnChange?: boolean
      onGuardar: (n: number, visto: string) => void
      onValidez?: (valido: boolean) => void
    }) {
      const [v, setV] = useState(inicial)
      return (
        <>
          <NumberInput aria-label="num" min={0} value={v} onChange={setV} commitOnChange={commitOnChange} onValidez={onValidez} />
          <button type="button" onClick={() => setV(2000)}>Total</button>
          <button
            type="button"
            onClick={() => onGuardar(v, (screen.getByLabelText('num') as HTMLInputElement).value)}
          >
            Guardar
          </button>
        </>
      )
    }

    it.each([
      ['tipeado «150.5.» sobre 100', 100, false, 'tipea', '150.5.', '100'],
      ['pegado «1,234,567» sobre 15000, en vivo', 15000, true, 'pega', '1,234,567', '15.000'],
    ])('%s: Guardar guarda lo que se ve', async (_caso, inicial, enVivo, como, texto, visto) => {
      const user = userEvent.setup()
      const onGuardar = vi.fn()
      const onValidez = vi.fn()
      render(<ConGuardar inicial={inicial} commitOnChange={enVivo} onGuardar={onGuardar} onValidez={onValidez} />)
      const input = screen.getByLabelText('num')

      await user.clear(input)
      if (como === 'tipea') await user.type(input, texto)
      else await user.paste(texto)
      expect(input).toHaveAttribute('aria-invalid', 'true')
      expect(onValidez).toHaveBeenLastCalledWith(false)

      await user.click(screen.getByRole('button', { name: 'Guardar' }))

      expect(onGuardar).toHaveBeenCalledWith(inicial, visto)
      expect(input).toHaveValue(visto)
      expect(input).not.toHaveAttribute('aria-invalid', 'true')
      expect(onValidez).toHaveBeenLastCalledWith(true)
      expect(screen.getByRole('alert')).toHaveTextContent('No se entendió')
      expect(screen.getByRole('alert')).toHaveTextContent(`el campo volvió a «${visto}»`)
    })

    it('un cambio del padre desde afuera (el botón «Total») se ve aunque el campo estuviera en rojo', async () => {
      const user = userEvent.setup()
      render(<ConGuardar inicial={100} onGuardar={vi.fn()} />)
      const input = screen.getByLabelText('num')

      await user.clear(input)
      await user.type(input, '150.5.')
      expect(input).toHaveValue('150,5,')

      await user.click(screen.getByRole('button', { name: 'Total' }))
      expect(input).toHaveValue('2.000')
      expect(input).not.toHaveAttribute('aria-invalid', 'true')
      expect(screen.queryByRole('alert')).toBeNull()
    })

    it('el aviso se va al volver a tipear', async () => {
      const user = userEvent.setup()
      render(<ConGuardar inicial={100} onGuardar={vi.fn()} />)
      const input = screen.getByLabelText('num')

      await user.clear(input)
      await user.type(input, '1..5')
      await user.tab()
      expect(screen.getByRole('alert')).toHaveTextContent('No se entendió «1,,5»')

      await user.click(input)
      await user.keyboard('5')
      expect(screen.queryByRole('alert')).toBeNull()
    })
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

  it('no pone miles: un litro o un porcentaje no llega a mil', async () => {
    const user = userEvent.setup()
    render(<NumberInput aria-label="pct" sinMiles value={1500} selectOnFocus={false} onChange={vi.fn()} />)
    const input = screen.getByLabelText('pct')
    expect(input).toHaveValue('1500')
    await user.clear(input)
    await user.type(input, '12500')
    expect(input).toHaveValue('12500')
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

