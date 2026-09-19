/**
 * Card: lo que se asevera acá es CONTRATO del primitivo —la etiqueta que
 * renderiza, los atributos que deja pasar, y las pocas clases que un consumidor
 * mira (el acento de 4px, la sombra de hover, el padding que se puede pisar)—.
 * El resto del look no se fija: cambiar un tono de gris no tiene que romper
 * ningún test.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import Card from './Card'

describe('Card', () => {
  it('renderiza un <div> con los hijos adentro', () => {
    render(<Card>contenido</Card>)

    const tarjeta = screen.getByText('contenido')
    expect(tarjeta.tagName).toBe('DIV')
  })

  it('`as` cambia la etiqueta renderizada', () => {
    const { rerender } = render(<Card as="section">x</Card>)
    expect(screen.getByText('x').tagName).toBe('SECTION')

    rerender(<Card as="article">x</Card>)
    expect(screen.getByText('x').tagName).toBe('ARTICLE')

    rerender(<Card as="li">x</Card>)
    expect(screen.getByText('x').tagName).toBe('LI')
  })

  it('deja pasar los atributos extra al elemento', () => {
    render(<Card aria-label="tarjeta" data-testid="c" id="kpi-1">x</Card>)

    const tarjeta = screen.getByTestId('c')
    expect(screen.getByLabelText('tarjeta')).toBe(tarjeta)
    expect(tarjeta).toHaveAttribute('id', 'kpi-1')
  })

  it('deja pasar el onClick', async () => {
    const user = userEvent.setup()
    const onClick = vi.fn()
    render(<Card variant="row" interactive onClick={onClick}>fila</Card>)

    await user.click(screen.getByText('fila'))

    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('cada variante trae su propio padding por defecto', () => {
    const { rerender } = render(<Card variant="section">x</Card>)
    expect(screen.getByText('x')).toHaveClass('p-4')

    rerender(<Card variant="stat">x</Card>)
    expect(screen.getByText('x')).toHaveClass('p-3')

    rerender(<Card variant="row">x</Card>)
    expect(screen.getByText('x')).toHaveClass('py-3', 'px-3.5')
  })

  it('`padding` explícito pisa el de la variante', () => {
    render(<Card variant="stat" padding="md">x</Card>)

    const tarjeta = screen.getByText('x')
    expect(tarjeta).toHaveClass('p-4')
    expect(tarjeta).not.toHaveClass('p-3')
  })

  it('`padding="none"` deja la tarjeta sin padding propio', () => {
    render(<Card padding="none">x</Card>)

    expect(screen.getByText('x').className).not.toMatch(/(^|\s)p[xy]?-/)
  })

  it('`accent` pinta el borde izquierdo de 4px del tono, con su variante dark', () => {
    render(<Card variant="stat" accent="danger">kpi</Card>)

    expect(screen.getByText('kpi')).toHaveClass(
      'border-l-4',
      'border-l-red-600',
      'dark:border-l-red-400',
    )
  })

  it('los cinco tonos dan cinco colores distintos y ninguno se repite', () => {
    const tonos = ['neutral', 'brand', 'success', 'warning', 'danger'] as const
    const vistos = new Set<string>()

    for (const tono of tonos) {
      const { unmount } = render(<Card accent={tono}>x</Card>)
      const clases = screen.getByText('x').className
      expect(clases).toContain('border-l-4')
      vistos.add(clases)
      unmount()
    }

    expect(vistos.size).toBe(tonos.length)
  })

  it('sin `accent` no hay borde de acento', () => {
    render(<Card variant="stat">kpi</Card>)

    expect(screen.getByText('kpi')).not.toHaveClass('border-l-4')
  })

  it('`interactive` suma la sombra de hover y sin él no está', () => {
    const { rerender } = render(<Card variant="row" interactive>fila</Card>)
    expect(screen.getByText('fila')).toHaveClass('hover:shadow-warm-md')

    rerender(<Card variant="row">fila</Card>)
    expect(screen.getByText('fila')).not.toHaveClass('hover:shadow-warm-md')
  })

  it('la sombra base convive con la de hover en vez de pisarse', () => {
    render(<Card interactive>x</Card>)

    expect(screen.getByText('x')).toHaveClass('shadow-warm', 'hover:shadow-warm-md')
  })

  it('el className del consumidor gana sobre el padding de la variante', () => {
    render(<Card className="p-8">x</Card>)

    const tarjeta = screen.getByText('x')
    expect(tarjeta).toHaveClass('p-8')
    expect(tarjeta).not.toHaveClass('p-4')
  })
})
