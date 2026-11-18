/**
 * T3 de la tercera pasada de #1644: en un campo sin miles, una inserción de varios caracteres que
 * NO llega como «pegar» (el chip del portapapeles de Gboard, el reemplazo de texto, el dictado
 * llegan como `insertText`) se filtraba como si fuera una tecla: «-26.82, -65.22» quedaba
 * «-26,826522» y «1.234,5» quedaba 1,2345, sin rojo. Ahora entra tal cual y el lector lo marca.
 * Tipear de a un carácter sigue igual.
 */
import { describe, it, expect } from 'vitest'
import { useState } from 'react'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { NumberInput } from './NumberInput'
import { CampoNumero } from './CampoNumero'
import { AvisoCamposEnRojo } from './AvisoCamposEnRojo'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'

function Coordenada() {
  const [t, setT] = useState('')
  return <CampoNumero aria-label="c" sinMiles negativo value={t} onChange={setT} />
}

function Porcentaje() {
  const [n, setN] = useState(0)
  return <NumberInput aria-label="p" sinMiles commitOnChange value={n} onChange={setN} />
}

// T5: «Ir al campo» abre el `<details>` cerrado que tiene el campo en rojo (las opciones avanzadas
// del grupo de precio): en un navegador, adentro de uno cerrado el campo no se ve ni toma el foco.
describe('T5: «Ir al campo» abre un <details> cerrado', () => {
  it('lo abre y le pone el foco al campo', async () => {
    const user = userEvent.setup()
    function Form() {
      const ilegibles = useRegistroIlegibles()
      const [t, setT] = useState('')
      return (
        <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
          <details data-testid="avanzadas">
            <summary>Opciones avanzadas</summary>
            <CampoNumero aria-label="precio" value={t} onChange={setT} />
          </details>
          <AvisoCamposEnRojo />
        </RegistroIlegiblesContext.Provider>
      )
    }
    render(<Form />)
    const detalles = screen.getByTestId('avanzadas') as HTMLDetailsElement
    detalles.open = true
    await user.type(screen.getByLabelText('precio'), '1..5')
    detalles.open = false
    await user.click(screen.getByRole('button', { name: 'Ir al campo' }))
    await waitFor(() => expect(screen.getByLabelText('precio')).toHaveFocus())
    expect(detalles.open).toBe(true)
  })
})

const insertarComoTexto =(campo: HTMLElement, texto: string) =>
  fireEvent.input(campo, { target: { value: texto }, inputType: 'insertText' })

describe('T3: lo insertado de una vez en un campo sin miles no se recorta callado', () => {
  it.each(['-26.82, -65.22', '1.234,5'])('CampoNumero sinMiles: «%s» insertado como texto queda en rojo', texto => {
    render(<Coordenada />)
    const campo = screen.getByLabelText('c')
    insertarComoTexto(campo, texto)
    expect(campo).toHaveAttribute('aria-invalid', 'true')
  })

  it('NumberInput sinMiles: «1.234,5» insertado como texto queda en rojo', () => {
    render(<Porcentaje />)
    const campo = screen.getByLabelText('p')
    insertarComoTexto(campo, '1.234,5')
    expect(campo).toHaveAttribute('aria-invalid', 'true')
  })

  it('tipear de a un carácter sigue filtrando: «-26.82» se ve «-26,82» y no es rojo', async () => {
    const user = userEvent.setup()
    render(<Coordenada />)
    const campo = screen.getByLabelText('c')
    await user.type(campo, '-26.82')
    expect(campo).toHaveValue('-26,82')
    expect(campo).not.toHaveAttribute('aria-invalid', 'true')
  })

  it('tipear «12.5» en el porcentaje se ve «12,5» y no es rojo', async () => {
    const user = userEvent.setup()
    render(<Porcentaje />)
    const campo = screen.getByLabelText('p')
    await user.clear(campo)
    await user.type(campo, '12.5')
    expect(campo).toHaveValue('12,5')
    expect(campo).not.toHaveAttribute('aria-invalid', 'true')
  })
})
