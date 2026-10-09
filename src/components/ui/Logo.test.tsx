import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { Logo } from './Logo'

describe('Logo', () => {
  it('el completo es UNA imagen con el nombre de la marca, aunque lleve las dos variantes', () => {
    const { container } = render(<Logo variante="completo" />)

    // jsdom no aplica Tailwind: las dos <img> están "visibles" y, si cada una
    // tuviera su alt, el nombre se anunciaría dos veces.
    expect(screen.getAllByRole('img')).toHaveLength(1)
    expect(screen.getByRole('img', { name: 'Crecer Distribuciones' })).toBeInTheDocument()

    const imagenes = container.querySelectorAll('img')
    expect(imagenes).toHaveLength(2)
    imagenes.forEach(img => expect(img).toHaveAttribute('alt', ''))
  })

  it('el completo muestra una variante por modo: la clara se oculta en oscuro y la oscura al revés', () => {
    const { container } = render(<Logo variante="completo" />)
    const [claro, oscuro] = Array.from(container.querySelectorAll('img'))

    expect(claro.className).toMatch(/\bdark:hidden\b/)
    expect(claro.className).not.toMatch(/(^|\s)hidden\b/)
    expect(oscuro.className).toMatch(/(^|\s)hidden\b/)
    expect(oscuro.className).toMatch(/\bdark:block\b/)
    expect(claro.getAttribute('src')).not.toBe(oscuro.getAttribute('src'))
  })

  it('la de la barra también es UNA imagen con el nombre, con la flecha sola en el celular y CRECER desde sm', () => {
    const { container } = render(<Logo variante="barra" className="2xl:ml-4" />)

    const logo = screen.getByRole('img', { name: 'Crecer Distribuciones' })
    expect(screen.getAllByRole('img')).toHaveLength(1)
    expect(logo).toHaveClass('2xl:ml-4')
    // Si flex la achica, el logo se deforma y se monta sobre los botones de al lado.
    expect(logo).toHaveClass('shrink-0')

    const [isotipo, compacto] = Array.from(container.querySelectorAll('img'))
    expect(isotipo.className).toMatch(/\bsm:hidden\b/)
    expect(compacto.className).toMatch(/(^|\s)hidden\b/)
    expect(compacto.className).toMatch(/\bsm:block\b/)
    for (const img of [isotipo, compacto]) {
      expect(img).toHaveAttribute('alt', '')
      expect(img).toHaveClass('max-w-none')
    }
  })
})
