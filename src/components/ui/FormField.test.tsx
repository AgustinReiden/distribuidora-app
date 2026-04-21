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
