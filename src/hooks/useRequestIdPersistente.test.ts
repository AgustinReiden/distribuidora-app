/**
 * Tests de `useRequestIdPersistente` (#1410): con el modal abierto, la clave que
 * ya tiene no depende de que el almacenamiento la siga teniendo.
 */
import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useRequestIdPersistente } from './useRequestIdPersistente'
import { fijarUsuarioRequestIds, VIGENCIA_REQUEST_ID_MS } from '../utils/requestIdPersistente'

const HUELLA = 'fifo|303|general|2026-11-04||111280|efectivo|'

beforeEach(() => {
  fijarUsuarioRequestIds('u-ana')
})

afterEach(() => {
  vi.useRealTimers()
  fijarUsuarioRequestIds(null)
})

describe('useRequestIdPersistente', () => {
  it('con el modal abierto, otra pestaña que pisa lo guardado no le cambia la clave', () => {
    const { result } = renderHook(() => useRequestIdPersistente())
    const primero = result.current.requestId(HUELLA)

    localStorage.clear()

    expect(result.current.requestId(HUELLA)).toBe(primero)
  })

  it('con el modal abierto, la clave no vence aunque pasen más de dos horas sin reintentar', () => {
    vi.useFakeTimers()
    vi.setSystemTime(Date.parse('2026-11-04T15:00:00Z'))
    const { result } = renderHook(() => useRequestIdPersistente())
    const primero = result.current.requestId(HUELLA)

    vi.setSystemTime(Date.parse('2026-11-04T15:00:00Z') + VIGENCIA_REQUEST_ID_MS + 60_000)

    expect(result.current.requestId(HUELLA)).toBe(primero)
  })

  it('cerrar y reabrir el modal encuentra la misma clave', () => {
    const primero = renderHook(() => useRequestIdPersistente()).result.current.requestId(HUELLA)
    const reabierto = renderHook(() => useRequestIdPersistente()).result.current.requestId(HUELLA)
    expect(reabierto).toBe(primero)
  })

  it('olvidar: el mismo pago después es otro, también con el modal abierto', () => {
    const { result } = renderHook(() => useRequestIdPersistente())
    const cobrado = result.current.requestId(HUELLA)
    result.current.olvidar([HUELLA])
    expect(result.current.requestId(HUELLA)).not.toBe(cobrado)
  })
})
