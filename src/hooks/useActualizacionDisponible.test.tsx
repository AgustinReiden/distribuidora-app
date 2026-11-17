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
    sessionStorage.clear()
    // Por defecto la app lleva rato abierta: fuera de la ventana de arranque,
    // donde el salto automatico no corre y manda el cartel.
    vi.spyOn(performance, 'now').mockReturnValue(5 * 60 * 1000)
    aplicarActualizacionSWMock.mockResolvedValue(undefined)
    // En DEV el hook queda inerte a proposito; los tests simulan produccion.
    vi.stubEnv('DEV', false)
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    document.body.innerHTML = ''
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

  // Cambió de regla con D57 (1563-b8): ya no hay «Mas tarde». La X esconde el
  // cartel y nada más: el próximo aviso lo vuelve a mostrar.
  it('ocultar esconde el cartel, y el próximo aviso lo vuelve a mostrar', async () => {
    responderVersion({ buildId: 'otro-build-mas-nuevo' })

    const { result } = renderHook(() => useActualizacionDisponible())
    await waitFor(() => expect(result.current.disponible).toBe(true))

    act(() => { result.current.ocultar() })
    expect(result.current.disponible).toBe(false)
    act(() => { avisarActualizacionSW?.() })

    expect(result.current.disponible).toBe(true)
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

  describe('D57 (1563-b8): se actualiza sola al volver a la app o al cambiar de pantalla', () => {
    /** La pestaña se esconde (otra app, pantalla apagada) y vuelve a verse. */
    function irseYVolver(visibilidad: { valor: string }): void {
      act(() => {
        visibilidad.valor = 'hidden'
        document.dispatchEvent(new Event('visibilitychange'))
      })
      act(() => {
        visibilidad.valor = 'visible'
        document.dispatchEvent(new Event('visibilitychange'))
      })
    }

    function visibilidadControlada(): { valor: string } {
      const visibilidad = { valor: 'visible' }
      Object.defineProperty(document, 'visibilityState', {
        configurable: true,
        get: () => visibilidad.valor,
      })
      return visibilidad
    }

    it('con el cartel puesto, volver a la app la actualiza aunque haya estado afuera un minuto', async () => {
      const visibilidad = visibilidadControlada()
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())
      await waitFor(() => expect(result.current.disponible).toBe(true))
      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()

      irseYVolver(visibilidad)

      expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1)
    })

    it('si el build nuevo se descubre al volver a la app, se actualiza en ese momento', async () => {
      const visibilidad = visibilidadControlada()
      responderVersion({ buildId: BUILD_DE_ESTA_PESTANIA })

      const { result } = renderHook(() => useActualizacionDisponible())
      await waitFor(() => expect(fetch).toHaveBeenCalled())
      await flush()
      expect(result.current.disponible).toBe(false)

      responderVersion({ buildId: 'otro-build-mas-nuevo' })
      irseYVolver(visibilidad)

      await waitFor(() => expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1))
    })

    it('un focus sin haberse ido (otra ventana encima) no la actualiza', async () => {
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())
      await waitFor(() => expect(result.current.disponible).toBe(true))

      act(() => { window.dispatchEvent(new Event('focus')) })
      await flush()

      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()
    })

    it('cambiar de pantalla con un build nuevo esperando la actualiza', async () => {
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result, rerender } = renderHook(({ ruta }) => useActualizacionDisponible(ruta), {
        initialProps: { ruta: '/pedidos' },
      })
      await waitFor(() => expect(result.current.disponible).toBe(true))
      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()

      rerender({ ruta: '/clientes' })

      expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1)
    })

    it('cambiar de pantalla sin build nuevo no hace nada', async () => {
      responderVersion({ buildId: BUILD_DE_ESTA_PESTANIA })

      const { rerender } = renderHook(({ ruta }) => useActualizacionDisponible(ruta), {
        initialProps: { ruta: '/pedidos' },
      })
      await waitFor(() => expect(fetch).toHaveBeenCalled())
      await flush()

      rerender({ ruta: '/clientes' })

      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()
    })

    it('con un modal abierto no se actualiza al cambiar de pantalla: espera a la próxima', async () => {
      responderVersion({ buildId: 'otro-build-mas-nuevo' })
      document.body.innerHTML = '<div role="dialog">Nuevo pedido</div>'

      const { result, rerender } = renderHook(({ ruta }) => useActualizacionDisponible(ruta), {
        initialProps: { ruta: '/pedidos' },
      })
      await waitFor(() => expect(result.current.disponible).toBe(true))

      rerender({ ruta: '/clientes' })
      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()

      document.body.innerHTML = ''
      rerender({ ruta: '/productos' })
      expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1)
    })

    it('después de un salto que no prosperó espera el enfriamiento (no entra en loop)', async () => {
      const visibilidad = visibilidadControlada()
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())
      await waitFor(() => expect(result.current.disponible).toBe(true))

      irseYVolver(visibilidad)
      irseYVolver(visibilidad)

      expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1)
    })
  })

  describe('salto automatico (solo cuando no hay nada que perder)', () => {
    it('recien abierta la app, salta solo y no muestra el cartel', async () => {
      vi.spyOn(performance, 'now').mockReturnValue(2000)
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())

      await waitFor(() => expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1))
      expect(result.current.disponible).toBe(false)
    })

    it('con un modal abierto no salta: queda el cartel', async () => {
      vi.spyOn(performance, 'now').mockReturnValue(2000)
      document.body.innerHTML = '<div role="dialog">Nuevo pedido</div>'
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())

      await waitFor(() => expect(result.current.disponible).toBe(true))
      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()
    })

    it('con un campo en edicion no salta', async () => {
      vi.spyOn(performance, 'now').mockReturnValue(2000)
      document.body.innerHTML = '<input id="x" />'
      document.getElementById('x')?.focus()
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())

      await waitFor(() => expect(result.current.disponible).toBe(true))
      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()
    })

    it('con la app en uso (fuera del arranque) no salta aunque no haya nada abierto', async () => {
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())

      await waitFor(() => expect(result.current.disponible).toBe(true))
      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()
    })

    it('no entra en loop: tras un salto automatico espera el enfriamiento', async () => {
      vi.spyOn(performance, 'now').mockReturnValue(2000)
      sessionStorage.setItem('actualizacion:ultimo-auto', String(Date.now()))
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      const { result } = renderHook(() => useActualizacionDisponible())

      await waitFor(() => expect(result.current.disponible).toBe(true))
      expect(aplicarActualizacionSWMock).not.toHaveBeenCalled()
    })

    // Cambió de regla con D57: un «Mas tarde» que quedó guardado de antes ya no
    // frena nada.
    it('un «Mas tarde» guardado por la versión anterior ya no frena el salto', async () => {
      vi.spyOn(performance, 'now').mockReturnValue(2000)
      sessionStorage.setItem('actualizacion:pospuesto-hasta', String(Date.now() + 60_000))
      responderVersion({ buildId: 'otro-build-mas-nuevo' })

      renderHook(() => useActualizacionDisponible())

      await waitFor(() => expect(aplicarActualizacionSWMock).toHaveBeenCalledTimes(1))
    })
  })

  it('actualizar deja el boton en "actualizando" para que no se repita el toque', async () => {
    responderVersion({ buildId: 'otro-build-mas-nuevo' })
    aplicarActualizacionSWMock.mockResolvedValue(undefined)

    const { result } = renderHook(() => useActualizacionDisponible())
    await waitFor(() => expect(result.current.disponible).toBe(true))

    act(() => { result.current.actualizar() })

    expect(result.current.actualizando).toBe(true)
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
