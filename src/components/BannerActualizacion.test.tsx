/**
 * Test de caracterización de BannerActualizacion: fija el comportamiento
 * ACTUAL antes de moverlo a una pila común de avisos por portal.
 *
 * Mockea useActualizacionDisponible (no ejercita el chequeo real de
 * /version.json ni el service worker; eso lo cubre otra suite).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const actualizar = vi.fn()
const posponer = vi.fn()

vi.mock('../hooks/useActualizacionDisponible', () => ({
  useActualizacionDisponible: vi.fn(),
}))

import { useActualizacionDisponible } from '../hooks/useActualizacionDisponible'
import BannerActualizacion from './BannerActualizacion'

function mockHook(disponible: boolean): void {
  vi.mocked(useActualizacionDisponible).mockReturnValue({
    disponible,
    buildActual: 'test-build',
    actualizar,
    posponer,
  })
}

describe('BannerActualizacion', () => {
  beforeEach(() => {
    actualizar.mockClear()
    posponer.mockClear()
  })

  it('no renderiza nada cuando no hay actualizacion disponible', () => {
    mockHook(false)
    const { container } = render(<BannerActualizacion />)
    expect(container.firstChild).toBeNull()
  })

  it('muestra el aviso con role status y su texto cuando hay actualizacion disponible', () => {
    mockHook(true)
    render(<BannerActualizacion />)
    const aviso = screen.getByRole('status')
    expect(aviso).toHaveTextContent('Hay una version nueva')
    expect(aviso).toHaveTextContent(/Actualiza para no seguir trabajando con pantallas viejas/)
  })

  it('el boton Actualizar llama a actualizar()', async () => {
    mockHook(true)
    render(<BannerActualizacion />)

    await userEvent.click(screen.getByRole('button', { name: 'Actualizar' }))

    expect(actualizar).toHaveBeenCalledTimes(1)
    expect(posponer).not.toHaveBeenCalled()
  })

  it('el boton Mas tarde llama a posponer()', async () => {
    mockHook(true)
    render(<BannerActualizacion />)

    await userEvent.click(screen.getByRole('button', { name: 'Mas tarde' }))

    expect(posponer).toHaveBeenCalledTimes(1)
    expect(actualizar).not.toHaveBeenCalled()
  })

  it('el boton de cerrar (X) tambien llama a posponer()', async () => {
    mockHook(true)
    render(<BannerActualizacion />)

    await userEvent.click(screen.getByRole('button', { name: 'Cerrar aviso de actualizacion' }))

    expect(posponer).toHaveBeenCalledTimes(1)
  })
})
