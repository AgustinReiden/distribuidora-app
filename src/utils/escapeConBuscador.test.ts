import { afterEach, describe, expect, it } from 'vitest'
import { noCerrarConBuscadorAbierto } from './escapeConBuscador'

function enfocar(atributos: Record<string, string>): void {
  const el = document.createElement('input')
  for (const [k, v] of Object.entries(atributos)) el.setAttribute(k, v)
  document.body.appendChild(el)
  el.focus()
}

const escape = (): KeyboardEvent => new KeyboardEvent('keydown', { key: 'Escape', cancelable: true })

describe('noCerrarConBuscadorAbierto', () => {
  afterEach(() => { document.body.innerHTML = '' })

  it('con la lista del buscador abierta frena el Escape del modal', () => {
    enfocar({ role: 'combobox', 'aria-expanded': 'true' })
    const evento = escape()
    noCerrarConBuscadorAbierto(evento)
    expect(evento.defaultPrevented).toBe(true)
  })

  it('con la lista cerrada deja que el modal se cierre', () => {
    enfocar({ role: 'combobox', 'aria-expanded': 'false' })
    const evento = escape()
    noCerrarConBuscadorAbierto(evento)
    expect(evento.defaultPrevented).toBe(false)
  })

  it('sin buscador enfocado deja que el modal se cierre', () => {
    enfocar({ type: 'text' })
    const evento = escape()
    noCerrarConBuscadorAbierto(evento)
    expect(evento.defaultPrevented).toBe(false)
  })
})
