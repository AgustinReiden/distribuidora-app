import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { Clock } from 'lucide-react'
import { IconBadge, type IconBadgeSize, type IconBadgeTone } from './IconBadge'

const TONOS: IconBadgeTone[] = ['brand', 'success', 'warning', 'danger', 'neutral']

const CAJAS: Record<IconBadgeSize, string> = {
  sm: 'w-7',
  md: 'w-[34px]',
  lg: 'w-11',
}

describe('IconBadge', () => {
  it('sin label es decorativo: aria-hidden y fuera del arbol accesible', () => {
    const { container } = render(<IconBadge icon={Clock} tone="brand" size="md" />)

    // Al lado siempre hay texto que dice lo mismo; anunciarlo dos veces molesta.
    expect(screen.queryByRole('img')).toBeNull()
    expect(container.querySelector('span[aria-hidden="true"]')).toBeInTheDocument()
  })

  it('con label es una imagen con nombre accesible', () => {
    render(<IconBadge icon={Clock} tone="warning" size="md" label="Pedidos pendientes" />)

    const badge = screen.getByRole('img', { name: 'Pedidos pendientes' })
    expect(badge).toBeInTheDocument()
    expect(badge).not.toHaveAttribute('aria-hidden')
  })

  it.each(TONOS)('el tono %s renderiza su par de clases', tono => {
    const { container } = render(<IconBadge icon={Clock} tone={tono} size="md" />)

    const badge = container.querySelector('span')
    expect(badge).not.toBeNull()
    // Cada tono pinta fondo Y texto (el icono hereda el color por currentColor).
    expect(badge?.className).toMatch(/\bbg-/)
    expect(badge?.className).toMatch(/\btext-/)
  })

  it.each(Object.keys(CAJAS) as IconBadgeSize[])('el tamaño %s pinta su caja', tamano => {
    const { container } = render(<IconBadge icon={Clock} tone="neutral" size={tamano} />)

    const clases = container.querySelector('span')?.className.split(/\s+/) ?? []
    expect(clases).toContain(CAJAS[tamano])
  })

  it('renderiza el icono que le pasan, tambien decorativo', () => {
    const { container } = render(<IconBadge icon={Clock} tone="success" size="lg" />)

    const svg = container.querySelector('svg')
    expect(svg).toBeInTheDocument()
    expect(svg).toHaveAttribute('aria-hidden', 'true')
  })

  it('acepta className del consumidor', () => {
    const { container } = render(
      <IconBadge icon={Clock} tone="neutral" size="sm" className="ml-2" />
    )

    expect(container.querySelector('span')?.className.split(/\s+/)).toContain('ml-2')
  })
})
