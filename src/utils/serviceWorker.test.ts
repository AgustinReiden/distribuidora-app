/**
 * Lo que se prueba aca es el ciclo de actualizacion, que es donde esto se
 * rompio en marzo y donde vuelve a ser peligroso:
 *
 * - que el registro exista de verdad (el bug original era que NADIE lo hacia);
 * - que el salto al build nuevo pase por el service worker y no por un
 *   `location.reload()` pelado, porque con el SW controlando la pagina el
 *   reload devuelve el index.html viejo del precache y el cartel "Hay una
 *   version nueva" queda para siempre sin hacer nada;
 * - que si algo del SW falla, igual recargue: nunca dejar a la usuaria
 *   apretando un boton que no hace nada.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

const registerSWMock = vi.fn()

vi.mock('virtual:pwa-register', () => ({
  registerSW: (opciones: unknown) => registerSWMock(opciones)
}))

vi.mock('./logger', () => ({
  logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() }
}))

import {
  registrarServiceWorker,
  suscribirActualizacionSW,
  hayActualizacionSWEsperando,
  aplicarActualizacionSW,
  _resetServiceWorkerParaTests
} from './serviceWorker'

interface OpcionesRegistro {
  immediate?: boolean
  onNeedRefresh?: () => void
  onOfflineReady?: () => void
  onRegisteredSW?: (url: string, reg?: ServiceWorkerRegistration) => void
  onRegisterError?: (error: Error) => void
}

/** Registro falso con el control de estados que necesita el ciclo de update. */
function registroFalso(inicial: Partial<ServiceWorkerRegistration> = {}) {
  const escuchas = new Set<() => void>()
  const instalando = {
    state: 'installing' as string,
    addEventListener: (_e: string, cb: () => void) => { escuchas.add(cb) },
    removeEventListener: (_e: string, cb: () => void) => { escuchas.delete(cb) }
  }

  const reg = {
    waiting: null as unknown,
    installing: null as unknown,
    update: vi.fn().mockResolvedValue(undefined),
    ...inicial
  }

  return {
    reg: reg as unknown as ServiceWorkerRegistration,
    /** Simula que el SW nuevo termino de instalarse y quedo esperando. */
    terminarInstalacion() {
      reg.installing = null
      reg.waiting = { postMessage: vi.fn() }
      instalando.state = 'installed'
      escuchas.forEach(cb => cb())
    },
    empezarInstalacion() {
      reg.installing = instalando
    }
  }
}

