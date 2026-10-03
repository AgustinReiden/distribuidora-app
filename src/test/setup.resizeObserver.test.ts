/**
 * Fija el contrato del ResizeObserver de src/test/setup.js (#735).
 *
 * `autoUpdate` de @floating-ui, que usan los DropdownMenu, Select y Popover de
 * Radix, hace `new ResizeObserver(...)`. Un `vi.fn().mockImplementation(() => ...)`
 * con funcion flecha se puede llamar pero no construir, y abrir cualquier menu
 * en jsdom tiraba "is not a constructor". Si alguien lo vuelve a cambiar por un
 * mock flecha, este test lo canta sin tener que abrir un menu.
 */
import { describe, it, expect } from 'vitest'

describe('setup de tests: ResizeObserver', () => {
  it('se puede construir con new', () => {
    expect(() => new ResizeObserver(() => {})).not.toThrow()
    expect(new ResizeObserver(() => {})).toBeInstanceOf(ResizeObserver)
  })

  it('observe, unobserve y disconnect existen y se pueden llamar', () => {
    const observador = new ResizeObserver(() => {})
    const elemento = document.createElement('div')

    expect(() => {
      observador.observe(elemento)
      observador.unobserve(elemento)
      observador.disconnect()
    }).not.toThrow()
  })
})
