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
})
