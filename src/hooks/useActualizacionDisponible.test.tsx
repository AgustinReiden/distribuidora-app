/**
 * El bug que motiva este hook: una pestania abierta corre el bundle del dia
 * que se abrio. Lo que se prueba aca es que avise cuando el deploy cambio, y
 * sobre todo que NO avise cuando no puede saberlo (sin red, respuesta rara,
 * deploy a medio subir): un cartel que aparece de gusto es peor que no
 * tenerlo, porque se aprende a ignorarlo.
 */
import { renderHook, act, waitFor } from '@testing-library/react'
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

const aplicarActualizacionSWMock = vi.fn()
let avisarActualizacionSW: (() => void) | null = null

vi.mock('../utils/serviceWorker', () => ({
  aplicarActualizacionSW: () => aplicarActualizacionSWMock(),
  hayActualizacionSWEsperando: () => false,
  suscribirActualizacionSW: (escucha: () => void) => {
    avisarActualizacionSW = escucha
    return () => { avisarActualizacionSW = null }
  },
}))

import { useActualizacionDisponible } from './useActualizacionDisponible'

// El build id que vite inyecta en el bundle bajo test (define en vite.config.js).
const BUILD_DE_ESTA_PESTANIA = __APP_BUILD_ID__

/** Deja correr la cadena de promesas del fetch antes de afirmar un negativo. */
const flush = (): Promise<void> => new Promise(r => setTimeout(r, 0))

function responderVersion(body: unknown, ok = true): void {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
    ok,
    json: () => Promise.resolve(body),
  }))
}

describe('useActualizacionDisponible', () => {
  beforeEach(() => {
    // En DEV el hook queda inerte a proposito; los tests simulan produccion.
    vi.stubEnv('DEV', false)
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.unstubAllEnvs()
    vi.clearAllMocks()
    avisarActualizacionSW = null
  })

  // El otro camino: el service worker termino de bajar el build nuevo y lo
  // dejo esperando. Avisa aunque el chequeo de /version.json no haya corrido.
  it('avisa cuando el service worker deja un build esperando', async () => {
    responderVersion({ buildId: BUILD_DE_ESTA_PESTANIA })

    const { result } = renderHook(() => useActualizacionDisponible())
    await waitFor(() => expect(avisarActualizacionSW).not.toBeNull())

    expect(result.current.disponible).toBe(false)
    act(() => { avisarActualizacionSW?.() })

    expect(result.current.disponible).toBe(true)
  })

  it('el aviso del service worker tambien respeta el "Mas tarde"', async () => {
    responderVersion({ buildId: 'otro-build-mas-nuevo' })

    const { result } = renderHook(() => useActualizacionDisponible())
    await waitFor(() => expect(result.current.disponible).toBe(true))

    act(() => { result.current.posponer() })
    act(() => { avisarActualizacionSW?.() })

    expect(result.current.disponible).toBe(false)
  })

  // Con el service worker controlando la pagina, un location.reload() pelado
  // vuelve a servir el index.html viejo del precache: el cartel quedaria
  // apretandose para siempre sin que cambie nada.
  it('actualizar pasa por el service worker, no por un reload pelado', async () => {
    responderVersion({ buildId: 'otro-build-mas-nuevo' })
    const reload = vi.fn()
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      reload,
    } as unknown as Location)

    const { result } = renderHook(() => useActualizacionDisponible())
    await waitFor(() => expect(result.current.disponible).toBe(true))

    act(() => { result.current.actualizar() })

    expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1)
    expect(reload).not.toHaveBeenCalled()
  })

  it('avisa cuando el build publicado no es el que corre esta pestania', async () => {
    responderVersion({ buildId: 'otro-build-mas-nuevo' })

    const { result } = renderHook(() => useActualizacionDisponible())

    await waitFor(() => expect(result.current.disponible).toBe(true))
  })

  it('no avisa si el build publicado es el mismo', async () => {
    responderVersion({ buildId: BUILD_DE_ESTA_PESTANIA })

    const { result } = renderHook(() => useActualizacionDisponible())

    await waitFor(() => expect(fetch).toHaveBeenCalled())
    await flush()
    expect(result.current.disponible).toBe(false)
  })

  it('no avisa si no hay red', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('Load failed')))

    const { result } = renderHook(() => useActualizacionDisponible())

    await waitFor(() => expect(fetch).toHaveBeenCalled())
    await flush()
    expect(result.current.disponible).toBe(false)
  })

  it('no avisa si el hosting devuelve algo que no es el version.json', async () => {
    // Caso real: un SPA fallback que responde el index.html con 200.
    responderVersion({ nada: 'que ver' })

    const { result } = renderHook(() => useActualizacionDisponible())

    await waitFor(() => expect(fetch).toHaveBeenCalled())
    await flush()
    expect(result.current.disponible).toBe(false)
  })

  it('no avisa si el archivo todavia no esta (deploy a medio subir)', async () => {
    responderVersion({}, false)

    const { result } = renderHook(() => useActualizacionDisponible())

    await waitFor(() => expect(fetch).toHaveBeenCalled())
    await flush()
    expect(result.current.disponible).toBe(false)
  })

  it('pide el archivo sin cache, para no leer una copia vieja del navegador', async () => {
    responderVersion({ buildId: BUILD_DE_ESTA_PESTANIA })

    renderHook(() => useActualizacionDisponible())

    await waitFor(() => expect(fetch).toHaveBeenCalled())
    const [url, opciones] = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(url).toMatch(/^\/version\.json\?t=\d+$/)
    expect(opciones).toEqual({ cache: 'no-store' })
  })

  it('posponer apaga el cartel y aguanta los chequeos siguientes', async () => {
    responderVersion({ buildId: 'otro-build-mas-nuevo' })

    const { result } = renderHook(() => useActualizacionDisponible())
    await waitFor(() => expect(result.current.disponible).toBe(true))

    act(() => { result.current.posponer() })
    expect(result.current.disponible).toBe(false)

    const llamadasPrevias = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls.length
    // Volver a la pestania dispara un chequeo, que debe respetar el "mas tarde".
    act(() => { window.dispatchEvent(new Event('focus')) })
    await new Promise(r => setTimeout(r, 0))

    expect((fetch as unknown as ReturnType<typeof vi.fn>).mock.calls.length).toBe(llamadasPrevias)
    expect(result.current.disponible).toBe(false)
  })

  it('en desarrollo no molesta ni pega al servidor', async () => {
    vi.stubEnv('DEV', true)
    responderVersion({ buildId: 'otro-build-mas-nuevo' })

    const { result } = renderHook(() => useActualizacionDisponible())
    await new Promise(r => setTimeout(r, 0))

    expect(fetch).not.toHaveBeenCalled()
    expect(result.current.disponible).toBe(false)
  })
})
