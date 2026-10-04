import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { FormField } from './FormField'

describe('FormField', () => {
  it('propaga inputMode al input hijo', () => {
    render(
      <FormField label="Precio" inputMode="decimal">
        <input type="number" />
      </FormField>
    )
    expect(screen.getByLabelText('Precio')).toHaveAttribute('inputmode', 'decimal')
  })

  it('no agrega inputMode si no se pasa la prop', () => {
    render(
      <FormField label="Nombre">
        <input type="text" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).not.toHaveAttribute('inputmode')
  })
})

describe('FormField — id, label y aria-* que inyecta', () => {
  it('genera un id y lo pone en el htmlFor del label y en el hijo', () => {
    const { container } = render(
      <FormField label="Nombre">
        <input type="text" />
      </FormField>
    )
    const input = screen.getByLabelText('Nombre')
    const label = container.querySelector('label')!
    expect(input.id).toMatch(/^field-.+/)
    expect(label).toHaveAttribute('for', input.id)
  })

  it('dos campos distintos no comparten id', () => {
    render(
      <>
        <FormField label="Uno"><input /></FormField>
        <FormField label="Dos"><input /></FormField>
      </>
    )
    expect(screen.getByLabelText('Uno').id).not.toBe(screen.getByLabelText('Dos').id)
  })

  it('sin hint, error ni required el hijo no recibe ningún aria-*', () => {
    render(
      <FormField label="Nombre">
        <input type="text" />
      </FormField>
    )
    const input = screen.getByLabelText('Nombre')
    expect(input).not.toHaveAttribute('aria-describedby')
    expect(input).not.toHaveAttribute('aria-invalid')
    expect(input).not.toHaveAttribute('aria-required')
  })

  it('el hint se pinta con su id y el hijo lo referencia en aria-describedby', () => {
    render(
      <FormField label="Precio" hint="Sin IVA">
        <input type="number" />
      </FormField>
    )
    const hint = screen.getByText('Sin IVA')
    expect(hint.id).toMatch(/^hint-.+/)
    expect(screen.getByLabelText('Precio')).toHaveAttribute('aria-describedby', hint.id)
  })

  it('el error se pinta como alert con su id y el hijo lo referencia en aria-describedby', () => {
    render(
      <FormField label="Nombre" error="Es obligatorio">
        <input type="text" />
      </FormField>
    )
    const alerta = screen.getByRole('alert')
    expect(alerta).toHaveTextContent('Es obligatorio')
    expect(alerta.id).toMatch(/^error-.+/)
    expect(screen.getByLabelText('Nombre')).toHaveAttribute('aria-describedby', alerta.id)
  })

  it('con error y hint a la vez se pinta el error y el hint se oculta', () => {
    render(
      <FormField label="Nombre" error="Es obligatorio" hint="Máx. 40 caracteres">
        <input type="text" />
      </FormField>
    )
    expect(screen.getByRole('alert')).toHaveTextContent('Es obligatorio')
    expect(screen.queryByText('Máx. 40 caracteres')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Nombre').getAttribute('aria-describedby')).toContain(
      screen.getByRole('alert').id
    )
  })

  it('aria-invalid="true" sólo cuando hay error', () => {
    const { rerender } = render(
      <FormField label="Nombre">
        <input type="text" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).not.toHaveAttribute('aria-invalid')

    rerender(
      <FormField label="Nombre" error="Falta">
        <input type="text" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).toHaveAttribute('aria-invalid', 'true')
  })

  it('aria-required="true" y asterisco oculto al lector sólo con required', () => {
    const { container, rerender } = render(
      <FormField label="Nombre">
        <input type="text" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).not.toHaveAttribute('aria-required')
    expect(container.querySelector('label span')).toBeNull()

    rerender(
      <FormField label="Nombre" required>
        <input type="text" />
      </FormField>
    )
    expect(screen.getByLabelText(/Nombre/)).toHaveAttribute('aria-required', 'true')
    const asterisco = container.querySelector('label span')!
    expect(asterisco).toHaveTextContent('*')
    expect(asterisco).toHaveAttribute('aria-hidden', 'true')
  })
})

describe('FormField — className', () => {
  it('conserva la className del hijo y no agrega estilos de error sin error', () => {
    render(
      <FormField label="Nombre">
        <input type="text" className="mi-clase otra-clase" />
      </FormField>
    )
    const input = screen.getByLabelText('Nombre')
    expect(input).toHaveClass('mi-clase', 'otra-clase')
    expect(input).not.toHaveClass('border-red-500')
  })

  it('con error suma los estilos de error a la className del hijo', () => {
    render(
      <FormField label="Nombre" error="Falta">
        <input type="text" className="mi-clase" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).toHaveClass(
      'mi-clase',
      'border-red-500',
      'bg-red-50',
      'focus:ring-red-500'
    )
  })

  it('la className del FormField va al contenedor, junto a form-field', () => {
    const { container } = render(
      <FormField label="Nombre" className="flex-1">
        <input type="text" />
      </FormField>
    )
    expect(container.firstElementChild).toHaveClass('form-field', 'flex-1')
  })
})

