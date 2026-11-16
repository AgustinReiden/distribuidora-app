/**
 * #1602: el gate no pide el permiso sin un toque, y las instrucciones de
 * desbloqueo dependen del equipo y de la causa.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import GeolocationGate from './GeolocationGate'

const PERMISSION_DENIED = 1
const POSITION_UNAVAILABLE = 2
const TIMEOUT = 3
const errorGeo = (code: number) =>
  ({ code, PERMISSION_DENIED, POSITION_UNAVAILABLE, TIMEOUT, message: 'x' }) as GeolocationPositionError
const posicion = {
  coords: { latitude: -26.8, longitude: -65.2, accuracy: 10, altitude: null, altitudeAccuracy: null, heading: null, speed: null },
  timestamp: 0,
} as GeolocationPosition

type AlExito = (pos: GeolocationPosition) => void
type AlError = (err: GeolocationPositionError) => void

const UA_ANDROID =
  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36'

const original = {
  geolocation: Object.getOwnPropertyDescriptor(navigator, 'geolocation'),
  permissions: Object.getOwnPropertyDescriptor(navigator, 'permissions'),
  userAgent: Object.getOwnPropertyDescriptor(navigator, 'userAgent'),
  matchMedia: window.matchMedia,
}

let getCurrentPosition: ReturnType<typeof vi.fn>
/** Lo que contesta la Permissions API; se puede cambiar en medio del test. */
const permiso = { estado: 'prompt' as 'granted' | 'prompt' | 'denied' | 'sin-api' }

function definir(nombre: 'geolocation' | 'permissions' | 'userAgent', value: unknown) {
  Object.defineProperty(navigator, nombre, { value, configurable: true, writable: true })
}

function instalada(si: boolean) {
  window.matchMedia = vi.fn((q: string) => ({
    matches: si && q === '(display-mode: standalone)',
    media: q, onchange: null,
    addListener: vi.fn(), removeListener: vi.fn(), addEventListener: vi.fn(), removeEventListener: vi.fn(), dispatchEvent: vi.fn(),
  })) as unknown as typeof window.matchMedia
}

beforeEach(() => {
  localStorage.clear()
  permiso.estado = 'prompt'
  getCurrentPosition = vi.fn()
  definir('geolocation', { getCurrentPosition })
  definir('permissions', {
    query: vi.fn(async () => {
      if (permiso.estado === 'sin-api') throw new Error('no')
      return { state: permiso.estado, addEventListener: vi.fn(), removeEventListener: vi.fn() }
    }),
  })
  definir('userAgent', UA_ANDROID)
  instalada(false)
})

afterEach(() => {
  for (const k of ['geolocation', 'permissions', 'userAgent'] as const) {
    const d = original[k]
    if (d) Object.defineProperty(navigator, k, d)
    else delete (navigator as unknown as Record<string, unknown>)[k]
  }
  window.matchMedia = original.matchMedia
})

const montar = () =>
  render(
    <GeolocationGate enabled onCancel={() => {}}>
      <p>formulario del pedido</p>
    </GeolocationGate>,
  )

