import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { esErrorDeChunk, importConRecarga } from './lazyWithReload'

describe('esErrorDeChunk', () => {
  it('detecta mensajes de chunk obsoleto tras deploy', () => {
    expect(esErrorDeChunk(new Error('Failed to fetch dynamically imported module: https://x/assets/pdfExport-Dd1O76j0.js'))).toBe(true)
    expect(esErrorDeChunk(new Error('error loading dynamically imported module'))).toBe(true)
    expect(esErrorDeChunk(new Error('Importing a module script failed'))).toBe(true)
    expect(esErrorDeChunk(new Error('ChunkLoadError: Loading chunk 5 failed'))).toBe(true)
  })

  it('ignora errores que no son de chunk', () => {
    expect(esErrorDeChunk(new Error('Network request failed'))).toBe(false)
    expect(esErrorDeChunk('algo')).toBe(false)
    expect(esErrorDeChunk(null)).toBe(false)
  })
})

describe('importConRecarga', () => {
  const originalLocation = window.location
  let reloadMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    reloadMock = vi.fn()
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...originalLocation, reload: reloadMock },
    })
    sessionStorage.clear()
  })

  afterEach(() => {
    Object.defineProperty(window, 'location', { configurable: true, value: originalLocation })
    sessionStorage.clear()
    vi.restoreAllMocks()
  })

  it('devuelve el módulo cuando el import resuelve', async () => {
    const mod = { generar: vi.fn() }
    await expect(importConRecarga(() => Promise.resolve(mod))).resolves.toBe(mod)
    expect(reloadMock).not.toHaveBeenCalled()
  })

  it('ante chunk obsoleto recarga una vez y lanza error amistoso', async () => {
    const factory = () => Promise.reject(new Error('Failed to fetch dynamically imported module: /assets/pdfExport-x.js'))
    await expect(importConRecarga(factory)).rejects.toThrow(/versión nueva/i)
    expect(reloadMock).toHaveBeenCalledTimes(1)
  })

  it('no recarga de nuevo dentro del cooldown', async () => {
    const factory = () => Promise.reject(new Error('Failed to fetch dynamically imported module: /assets/pdfExport-x.js'))
    await expect(importConRecarga(factory)).rejects.toThrow(/versión nueva/i)     // 1ra: dispara recarga
    await expect(importConRecarga(factory)).rejects.toThrow(/Recargá la página/i) // 2da: en cooldown
    expect(reloadMock).toHaveBeenCalledTimes(1)
  })

  it('propaga errores que no son de chunk sin recargar', async () => {
    const err = new Error('boom de negocio')
    await expect(importConRecarga(() => Promise.reject(err))).rejects.toThrow('boom de negocio')
    expect(reloadMock).not.toHaveBeenCalled()
  })

  /**
   * El chofer en la calle. La app NO registra service worker, así que no hay app
   * shell precacheado: recargar sin red deja la pantalla en blanco y lo deja sin
   * app en medio del reparto. Antes se recargaba igual.
   */
  describe('sin conexión', () => {
    const setOnline = (v: boolean) =>
      Object.defineProperty(navigator, 'onLine', { configurable: true, value: v })

    afterEach(() => setOnline(true))

    it('NO recarga y avisa que no recargue', async () => {
      setOnline(false)
      const factory = () => Promise.reject(new Error('Failed to fetch dynamically imported module: /assets/x.js'))

      await expect(importConRecarga(factory)).rejects.toThrow(/no hay conexión/i)
      await expect(importConRecarga(factory)).rejects.toThrow(/no recargues/i)
      expect(reloadMock).not.toHaveBeenCalled()
    })

    it('con la red de vuelta sí recarga', async () => {
      setOnline(false)
      const factory = () => Promise.reject(new Error('Failed to fetch dynamically imported module: /assets/x.js'))
      await expect(importConRecarga(factory)).rejects.toThrow(/no hay conexión/i)
      expect(reloadMock).not.toHaveBeenCalled()

      setOnline(true)
      await expect(importConRecarga(factory)).rejects.toThrow(/versión nueva/i)
      expect(reloadMock).toHaveBeenCalledTimes(1)
    })
  })

  /**
   * El cooldown viejo era temporal, no un tope: pasados 15 s volvía a recargar,
   * y si el chunk seguía sin estar la pestaña entraba en loop de recargas.
   */
  it('deja de insistir tras 2 recargas, aunque pase el cooldown', async () => {
    const factory = () => Promise.reject(new Error('Failed to fetch dynamically imported module: /assets/x.js'))

    await expect(importConRecarga(factory)).rejects.toThrow(/versión nueva/i)
    expect(reloadMock).toHaveBeenCalledTimes(1)

    // Se simula que pasó el cooldown conservando el contador de intentos.
    const [intentos] = (sessionStorage.getItem('chunk-reload-at') || '0|0').split('|')
    sessionStorage.setItem('chunk-reload-at', `${intentos}|0`)
    await expect(importConRecarga(factory)).rejects.toThrow(/versión nueva/i)
    expect(reloadMock).toHaveBeenCalledTimes(2)

    // Tercera: el tope corta, no importa el cooldown.
    const [intentos2] = (sessionStorage.getItem('chunk-reload-at') || '0|0').split('|')
    sessionStorage.setItem('chunk-reload-at', `${intentos2}|0`)
    await expect(importConRecarga(factory)).rejects.toThrow(/Recargá la página/i)
    expect(reloadMock).toHaveBeenCalledTimes(2)
  })
})
