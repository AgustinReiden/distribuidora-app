/**
 * Tests de `useRequestIdEstable` — el UUID de idempotencia de los pagos (mig 167).
 *
 * La regla que importa: mismo pago => mismo UUID (el server lo deduplica),
 * pago distinto => UUID distinto (se registra aparte, como corresponde).
 */
import { describe, it, expect } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useRequestIdEstable } from './useRequestIdEstable'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

describe('useRequestIdEstable', () => {
  it('devuelve un UUID v4 valido', () => {
    const { result } = renderHook(() => useRequestIdEstable())
    expect(result.current('pago|c1|1000|efectivo')).toMatch(UUID_RE)
  })

  it('devuelve el MISMO UUID para la misma huella (reintento del mismo pago)', () => {
    const { result } = renderHook(() => useRequestIdEstable())
    const huella = 'pago|c1|111280|efectivo|2026-07-13'

    const primerIntento = result.current(huella)
    const segundoIntento = result.current(huella)
    const tercerIntento = result.current(huella)

    expect(segundoIntento).toBe(primerIntento)
    expect(tercerIntento).toBe(primerIntento)
  })

  it('devuelve un UUID nuevo si cambia el monto (es otro pago, no un reintento)', () => {
    const { result } = renderHook(() => useRequestIdEstable())

    const conMonto1000 = result.current('pago|c1|1000|efectivo')
    const conMonto2000 = result.current('pago|c1|2000|efectivo')

    expect(conMonto2000).not.toBe(conMonto1000)
  })

  it('da UUIDs distintos por linea de un pago dividido', () => {
    const { result } = renderHook(() => useRequestIdEstable())
    const base = 'divid|c1|p1|2026-08-05'

    const ids = [0, 1, 2].map(i => result.current(`${base}#${i}`))

    expect(new Set(ids).size).toBe(3)
    // y siguen siendo estables entre reintentos
    expect([0, 1, 2].map(i => result.current(`${base}#${i}`))).toEqual(ids)
  })

  it('sobrevive al re-render (el UUID no se regenera en cada pasada)', () => {
    const { result, rerender } = renderHook(() => useRequestIdEstable())
    const antes = result.current('pago|c1|1000|efectivo')

    rerender()

    expect(result.current('pago|c1|1000|efectivo')).toBe(antes)
  })
})
