import { describe, it, expect, vi } from 'vitest'
import { createRef } from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { Button } from './Button'
import { buttonClasses, type ButtonSize, type ButtonVariant } from './button-variants'

const VARIANTES: ButtonVariant[] = ['primary', 'secondary', 'ghost', 'danger', 'success', 'hero']
const TAMANOS: ButtonSize[] = ['sm', 'md', 'lg', 'touch', 'icon', 'iconSm']

describe('Button', () => {
  it('es un boton con nombre accesible', () => {
    render(<Button>Guardar</Button>)

    expect(screen.getByRole('button', { name: 'Guardar' })).toBeInTheDocument()
  })

  it('NO fija type: adentro de un form el navegador tiene que poder asumir submit', () => {
    render(<Button>Guardar</Button>)

    // Si algun dia esto se rompe, los formularios que mandan con Enter dejan de
    // mandar y no falla nada visible.
    expect(screen.getByRole('button', { name: 'Guardar' })).not.toHaveAttribute('type')
  })

  it('propaga el type cuando el consumidor lo pasa', () => {
    render(<Button type="button">Cancelar</Button>)

    expect(screen.getByRole('button', { name: 'Cancelar' })).toHaveAttribute('type', 'button')
  })

  it('disabled bloquea el click', async () => {
    const user = userEvent.setup()
    const onClick = vi.fn()
    render(
      <Button disabled onClick={onClick}>
        Guardar
      </Button>
    )

    const boton = screen.getByRole('button', { name: 'Guardar' })
    expect(boton).toBeDisabled()
    await user.click(boton)

    expect(onClick).not.toHaveBeenCalled()
  })

  it('loading marca aria-busy y deja un svg con animate-spin', () => {
    render(<Button loading>Guardando</Button>)

    const boton = screen.getByRole('button', { name: 'Guardando' })
    expect(boton).toHaveAttribute('aria-busy', 'true')
    // `svg.animate-spin` es el contrato que ya asevera
    // ModalEditarPedido.test.jsx sobre el boton de guardar.
    expect(boton.querySelector('svg.animate-spin')).toBeInTheDocument()
  })

  it('sin loading no hay aria-busy ni spinner', () => {
    render(<Button>Guardar</Button>)

    const boton = screen.getByRole('button', { name: 'Guardar' })
    expect(boton).not.toHaveAttribute('aria-busy')
    expect(boton.querySelector('svg.animate-spin')).toBeNull()
  })

  it('loading NO bloquea el click (para eso esta disabled)', async () => {
    const user = userEvent.setup()
    const onClick = vi.fn()
    render(
      <Button loading onClick={onClick}>
        Guardando
      </Button>
    )

    await user.click(screen.getByRole('button', { name: 'Guardando' }))

    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it.each(VARIANTES)('la variante %s renderiza y solo primary lleva el gancho btn-primary', variante => {
    render(<Button variant={variante}>Accion</Button>)

    const boton = screen.getByRole('button', { name: 'Accion' })
    expect(boton.className.length).toBeGreaterThan(0)
    // `btn-primary` no pinta nada por si sola: es el gancho que
    // high-contrast.css matchea con [class*="btn-primary"]. Si aparece en otra
    // variante, el alto contraste le pisa el color a un boton que no es el
    // primario.
    expect(boton.className.split(/\s+/).includes('btn-primary')).toBe(variante === 'primary')
  })

  it.each(TAMANOS)('el tamaño %s renderiza', tamano => {
    render(<Button size={tamano}>Accion</Button>)

    expect(screen.getByRole('button', { name: 'Accion' })).toBeInTheDocument()
  })

  it('por defecto es primary y md', () => {
    render(<Button>Accion</Button>)

    const clases = screen.getByRole('button', { name: 'Accion' }).className.split(/\s+/)
    expect(clases).toContain('bg-brand-600')
    expect(clases).toContain('btn-primary')
    expect(clases).toContain('h-10')
  })

  it('el className del consumidor se mergea sin comerse el degrade de hero', () => {
    render(
      <Button variant="hero" className="bg-white">
        Nuevo pedido
      </Button>
    )

    const clases = screen.getByRole('button', { name: 'Nuevo pedido' }).className.split(/\s+/)
    // El bug que esto cuida: con tailwind-merge 3.x (hecha para Tailwind 4),
    // `bg-gradient-to-br` caia en el grupo de color de fondo y cualquier `bg-*`
    // del consumidor lo borraba en silencio. Ver src/lib/utils.ts.
    expect(clases).toContain('bg-gradient-to-br')
    expect(clases).toContain('bg-white')
  })

  it('el className del consumidor gana en un conflicto real', () => {
    render(<Button className="h-14">Accion</Button>)

    const clases = screen.getByRole('button', { name: 'Accion' }).className.split(/\s+/)
    expect(clases).toContain('h-14')
    expect(clases).not.toContain('h-10')
  })

  it('el ref llega al <button>', () => {
    const ref = createRef<HTMLButtonElement>()
    render(<Button ref={ref}>Accion</Button>)

    expect(ref.current).toBe(screen.getByRole('button', { name: 'Accion' }))
    expect(ref.current?.tagName).toBe('BUTTON')
  })
})

describe('buttonClasses', () => {
  it('devuelve un string usable en un <a> con pinta de boton', () => {
    const clases = buttonClasses({ variant: 'secondary', size: 'sm', className: 'w-full' })

    expect(typeof clases).toBe('string')
    expect(clases.split(/\s+/)).toContain('w-full')
    expect(clases.split(/\s+/)).toContain('h-8')
  })

  it('sin argumentos cae en los defaults (primary / md)', () => {
    const clases = buttonClasses().split(/\s+/)

    expect(clases).toContain('bg-brand-600')
    expect(clases).toContain('h-10')
  })
})
