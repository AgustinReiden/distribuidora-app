import { describe, it, expect } from 'vitest'
import { errorDeMinimoVenta, CANTIDAD_MINIMA_VENTA_MAXIMA, MENSAJE_MINIMO_VENTA_MAXIMO } from './minimoVenta'

describe('errorDeMinimoVenta', () => {
  it('vacío, null y 0 son «sin mínimo»', () => {
    expect(errorDeMinimoVenta(undefined)).toBeNull()
    expect(errorDeMinimoVenta(null)).toBeNull()
    expect(errorDeMinimoVenta(0)).toBeNull()
  })

  it('de 1 a 99.999.999 pasa', () => {
    expect(errorDeMinimoVenta(1)).toBeNull()
    expect(errorDeMinimoVenta(99_999_999)).toBeNull()
    expect(errorDeMinimoVenta(CANTIDAD_MINIMA_VENTA_MAXIMA)).toBeNull()
  })

  it('arriba del tope se rechaza con el mensaje claro', () => {
    expect(errorDeMinimoVenta(CANTIDAD_MINIMA_VENTA_MAXIMA + 1)).toBe(MENSAJE_MINIMO_VENTA_MAXIMO)
    expect(errorDeMinimoVenta(100_000_000)).toBe(MENSAJE_MINIMO_VENTA_MAXIMO)
    expect(MENSAJE_MINIMO_VENTA_MAXIMO).toContain('99.999.999')
  })

  it('negativo, decimal y no numérico se rechazan', () => {
    expect(errorDeMinimoVenta(-3)).toMatch(/negativo/)
    expect(errorDeMinimoVenta(1.5)).toMatch(/entero/)
    expect(errorDeMinimoVenta(Number.NaN)).toMatch(/número/)
  })
})