describe('serviceWorker', () => {
  const originalLocation = window.location
  const teniaServiceWorker = 'serviceWorker' in navigator
  let reloadMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    _resetServiceWorkerParaTests()
    vi.stubEnv('PROD', true)
    reloadMock = vi.fn()

    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...originalLocation, reload: reloadMock }
    })

    // jsdom no implementa serviceWorker: sin esto el guard corta antes.
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: { ready: Promise.resolve() }
    })
  })

  afterEach(() => {
    Object.defineProperty(window, 'location', { configurable: true, value: originalLocation })
    if (!teniaServiceWorker) {
      delete (navigator as unknown as Record<string, unknown>).serviceWorker
    }
    vi.unstubAllEnvs()
    vi.clearAllMocks()
  })

  it('no registra nada si el navegador no soporta service workers', () => {
    delete (navigator as unknown as Record<string, unknown>).serviceWorker

    registrarServiceWorker()

    expect(registerSWMock).not.toHaveBeenCalled()
  })

  describe('registro', () => {
    it('registra el service worker en produccion', () => {
      registrarServiceWorker()

      expect(registerSWMock).toHaveBeenCalledTimes(1)
      expect(registerSWMock.mock.calls[0][0]).toMatchObject({ immediate: true })
    })

    it('no registra nada en desarrollo: no hay sw.js que servir', () => {
      vi.stubEnv('PROD', false)

      registrarServiceWorker()

      expect(registerSWMock).not.toHaveBeenCalled()
    })

    it('no registra dos veces aunque se llame de nuevo', () => {
      registerSWMock.mockReturnValue(vi.fn())

      registrarServiceWorker()
      registrarServiceWorker()

      expect(registerSWMock).toHaveBeenCalledTimes(1)
    })

    it('un registro fallido no propaga: la app anda igual, solo sin offline', () => {
      registerSWMock.mockImplementation(() => { throw new Error('sin permisos') })

      expect(() => registrarServiceWorker()).not.toThrow()
    })
  })

  describe('aviso de version nueva', () => {
    it('avisa a los suscriptores cuando queda un build esperando', () => {
      const escucha = vi.fn()
      suscribirActualizacionSW(escucha)
      registrarServiceWorker()

      expect(hayActualizacionSWEsperando()).toBe(false)

      const opciones = registerSWMock.mock.calls[0][0] as OpcionesRegistro
      opciones.onNeedRefresh?.()

      expect(hayActualizacionSWEsperando()).toBe(true)
      expect(escucha).toHaveBeenCalledTimes(1)
    })

    it('deja de avisar despues de desuscribirse', () => {
      const escucha = vi.fn()
      const desuscribir = suscribirActualizacionSW(escucha)
      registrarServiceWorker()
      desuscribir()

      const opciones = registerSWMock.mock.calls[0][0] as OpcionesRegistro
      opciones.onNeedRefresh?.()

      expect(escucha).not.toHaveBeenCalled()
    })

    it('un suscriptor que explota no frena a los demas', () => {
      const explota = vi.fn(() => { throw new Error('boom') })
      const sano = vi.fn()
      suscribirActualizacionSW(explota)
      suscribirActualizacionSW(sano)
      registrarServiceWorker()

      const opciones = registerSWMock.mock.calls[0][0] as OpcionesRegistro
      expect(() => opciones.onNeedRefresh?.()).not.toThrow()
      expect(sano).toHaveBeenCalled()
    })
  })

  describe('aplicar la actualizacion', () => {
    /** Registra y devuelve el activador que expone el plugin. */
    function registrarCon(reg: ServiceWorkerRegistration | null) {
      const activar = vi.fn().mockResolvedValue(undefined)
      registerSWMock.mockImplementation((opciones: OpcionesRegistro) => {
        if (reg) opciones.onRegisteredSW?.('/sw.js', reg)
        return activar
      })
      registrarServiceWorker()
      return activar
    }

    it('activa el SW en espera y NO recarga a mano', async () => {
      // Clave del arreglo: con el SW controlando, un reload pelado sirve el
      // index.html viejo del precache. La recarga la dispara el cambio de
      // controlador, no nosotros.
      const { reg } = registroFalso({ waiting: { postMessage: vi.fn() } })
      const activar = registrarCon(reg)

      await aplicarActualizacionSW()

      expect(activar).toHaveBeenCalledWith(true)
      expect(reloadMock).not.toHaveBeenCalled()
    })

    it('va a buscar el sw nuevo si el cartel llego antes que el navegador', async () => {
      // /version.json se entera antes de que el navegador revise el sw.js.
      const falso = registroFalso()
      const activar = registrarCon(falso.reg)

      falso.reg.update = vi.fn().mockImplementation(async () => {
        falso.empezarInstalacion()
      })

      const promesa = aplicarActualizacionSW()
      await vi.waitFor(() => expect(falso.reg.update).toHaveBeenCalled())
      falso.terminarInstalacion()
      await promesa

      expect(activar).toHaveBeenCalledWith(true)
      expect(reloadMock).not.toHaveBeenCalled()
    })

    it('recarga si no hay service worker registrado', async () => {
      registrarCon(null)

      await aplicarActualizacionSW()

      expect(reloadMock).toHaveBeenCalledTimes(1)
    })

    it('recarga igual si el update del service worker falla', async () => {
      const { reg } = registroFalso()
      const activar = registrarCon(reg)
      reg.update = vi.fn().mockRejectedValue(new Error('sin red'))

      await aplicarActualizacionSW()

      expect(activar).not.toHaveBeenCalled()
      expect(reloadMock).toHaveBeenCalledTimes(1)
    })

    it('recarga si el update no trajo ningun build nuevo', async () => {
      const { reg } = registroFalso()
      registrarCon(reg)

      await aplicarActualizacionSW()

      expect(reg.update).toHaveBeenCalled()
      expect(reloadMock).toHaveBeenCalledTimes(1)
    })
  })
})
