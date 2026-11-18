/**
 * Test de caracterización de BannerActualizacion.
 *
 * Mockea useActualizacionDisponible (no ejercita el chequeo real de
 * /version.json ni el service worker; eso lo cubre otra suite).
 *
 * Cambió de regla con D57 (1563-b8 de #1563): la actualización es obligatoria.
 * El cartel avisa que se actualiza sola y ya no tiene «Mas tarde»; la X sólo lo
 * esconde (`ocultar`), no pospone nada.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const actualizar = vi.fn()
const ocultar = vi.fn()

vi.mock('../hooks/useActualizacionDisponible', () => ({
  useActualizacionDisponible: vi.fn(),
}))

import { useActualizacionDisponible } from '../hooks/useActualizacionDisponible'
import BannerActualizacion from './BannerActualizacion'

function mockHook(disponible: boolean, actualizando = false): void {
  vi.mocked(useActualizacionDisponible).mockReturnValue({
    disponible,
    actualizando,
    buildActual: 'test-build',
    actualizar,
    ocultar,
  })
}

describe('BannerActualizacion', () => {
  beforeEach(() => {
    actualizar.mockClear()
    ocultar.mockClear()
    vi.mocked(useActualizacionDisponible).mockClear()
  })

  it('no renderiza nada cuando no hay actualizacion disponible', () => {
    mockHook(false)
    const { container } = render(<BannerActualizacion />)
    expect(container.firstChild).toBeNull()
    // El aviso se dibuja por portal en la pila (#716), no en el container: hay
    // que mirar afuera para que esto diga algo.
    expect(document.getElementById('notice-root')?.childElementCount ?? 0).toBe(0)
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('avisa que se actualiza sola al cambiar de pantalla o volver a la app (D57)', () => {
    mockHook(true)
    render(<BannerActualizacion />)
    const aviso = screen.getByRole('status')
    expect(aviso).toHaveTextContent('Hay una versión nueva')
    expect(aviso).toHaveTextContent(/se va a actualizar sola cuando cambies de pantalla o vuelvas a ella/)
  })

  it('ya no ofrece «Mas tarde» (D57)', () => {
    mockHook(true)
    render(<BannerActualizacion />)
    expect(screen.queryByRole('button', { name: /m[aá]s tarde/i })).toBeNull()
  })

  it('le pasa la ruta al hook, para actualizar al cambiar de pantalla', () => {
    mockHook(false)
    render(<BannerActualizacion ruta="/clientes" />)
    expect(useActualizacionDisponible).toHaveBeenCalledWith('/clientes')
  })

  it('el boton Actualizar llama a actualizar()', async () => {
    mockHook(true)
    render(<BannerActualizacion />)

    await userEvent.click(screen.getByRole('button', { name: 'Actualizar' }))

    expect(actualizar).toHaveBeenCalledTimes(1)
    expect(ocultar).not.toHaveBeenCalled()
  })

  it('el boton de cerrar (X) sólo esconde el cartel', async () => {
    mockHook(true)
    render(<BannerActualizacion />)

    await userEvent.click(screen.getByRole('button', { name: 'Cerrar aviso de actualización' }))

    expect(ocultar).toHaveBeenCalledTimes(1)
    expect(actualizar).not.toHaveBeenCalled()
  })

  it('mientras actualiza, el boton queda deshabilitado y lo dice', () => {
    mockHook(true, true)
    render(<BannerActualizacion />)

    expect(screen.getByRole('button', { name: 'Actualizando...' })).toBeDisabled()
  })
})
