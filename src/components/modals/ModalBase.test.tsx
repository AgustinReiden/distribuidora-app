import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import type { ReactElement } from 'react'
import ModalBase from './ModalBase'

function Boom(): ReactElement {
  throw new Error('explosion en modal')
}

describe('ModalBase ErrorBoundary', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('muestra fallback en lugar de crashear cuando children tiran', () => {
    // Silenciamos los logs esperados de React al capturar el error en el boundary.
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    // Si no hay boundary, el error no capturado haría que render() lance
    // y el test falle con la excepción. Si lo hay, render() completa y
    // podemos inspeccionar el fallback.
    render(
      <ModalBase onClose={() => {}} title="Test">
        <Boom />
      </ModalBase>
    )

    // El fallback de CompactErrorBoundary para un error UNKNOWN muestra
    // el título "Error inesperado" proveniente de getRecoveryInfo. Este
    // texto SOLO aparece si el boundary atrapó el throw.
    expect(screen.getByText('Error inesperado')).toBeInTheDocument()

    // El mensaje genérico del fallback UNKNOWN también debe estar.
    expect(
      screen.getByText(/ha ocurrido un error inesperado/i)
    ).toBeInTheDocument()

    // El frame del modal (header con el título) sigue presente:
    // el boundary envuelve solo el body, no todo el modal — si el
    // boundary estuviera afuera, al capturar perderíamos el frame.
    expect(screen.getByText('Test')).toBeInTheDocument()

    errSpy.mockRestore()
  })
})
