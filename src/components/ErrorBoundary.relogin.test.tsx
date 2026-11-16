/**
 * 1600-b7 (#1600): «Iniciar sesión» del ErrorBoundary pasa por la limpieza de datos locales.
 *
 * Sólo borraba las claves de auth: las rutas del chofer, los cobros sin confirmar y el caché
 * de lo que se vio en pantalla quedaban en el teléfono para el siguiente que entrara.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const { limpiarDatosSensiblesLocales } = vi.hoisted(() => ({ limpiarDatosSensiblesLocales: vi.fn() }))
vi.mock('../lib/limpiezaLocal', () => ({ limpiarDatosSensiblesLocales }))
vi.mock('../lib/sentry', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn() }))
vi.mock('../utils/errorUtils', () => ({
  categorizeError: vi.fn(() => 'auth'),
  getRecoveryInfo: vi.fn(() => ({
    title: 'Sesión expirada',
    message: 'Tenés que iniciar sesión nuevamente',
    iconName: 'Lock',
    canRetry: false,
    action: 'relogin',
  })),
}))

import { ErrorBoundary } from './ErrorBoundary'
import { fijarUsuarioNotificaciones } from '../utils/notificacionesGuardadas'

const Rompe = () => {
  throw new Error('sesión vencida')
}

describe('ErrorBoundary: relogin', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(console, 'error').mockImplementation(() => {})
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...window.location, assign: vi.fn(), reload: vi.fn() },
    })
  })

  it('limpia los datos locales del usuario antes de volver al login', () => {
    fijarUsuarioNotificaciones('user-A')
    render(<ErrorBoundary><Rompe /></ErrorBoundary>)

    fireEvent.click(screen.getByRole('button', { name: /iniciar sesión/i }))

    // Las claves de reintento (alta en duda, cobros sin confirmar) se conservan (L1, #1603).
    expect(limpiarDatosSensiblesLocales).toHaveBeenCalledWith('user-A', { conservarClavesDeReintento: true })
    expect(window.location.assign).toHaveBeenCalledWith('/')
    fijarUsuarioNotificaciones(null)
  })

  it('si la limpieza falla, igual vuelve al login', () => {
    limpiarDatosSensiblesLocales.mockImplementationOnce(() => { throw new Error('storage roto') })
    render(<ErrorBoundary><Rompe /></ErrorBoundary>)

    fireEvent.click(screen.getByRole('button', { name: /iniciar sesión/i }))

    expect(window.location.assign).toHaveBeenCalledWith('/')
  })
})
