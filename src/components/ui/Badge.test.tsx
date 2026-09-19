import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { Check } from 'lucide-react'
import { Badge } from './Badge'
import type { Tone } from '@/lib/estadoTones'

// Las clases de color son CONTRATO: son el motivo por el que existe el
// primitivo (una sola paleta de estado para toda la app), asi que se aseveran.
const SOFT: Array<[Tone, string]> = [
  ['neutral', 'bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-200'],
  ['brand', 'bg-brand-100 text-brand-700 dark:bg-brand-900/30 dark:text-brand-300'],
  ['success', 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300'],
  ['warning', 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300'],
  ['danger', 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300'],
]

const STRONG: Array<[Tone, string]> = [
  ['neutral', 'bg-gray-600 text-white'],
  ['brand', 'bg-brand-600 text-white'],
  ['success', 'bg-green-600 text-white'],
  ['warning', 'bg-amber-600 text-white'],
  ['danger', 'bg-red-600 text-white'],
]

describe('Badge', () => {
  it('renderiza un span con el texto', () => {
    render(<Badge>Entregado</Badge>)
    const badge = screen.getByText('Entregado')

    expect(badge.tagName).toBe('SPAN')
  })

  it.each(SOFT)('tono %s con fill soft', (tone, clases) => {
    render(<Badge tone={tone}>etiqueta</Badge>)

    expect(screen.getByText('etiqueta')).toHaveClass(...clases.split(' '))
  })

  it.each(STRONG)('tono %s con fill strong', (tone, clases) => {
    render(
      <Badge tone={tone} fill="strong">
        etiqueta
      </Badge>
    )

    expect(screen.getByText('etiqueta')).toHaveClass(...clases.split(' '))
  })

  it('sin props es neutral y soft', () => {
    render(<Badge>etiqueta</Badge>)

    expect(screen.getByText('etiqueta')).toHaveClass('bg-gray-100', 'text-gray-700')
  })

  it('el className del consumidor no pisa el tono', () => {
    render(
      <Badge tone="danger" className="bg-gray-100 text-gray-700">
        etiqueta
      </Badge>
    )
    const badge = screen.getByText('etiqueta')

    expect(badge).toHaveClass('bg-red-100', 'text-red-700')
    expect(badge).not.toHaveClass('bg-gray-100')
    expect(badge).not.toHaveClass('text-gray-700')
  })

  it('el className del consumidor si corrige la forma', () => {
    render(<Badge className="px-4">etiqueta</Badge>)
    const badge = screen.getByText('etiqueta')

    expect(badge).toHaveClass('px-4')
    expect(badge).not.toHaveClass('px-2')
  })

  it('por defecto es una pastilla', () => {
    render(<Badge>etiqueta</Badge>)

    expect(screen.getByText('etiqueta')).toHaveClass('rounded-full')
  })

  it('mono usa monoespaciada y esquina en vez de pastilla', () => {
    render(<Badge mono>FC</Badge>)
    const badge = screen.getByText('FC')

    expect(badge).toHaveClass('font-mono', 'tracking-wide', 'rounded-[5px]')
    expect(badge).not.toHaveClass('rounded-full')
  })

  it('el icono es decorativo: no lo anuncia el lector de pantalla', () => {
    const { container } = render(<Badge icon={Check}>Pagado</Badge>)
    const icono = container.querySelector('svg')

    expect(icono).not.toBeNull()
    expect(icono).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByText('Pagado')).toBeInTheDocument()
  })

  it('sin icon no dibuja ningun svg', () => {
    const { container } = render(<Badge>Pagado</Badge>)

    expect(container.querySelector('svg')).toBeNull()
  })

  it('pasa el resto de los atributos al span', () => {
    render(<Badge title="Factura C">FC</Badge>)

    expect(screen.getByText('FC')).toHaveAttribute('title', 'Factura C')
  })
})
