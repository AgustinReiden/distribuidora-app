/**
 * El primitivo `Combobox`: se asevera por rol ARIA y por teclado, que es lo que
 * el `<select>` nativo daba gratis y este tiene que seguir dando.
 */
import '@testing-library/jest-dom/vitest'
import { useState } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Combobox } from './Combobox'

interface Prov { id: string; nombre: string; cuit: string | null }
const PROVS: Prov[] = [
  { id: '1', nombre: 'José Farías e Hijos SRL', cuit: '30-71234567-8' },
  { id: '2', nombre: 'Manaos SA', cuit: null },
  { id: '3', nombre: 'Distribuidora Norte', cuit: null },
]

function Ejemplo({ onCrear, onSubmit = vi.fn() }: { onCrear?: (t: string) => void; onSubmit?: () => void }) {
  const [valor, setValor] = useState<string | null>(null)
  return (
    <form onSubmit={e => { e.preventDefault(); onSubmit() }}>
      <Combobox
        opciones={PROVS}
        getKey={p => p.id}
        getLabel={p => p.nombre}
        getTextosBusqueda={p => [p.nombre, p.cuit]}
        valor={valor}
        onSeleccionar={p => setValor(p.id)}
        onCrear={onCrear}
        textoCrear={t => `+ Nuevo proveedor "${t}"`}
        aria-label="Proveedor de prueba"
        placeholder="Buscar..."
      />
      <button type="button">Afuera</button>
    </form>
  )
}

const input = () => screen.getByRole('combobox', { name: 'Proveedor de prueba' })

describe('Combobox', () => {
  it('cerrado: aria-expanded=false y sin lista', () => {
    render(<Ejemplo />)
    expect(input()).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('listbox')).toBeNull()
  })

  it('al enfocar abre la lista con todas las opciones', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)
    await user.click(input())
    expect(input()).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getAllByRole('option')).toHaveLength(3)
  })

  it('filtra sin tildes y por CUIT', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)
    await user.type(input(), 'farias')
    expect(screen.getAllByRole('option').map(o => o.textContent)).toEqual(['José Farías e Hijos SRL'])
    await user.clear(input())
    await user.type(input(), '3071234')
    expect(screen.getAllByRole('option').map(o => o.textContent)).toEqual(['José Farías e Hijos SRL'])
  })

  it('con el mouse: elige, cierra y muestra el nombre', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)
    await user.click(input())
    await user.click(screen.getByRole('option', { name: 'Manaos SA' }))
    expect(input()).toHaveValue('Manaos SA')
    expect(input()).toHaveAttribute('aria-expanded', 'false')
    // El foco se queda en el input.
    expect(input()).toHaveFocus()
  })

  it('con teclado: ↓ ↓ ↑ Enter, y la activa se anuncia por aria-activedescendant', async () => {
    const onSubmit = vi.fn()
    const user = userEvent.setup()
    render(<Ejemplo onSubmit={onSubmit} />)
    await user.click(input())
    await user.keyboard('{ArrowDown}{ArrowDown}')
    const activa = input().getAttribute('aria-activedescendant')
    expect(activa).toBeTruthy()
    expect(document.getElementById(activa!)).toHaveTextContent('Manaos SA')
    expect(document.getElementById(activa!)).toHaveAttribute('aria-selected', 'true')
    await user.keyboard('{ArrowDown}{ArrowUp}{Enter}')
    expect(input()).toHaveValue('Manaos SA')
    // Enter en el buscador no manda el formulario.
    expect(onSubmit).not.toHaveBeenCalled()
  })

  it('al tipear, Enter elige la primera', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)
    await user.type(input(), 'norte{Enter}')
    expect(input()).toHaveValue('Distribuidora Norte')
  })

  it('Escape cierra la lista sin elegir y no se propaga', async () => {
    const afuera = vi.fn()
    const user = userEvent.setup()
    render(<div onKeyDown={afuera}><Ejemplo /></div>)
    await user.type(input(), 'man')
    afuera.mockClear()
    fireEvent.keyDown(input(), { key: 'Escape' })
    expect(screen.queryByRole('listbox')).toBeNull()
    expect(input()).toHaveValue('')
    expect(afuera).not.toHaveBeenCalled()
  })

  it('al salir del campo se cierra', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)
    await user.click(input())
    await user.click(screen.getByRole('button', { name: 'Afuera' }))
    expect(screen.queryByRole('listbox')).toBeNull()
  })

  it('ofrece crear con lo tipeado, salvo que ya exista igual', async () => {
    const onCrear = vi.fn()
    const user = userEvent.setup()
    render(<Ejemplo onCrear={onCrear} />)
    await user.type(input(), 'Aguas del Sur')
    await user.click(screen.getByRole('option', { name: '+ Nuevo proveedor "Aguas del Sur"' }))
    expect(onCrear).toHaveBeenCalledWith('Aguas del Sur')

    await user.clear(input())
    await user.type(input(), 'manaos sa')
    expect(screen.queryByRole('option', { name: /Nuevo proveedor/ })).toBeNull()
  })

  it('sin onCrear no hay opción de crear', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)
    await user.type(input(), 'zzz')
    expect(screen.queryAllByRole('option')).toHaveLength(0)
    expect(screen.getByText('Sin resultados')).toBeInTheDocument()
  })
})