describe('FormField — lo que ya traía el hijo', () => {
  // #777: antes cloneElement inyectaba SIEMPRE id y aria-* y la prop nueva
  // ganaba, así que FormField pisaba lo que el hijo declaró (en el historial,
  // estos casos llevaban `// BUG #777` y fijaban ese pisado). Ahora no pisa:
  // el id del hijo manda, aria-describedby se suma y aria-invalid/aria-required
  // explícitos del hijo ganan.

  it('respeta el id que el hijo ya traía y el label lo usa en htmlFor', () => {
    const { container } = render(
      <FormField label="Nombre">
        <input id="mi-campo" type="text" />
      </FormField>
    )
    const input = screen.getByLabelText('Nombre')
    expect(input).toHaveAttribute('id', 'mi-campo')
    expect(container.querySelector('label')).toHaveAttribute('for', 'mi-campo')
  })

  it('suma el hint al aria-describedby que el hijo ya traía, el del hijo primero', () => {
    render(
      <FormField label="Porcentaje" hint="Sin IVA">
        <input type="text" aria-describedby="ayuda-propia" />
      </FormField>
    )
    const input = screen.getByLabelText('Porcentaje')
    expect(input.getAttribute('aria-describedby')).toBe(`ayuda-propia ${screen.getByText('Sin IVA').id}`)
  })

  it('suma el error al aria-describedby que el hijo ya traía, el del hijo primero', () => {
    render(
      <FormField label="Porcentaje" error="Falta">
        <input type="text" aria-describedby="ayuda-propia" />
      </FormField>
    )
    const input = screen.getByLabelText('Porcentaje')
    expect(input.getAttribute('aria-describedby')).toBe(`ayuda-propia ${screen.getByRole('alert').id}`)
  })

  it('con aria-describedby propio, error y hint conserva la referencia propia y suma la del error', () => {
    render(
      <FormField label="Porcentaje" error="Falta" hint="Sin IVA">
        <input type="text" aria-describedby="ayuda-propia" />
      </FormField>
    )
    const tokens = screen.getByLabelText('Porcentaje').getAttribute('aria-describedby')!.split(' ')
    expect(tokens[0]).toBe('ayuda-propia')
    expect(tokens).toContain(screen.getByRole('alert').id)
  })

  it('conserva el aria-describedby del hijo cuando no hay hint ni error', () => {
    render(
      <FormField label="Porcentaje">
        <input type="text" aria-describedby="ayuda-propia" />
      </FormField>
    )
    expect(screen.getByLabelText('Porcentaje')).toHaveAttribute('aria-describedby', 'ayuda-propia')
  })

  it('no repite referencias y normaliza los espacios del aria-describedby del hijo', () => {
    render(
      <FormField label="Porcentaje" hint="Sin IVA">
        <input type="text" aria-describedby="  uno   dos uno  " />
      </FormField>
    )
    expect(screen.getByLabelText('Porcentaje').getAttribute('aria-describedby')).toBe(
      `uno dos ${screen.getByText('Sin IVA').id}`
    )
  })

  it('respeta el aria-invalid explícito del hijo, también "false" con error; sin él decide FormField', () => {
    const { rerender } = render(
      <FormField label="Nombre">
        <input type="text" aria-invalid="true" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).toHaveAttribute('aria-invalid', 'true')

    rerender(
      <FormField label="Nombre" error="Falta">
        <input type="text" aria-invalid={false} />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).toHaveAttribute('aria-invalid', 'false')

    rerender(
      <FormField label="Nombre" error="Falta">
        <input type="text" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).toHaveAttribute('aria-invalid', 'true')
  })

  it('respeta el aria-required explícito del hijo, también "false" con required; sin él decide FormField', () => {
    const { rerender } = render(
      <FormField label="Nombre">
        <input type="text" aria-required="true" />
      </FormField>
    )
    expect(screen.getByLabelText('Nombre')).toHaveAttribute('aria-required', 'true')

    rerender(
      <FormField label="Nombre" required>
        <input type="text" aria-required={false} />
      </FormField>
    )
    expect(screen.getByLabelText(/Nombre/)).toHaveAttribute('aria-required', 'false')

    rerender(
      <FormField label="Nombre" required>
        <input type="text" />
      </FormField>
    )
    expect(screen.getByLabelText(/Nombre/)).toHaveAttribute('aria-required', 'true')
  })

  it('un id propio vacío cuenta como ausente y se genera uno', () => {
    const { container } = render(
      <FormField label="Nombre">
        <input id="" type="text" />
      </FormField>
    )
    const input = screen.getByLabelText('Nombre')
    expect(input.id).toMatch(/^field-.+/)
    expect(container.querySelector('label')).toHaveAttribute('for', input.id)
  })
})
