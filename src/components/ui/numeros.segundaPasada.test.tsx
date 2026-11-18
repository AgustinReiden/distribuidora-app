/**
 * Lo que encontró la segunda pasada de la lente de #1644 en los tres campos de número y en el
 * registro, tipeando con `userEvent`.
 *
 * - N4: al lado del Guardar frenado, `AvisoCamposEnRojo` dice cuántos campos hay en rojo y lleva al
 *   primero (abre la sección si está cerrada y le pone el foco).
 * - N8: pegar sobre una selección más larga es un pegado (lo dice el evento), y no saca el aviso.
 * - N9: con `commitOnChange` y el padre vacío, lo que no se entiende deja al padre vacío, no con el
 *   pedazo legible.
 * - N11: la segunda mitad del aviso sale sólo con la costumbre de los miles, y con su signo.
 * - N12: el «$» de `InputMonto` va pegado al input, no al bloque que también tiene el aviso.
 */
import { describe, it, expect, vi } from 'vitest'
import { useState, type ReactNode } from 'react'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { NumberInput } from './NumberInput'
import { CampoNumero } from './CampoNumero'
import { InputMonto } from './InputMonto'
import { AvisoCamposEnRojo } from './AvisoCamposEnRojo'
import { AbrirSeccionContext, RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'

function ConRegistro({ children }: { children: ReactNode }) {
  const ilegibles = useRegistroIlegibles()
  return (
    <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
      {children}
      <AvisoCamposEnRojo />
      <button type="button" disabled={ilegibles.hay}>Guardar</button>
    </RegistroIlegiblesContext.Provider>
  )
}

function Texto({ etiqueta, entero = false }: { etiqueta: string; entero?: boolean }) {
  const [t, setT] = useState('')
  return <CampoNumero aria-label={etiqueta} entero={entero} value={t} onChange={setT} />
}

describe('N4: el Guardar frenado dice por qué y lleva al campo', () => {
  it('cuenta los campos en rojo y «Ir al campo» enfoca el primero de la pantalla', async () => {
    const user = userEvent.setup()
    render(
      <ConRegistro>
        <Texto etiqueta="primero" entero />
        <Texto etiqueta="segundo" entero />
      </ConRegistro>,
    )
    expect(screen.queryByText(/campo.* en rojo/)).toBeNull()
    await user.type(screen.getByLabelText('segundo'), '1,5')
    await user.type(screen.getByLabelText('primero'), '2,5')
    expect(screen.getByText('Hay 2 campos en rojo para corregir')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled()
    await user.click(screen.getByRole('button', { name: 'Ir al campo' }))
    await waitFor(() => expect(screen.getByLabelText('primero')).toHaveFocus())
  })

  it('abre la sección cerrada que tiene el campo (como el carrito del alta)', async () => {
    const user = userEvent.setup()
    const abrir = vi.fn()
    render(
      <ConRegistro>
        <AbrirSeccionContext.Provider value={abrir}>
          <Texto etiqueta="cantidad" entero />
        </AbrirSeccionContext.Provider>
      </ConRegistro>,
    )
    await user.type(screen.getByLabelText('cantidad'), '1,2')
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Ir al campo' }))
    expect(abrir).toHaveBeenCalledTimes(1)
    await waitFor(() => expect(screen.getByLabelText('cantidad')).toHaveFocus())
  })

  it('al corregirlo el aviso se va', async () => {
    const user = userEvent.setup()
    render(<ConRegistro><Texto etiqueta="c" entero /></ConRegistro>)
    const campo = screen.getByLabelText('c')
    await user.type(campo, '1,2')
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
    await user.type(campo, '{Backspace}{Backspace}')
    expect(screen.queryByText(/en rojo para corregir/)).toBeNull()
  })
})

describe('N8: pegar sobre una selección más larga es un pegado', () => {
  function Plata({ tipo }: { tipo: 'NumberInput' | 'CampoNumero' | 'InputMonto' }) {
    const [n, setN] = useState(15000)
    const [t, setT] = useState('15.000')
    if (tipo === 'NumberInput') return <NumberInput aria-label="m" commitOnChange value={n} onChange={setN} />
    if (tipo === 'CampoNumero') return <CampoNumero aria-label="m" value={t} onChange={setT} />
    return <InputMonto aria-label="m" value={t} onChange={setT} />
  }

  it.each(['NumberInput', 'CampoNumero', 'InputMonto'] as const)('%s: «1,500» pegado sobre «15.000» no avisa', async tipo => {
    const user = userEvent.setup()
    render(<Plata tipo={tipo} />)
    const campo = screen.getByLabelText('m') as HTMLInputElement
    await user.click(campo)
    campo.setSelectionRange(0, campo.value.length)
    await user.paste('1,500')
    expect(campo).toHaveValue('1,500')
    expect(screen.queryByRole('status')).toBeNull()
  })
})

describe('N9: commitOnChange con el padre vacío', () => {
  it('«1,5» en un entero vacío deja al padre vacío (onVaciar), no en 1', async () => {
    const user = userEvent.setup()
    function Filtro() {
      const [dias, setDias] = useState(0)
      return (
        <>
          <NumberInput aria-label="días" integer commitOnChange value={dias || null} onChange={setDias} onVaciar={() => setDias(0)} />
          <span data-testid="padre">{dias}</span>
        </>
      )
    }
    render(<Filtro />)
    const campo = screen.getByLabelText('días')
    await user.type(campo, '1,5')
    expect(screen.getByTestId('padre')).toHaveTextContent('0')
    await user.tab()
    expect(screen.getByTestId('padre')).toHaveTextContent('0')
    expect(screen.getByRole('alert')).toHaveTextContent('el campo volvió a quedar vacío')
    expect(campo).toHaveValue('')
  })
})

describe('N11: el texto del aviso', () => {
  function Plata({ negativo = false }: { negativo?: boolean }) {
    const [t, setT] = useState('')
    return <CampoNumero aria-label="m" negativo={negativo} value={t} onChange={setT} />
  }

  it.each([
    ['1,0049', /^Se guarda \$\s1,00\.$/],
    ['0,005', /^Se guarda \$\s0,01\.$/],
    ['280.000', /^Se guarda \$\s280,00\. Para \$\s280\.000,00 escribí 280000\.$/],
  ])('«%s» tipeado', async (teclas, esperado) => {
    const user = userEvent.setup()
    render(<Plata />)
    await user.type(screen.getByLabelText('m'), teclas)
    expect(screen.getByRole('status').textContent).toMatch(esperado)
  })

  it('con un negativo conserva el signo', async () => {
    const user = userEvent.setup()
    render(<Plata negativo />)
    await user.type(screen.getByLabelText('m'), '-1.505')
    expect(screen.getByRole('status')).toHaveTextContent(/escribí -1505\.$/)
  })
})

describe('N12: el «$» de InputMonto va pegado al input', () => {
  it('con el aviso arriba, el prefijo comparte el bloque sólo con el input', async () => {
    const user = userEvent.setup()
    function Monto() {
      const [t, setT] = useState('')
      return <div><InputMonto aria-label="m" prefijo="$" avisoCorto value={t} onChange={setT} className="pl-7" /></div>
    }
    render(<Monto />)
    const campo = screen.getByLabelText('m')
    await user.type(campo, '1.500')
    const bloque = campo.parentElement as HTMLElement
    expect(bloque).toHaveClass('relative')
    expect(bloque.children).toHaveLength(2)
    expect(bloque).toHaveTextContent('$')
    // El aviso va afuera del bloque del «$», y en una columna angosta, corto.
    const aviso = screen.getByRole('status')
    expect(bloque.contains(aviso)).toBe(false)
    expect(aviso.textContent).toMatch(/^Se guarda \$\s1,50\.$/)
  })
})