describe('GeolocationGate: el permiso se pide con un toque (#1602)', () => {
  it('sin permiso dado ni marca local, al abrir NO llama a getCurrentPosition: espera el botón', async () => {
    const user = userEvent.setup()
    montar()
    expect(await screen.findByText('Activá la ubicación para continuar')).toBeInTheDocument()
    // Que la consulta del permiso haya terminado antes de afirmar.
    await waitFor(() => expect(navigator.permissions.query).toHaveBeenCalled())
    await new Promise(r => setTimeout(r, 0))
    expect(getCurrentPosition).not.toHaveBeenCalled()

    getCurrentPosition.mockImplementation((ok: AlExito) => ok(posicion))
    await user.click(screen.getByRole('button', { name: /Activar GPS/ }))
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
    expect(await screen.findByText('formulario del pedido')).toBeInTheDocument()
    // La captura exitosa deja la marca para la próxima.
    expect(localStorage.getItem('gps.captura_ok')).toBe('1')
  })

  it('con la API en granted, sondea solo al abrir y pasa sin tocar nada (como antes)', async () => {
    permiso.estado = 'granted'
    getCurrentPosition.mockImplementation((ok: AlExito) => ok(posicion))
    montar()
    expect(await screen.findByText('formulario del pedido')).toBeInTheDocument()
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
    expect(getCurrentPosition.mock.calls[0][2]).toMatchObject({ enableHighAccuracy: false })
  })

  it('con la API en prompt pero una captura exitosa anterior (Chrome Android), también sondea solo', async () => {
    localStorage.setItem('gps.captura_ok', '1')
    getCurrentPosition.mockImplementation((ok: AlExito) => ok(posicion))
    montar()
    expect(await screen.findByText('formulario del pedido')).toBeInTheDocument()
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
  })

  it('con la API en denied va directo a la pantalla de bloqueo, sin sondear', async () => {
    permiso.estado = 'denied'
    montar()
    expect(await screen.findByText('Ubicación bloqueada')).toBeInTheDocument()
    expect(getCurrentPosition).not.toHaveBeenCalled()
  })

  it('sin Permissions API y sin marca, tampoco sondea', async () => {
    permiso.estado = 'sin-api'
    montar()
    expect(await screen.findByText('Activá la ubicación para continuar')).toBeInTheDocument()
    await new Promise(r => setTimeout(r, 0))
    expect(getCurrentPosition).not.toHaveBeenCalled()
  })

  it('un sondeo que da PERMISSION_DENIED borra la marca y bloquea', async () => {
    localStorage.setItem('gps.captura_ok', '1')
    getCurrentPosition.mockImplementation((_ok: AlExito, err: AlError) => {
      permiso.estado = 'denied'
      err(errorGeo(PERMISSION_DENIED))
    })
    montar()
    expect(await screen.findByText('Ubicación bloqueada')).toBeInTheDocument()
    expect(localStorage.getItem('gps.captura_ok')).toBeNull()
  })
})

describe('GeolocationGate: instrucciones según el equipo y la causa (#1602)', () => {
  it('la app instalada en Android no manda a los tres puntos: manda a abrir Chrome', async () => {
    permiso.estado = 'denied'
    instalada(true)
    montar()
    expect(await screen.findByText('Ubicación bloqueada')).toBeInTheDocument()
    expect(screen.getByText(/Abrí Chrome \(el navegador, no la app\)/)).toBeInTheDocument()
    expect(screen.queryByText(/tres puntos/)).toBeNull()
  })

  it('en una pestaña de Chrome Android sí nombra el menú del navegador', async () => {
    permiso.estado = 'denied'
    montar()
    expect(await screen.findByText(/tres puntos/)).toBeInTheDocument()
  })

  it('el sitio tiene permiso y aun así PERMISSION_DENIED: es la ubicación del teléfono o el navegador', async () => {
    const user = userEvent.setup()
    permiso.estado = 'prompt'
    montar()
    getCurrentPosition.mockImplementation((_ok: AlExito, err: AlError) => {
      // Después del intento la API sigue diciendo granted: no es el sitio.
      permiso.estado = 'granted'
      err(errorGeo(PERMISSION_DENIED))
    })
    await user.click(await screen.findByRole('button', { name: /Activar GPS/ }))
    expect(await screen.findByText('La ubicación del teléfono no responde')).toBeInTheDocument()
    expect(screen.getByText(/«Ubicación» esté prendida/)).toBeInTheDocument()
    expect(screen.queryByText(/Configuración de sitios/)).toBeNull()
  })

  it('el preventista rechaza el aviso del navegador: es el sitio', async () => {
    const user = userEvent.setup()
    montar()
    getCurrentPosition.mockImplementation((_ok: AlExito, err: AlError) => {
      permiso.estado = 'denied'
      err(errorGeo(PERMISSION_DENIED))
    })
    await user.click(await screen.findByRole('button', { name: /Activar GPS/ }))
    expect(await screen.findByText('Ubicación bloqueada')).toBeInTheDocument()
  })

  it('«Continuar sin GPS» avisa que al confirmar se pide el motivo, y deja pasar', async () => {
    const user = userEvent.setup()
    permiso.estado = 'denied'
    montar()
    expect(await screen.findByText('Al confirmar te vamos a pedir el motivo.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Continuar sin GPS' }))
    expect(screen.getByText('formulario del pedido')).toBeInTheDocument()
  })

  it('un timeout al tocar el botón deja pasar (el motivo se pide al confirmar)', async () => {
    const user = userEvent.setup()
    montar()
    getCurrentPosition.mockImplementation((_ok: AlExito, err: AlError) => err(errorGeo(TIMEOUT)))
    await user.click(await screen.findByRole('button', { name: /Activar GPS/ }))
    expect(await screen.findByText('formulario del pedido')).toBeInTheDocument()
  })
})
