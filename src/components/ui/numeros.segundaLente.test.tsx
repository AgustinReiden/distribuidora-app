/**
 * Lo que encontró la segunda lente de #1644 en los tres campos de número, tipeando con `userEvent`
 * (no pegando: pegar es atómico y esconde los pedazos de un tipeo).
 *
 * - H4: con `commitOnChange`, mientras lo tipeado no se entiende el padre vuelve al valor de antes
 *   de tipear (nunca al último pedazo legible), y con un registro alrededor el formulario no guarda.
 * - H6 (decisión del dueño, 17/11: «Que guarde 1,50 pero salga un aviso en amarillo no grande sobre
 *   el campo»): «1.500» tipeado en la plata guarda 1,5 con un aviso amarillo (`role="status"`), sin
 *   rojo y sin frenar el guardado. «1500» no avisa; lo pegado y lo precargado tampoco.
 * - H7/H8: `CampoNumero sinMiles` filtra las letras, decide el rojo con `leerDecimalSinMiles` y
 *   repone el cursor; un negativo pegado en un campo sin `negativo` va en rojo.
 */
import { describe, it, expect } from 'vitest'
import { useState } from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { NumberInput } from './NumberInput'
import { CampoNumero } from './CampoNumero'
import { InputMonto } from './InputMonto'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'
import { parsePrecio } from '../../utils/calculations'
import { parseMonto } from '../../utils/personal'

type Tipo = 'NumberInput' | 'CampoNumero' | 'InputMonto'

/** Un formulario de verdad: el campo, el registro y un Guardar que lee lo que guarda el padre. */
function Formulario({ tipo, inicial, commit = true, entero = false, onGuardar }: {
  tipo: Tipo
  inicial: number
  commit?: boolean
  entero?: boolean
  onGuardar: (n: number | null) => void
}) {
  const ilegibles = useRegistroIlegibles()
  const [numero, setNumero] = useState<number>(inicial)
  const [texto, setTexto] = useState<string>(inicial ? String(inicial) : '')
  const leer = (): number | null => (tipo === 'NumberInput' ? numero : tipo === 'InputMonto' ? parseMonto(texto) : parsePrecio(texto))
  return (
    <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
      {tipo === 'NumberInput' && (
        <NumberInput aria-label="n" integer={entero} commitOnChange={commit} min={0} value={numero} onChange={setNumero} />
      )}
      {tipo === 'CampoNumero' && <CampoNumero aria-label="n" entero={entero} value={texto} onChange={setTexto} />}
      {tipo === 'InputMonto' && <InputMonto aria-label="n" value={texto} onChange={setTexto} />}
      <button type="button" disabled={ilegibles.hay} onClick={() => onGuardar(leer())}>Guardar</button>
      <span data-testid="padre">{tipo === 'NumberInput' ? numero : texto}</span>
    </RegistroIlegiblesContext.Provider>
  )
}

const guardar = () => screen.getByRole('button', { name: 'Guardar' })

describe('H4: con commitOnChange el padre no se queda con un pedazo de lo tipeado', () => {
  it.each([
    [true, '1.200', 5],
    [false, '1..5', 15000],
    [false, '1,000,50', 15000],
  ])('entero=%s, «%s» tipeado sobre %d: el padre vuelve a lo de antes y Guardar queda frenado', async (entero, teclas, inicial) => {
    const user = userEvent.setup()
    const guardados: (number | null)[] = []
    render(<Formulario tipo="NumberInput" entero={entero} inicial={inicial} onGuardar={n => guardados.push(n)} />)
    const campo = screen.getByLabelText('n')
    await user.click(campo)
    await user.keyboard(teclas)
    expect(campo).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByTestId('padre')).toHaveTextContent(String(inicial))
    expect(guardar()).toBeDisabled()
    await user.click(guardar())
    expect(guardados).toEqual([])
    // Al salir, con el registro alrededor, sigue en rojo (no vuelve callado a lo de antes).
    expect(campo).toHaveAttribute('aria-invalid', 'true')
  })

  it('al corregirlo, el padre recibe lo nuevo y Guardar se habilita', async () => {
    const user = userEvent.setup()
    const guardados: (number | null)[] = []
    render(<Formulario tipo="NumberInput" entero inicial={5} onGuardar={n => guardados.push(n)} />)
    const campo = screen.getByLabelText('n')
    await user.click(campo)
    await user.keyboard('1.200')
    await user.clear(campo)
    await user.type(campo, '1200')
    expect(campo).toHaveValue('1.200')
    expect(guardar()).toBeEnabled()
    await user.click(guardar())
    expect(guardados).toEqual([1200])
  })
})

