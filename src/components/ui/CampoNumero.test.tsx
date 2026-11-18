/**
 * B20 (D17): el campo de texto para un número que el padre guarda como texto. La misma regla que
 * `NumberInput`: el punto y la coma tipeados son decimales, los miles los pone el campo, lo pegado
 * se lee como se muestra la plata, y lo que no se entiende queda en rojo con el motivo.
 */
import { describe, it, expect } from 'vitest'
import { useState } from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { CampoNumero, type CampoNumeroProps } from './CampoNumero'
import { leerNumero, leerDecimalSinMiles, NUMERO_ILEGIBLE } from '../../utils/normalizarNumero'

function Campo(props: Partial<CampoNumeroProps> & { inicial?: string }) {
  const { inicial = '', ...resto } = props
  const [valor, setValor] = useState(inicial)
  return <CampoNumero aria-label="n" {...resto} value={valor} onChange={setValor} />
}

const campo = () => screen.getByLabelText('n') as HTMLInputElement

describe('CampoNumero', () => {
  it.each([
    ['150000', '150.000', 150000],
    ['1250,5', '1.250,5', 1250.5],
    ['1250.5', '1.250,5', 1250.5],
    ['1.500', '1,500', 1.5],
  ])('tipear %j se ve %j y se lee %d', async (teclas, visto, leido) => {
    const user = userEvent.setup()
    render(<Campo />)
    await user.type(campo(), teclas)
    expect(campo()).toHaveValue(visto)
    expect(leerNumero(visto)).toBe(leido)
  })

  it('pegar «1.250,50» se lee 1250,5', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    await user.click(campo())
    await user.paste('1.250,50')
    expect(campo()).toHaveValue('1.250,50')
    expect(leerNumero(campo().value)).toBe(1250.5)
  })

  it('lo que no se entiende queda en rojo con el motivo a la vista', async () => {
    const user = userEvent.setup()
    render(<Campo />)
    await user.click(campo())
    await user.paste('1,234,567')
    expect(campo()).toHaveAttribute('aria-invalid', 'true')
    expect(campo().className).toContain('!border-red-500')
    expect(screen.getByRole('alert')).toHaveTextContent(NUMERO_ILEGIBLE)
    expect(campo()).toHaveAccessibleDescription(NUMERO_ILEGIBLE)
  })

  it('el padre pone su motivo (un rango, un entero)', () => {
    render(<Campo inicial="1,5" entero motivo="Las cantidades van sin coma" />)
    expect(campo()).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Las cantidades van sin coma')
  })

  it('con dígitos repetidos el cursor no salta: 1.000 → 1.500', async () => {
    const user = userEvent.setup()
    render(<Campo inicial="1.000" />)
    await user.click(campo())
    campo().setSelectionRange(3, 3)
    await user.keyboard('{Backspace}5')
    expect(campo()).toHaveValue('1.500')
  })

  it('sinMiles: un porcentaje o una coordenada no lleva miles; el punto es la coma', async () => {
    const user = userEvent.setup()
    render(<Campo sinMiles />)
    await user.type(campo(), '1250.75')
    expect(campo()).toHaveValue('1250,75')
    expect(leerDecimalSinMiles(campo().value)).toBe(1250.75)
  })

  it('entero: abre el teclado numérico; decimal, el de la coma', () => {
    render(<><CampoNumero aria-label="e" entero value="" onChange={() => {}} /><CampoNumero aria-label="d" value="" onChange={() => {}} /></>)
    expect(screen.getByLabelText('e')).toHaveAttribute('inputmode', 'numeric')
    expect(screen.getByLabelText('d')).toHaveAttribute('inputmode', 'decimal')
    expect(screen.getByLabelText('d')).toHaveAttribute('type', 'text')
  })

  it('negativo: el menos al principio entra', async () => {
    const user = userEvent.setup()
    render(<Campo sinMiles negativo />)
    await user.type(campo(), '-26.8')
    expect(campo()).toHaveValue('-26,8')
  })
})