describe('H6: «1.500» tipeado en la plata se guarda 1,50 con el aviso amarillo', () => {
  it.each<Tipo>(['NumberInput', 'CampoNumero', 'InputMonto'])('%s', async tipo => {
    const user = userEvent.setup()
    const guardados: (number | null)[] = []
    render(<Formulario tipo={tipo} inicial={0} onGuardar={n => guardados.push(n)} />)
    const campo = screen.getByLabelText('n')
    await user.clear(campo)
    await user.type(campo, '1.500')
    expect(campo).toHaveValue('1,500')
    expect(campo).not.toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('status')).toHaveTextContent(/Se guarda \$\s1,50\. Para \$\s1\.500,00 escribí 1500\./)
    expect(screen.queryByRole('alert')).toBeNull()
    expect(guardar()).toBeEnabled()
    await user.click(guardar())
    expect(guardados).toEqual([1.5])
    // Sigue a la vista al salir del campo, hasta que el valor cambie.
    expect(screen.getByRole('status')).toHaveTextContent('Se guarda')
  })

  it.each<Tipo>(['NumberInput', 'CampoNumero', 'InputMonto'])('%s: «1.505» avisa lo que se guarda al centavo (1,51)', async tipo => {
    const user = userEvent.setup()
    const guardados: (number | null)[] = []
    render(<Formulario tipo={tipo} inicial={0} onGuardar={n => guardados.push(n)} />)
    const campo = screen.getByLabelText('n')
    await user.clear(campo)
    await user.type(campo, '1.505')
    expect(screen.getByRole('status')).toHaveTextContent(/Se guarda \$\s1,51\./)
    await user.click(guardar())
    expect(guardados).toEqual([1.51])
  })

  it.each<Tipo>(['NumberInput', 'CampoNumero', 'InputMonto'])('%s: «1500» tipeado no avisa', async tipo => {
    const user = userEvent.setup()
    render(<Formulario tipo={tipo} inicial={0} onGuardar={() => {}} />)
    const campo = screen.getByLabelText('n')
    await user.clear(campo)
    await user.type(campo, '1500')
    expect(campo).toHaveValue('1.500')
    expect(screen.queryByRole('status')).toBeNull()
  })

  it.each<Tipo>(['NumberInput', 'CampoNumero', 'InputMonto'])('%s: lo pegado no avisa', async tipo => {
    const user = userEvent.setup()
    render(<Formulario tipo={tipo} inicial={0} onGuardar={() => {}} />)
    const campo = screen.getByLabelText('n')
    await user.clear(campo)
    await user.click(campo)
    await user.paste('1,500')
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('lo precargado no avisa', () => {
    render(<CampoNumero aria-label="n" value="1,505" onChange={() => {}} />)
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('un aviso desaparece cuando el valor cambia', async () => {
    const user = userEvent.setup()
    render(<Formulario tipo="CampoNumero" inicial={0} onGuardar={() => {}} />)
    const campo = screen.getByLabelText('n')
    await user.clear(campo)
    await user.type(campo, '1.500')
    expect(screen.getByRole('status')).toBeInTheDocument()
    await user.type(campo, '{Backspace}')
    expect(screen.queryByRole('status')).toBeNull()
  })
})

describe('H7 y H8: CampoNumero sin miles y los negativos', () => {
  function SinMiles({ negativo = false }: { negativo?: boolean }) {
    const [t, setT] = useState('')
    return <CampoNumero aria-label="n" sinMiles negativo={negativo} value={t} onChange={setT} />
  }

  it('las letras tipeadas no entran', async () => {
    const user = userEvent.setup()
    render(<SinMiles />)
    await user.type(screen.getByLabelText('n'), '0x1a0')
    expect(screen.getByLabelText('n')).toHaveValue('010')
  })

  it('«1.234,5» pegado no se reescribe callado: queda en rojo (lo decide leerDecimalSinMiles)', async () => {
    const user = userEvent.setup()
    render(<SinMiles />)
    await user.click(screen.getByLabelText('n'))
    await user.paste('1.234,5')
    expect(screen.getByLabelText('n')).toHaveValue('1.234,5')
    expect(screen.getByLabelText('n')).toHaveAttribute('aria-invalid', 'true')
  })

  it('la tecla del punto en el medio deja el cursor en su lugar', async () => {
    const user = userEvent.setup()
    render(<SinMiles />)
    const campo = screen.getByLabelText('n') as HTMLInputElement
    await user.type(campo, '105')
    await user.type(campo, '.', { initialSelectionStart: 2, initialSelectionEnd: 2 })
    expect(campo).toHaveValue('10,5')
    expect(campo.selectionStart).toBe(3)
  })

  it('un negativo pegado en un campo sin negativo va en rojo; con negativo, no', async () => {
    const user = userEvent.setup()
    const { unmount } = render(<SinMiles />)
    await user.click(screen.getByLabelText('n'))
    await user.paste('-50')
    expect(screen.getByLabelText('n')).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Este campo no lleva números negativos')
    unmount()
    render(<SinMiles negativo />)
    await user.click(screen.getByLabelText('n'))
    await user.paste('-50')
    expect(screen.getByLabelText('n')).not.toHaveAttribute('aria-invalid', 'true')
  })

  it('un negativo pegado en la plata sin negativo (el IVA del ajuste) va en rojo', async () => {
    const user = userEvent.setup()
    render(<Formulario tipo="CampoNumero" inicial={0} onGuardar={() => {}} />)
    await user.click(screen.getByLabelText('n'))
    await user.paste('-50')
    expect(screen.getByLabelText('n')).toHaveAttribute('aria-invalid', 'true')
    expect(guardar()).toBeDisabled()
  })
})
