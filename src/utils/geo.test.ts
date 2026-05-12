import { describe, it, expect } from 'vitest'
import {
  haversineMeters,
  formatDistancia,
  clasificarDistancia,
  colorPreventista,
} from './geo'

describe('haversineMeters', () => {
  it('returns 0 for identical coordinates', () => {
    const c = { lat: -26.8, lng: -65.2 }
    expect(haversineMeters(c, c)).toBeCloseTo(0, 3)
  })

  it('matches known distance Tucumán → Salta (~250 km)', () => {
    const tucuman = { lat: -26.8083, lng: -65.2176 }
    const salta = { lat: -24.7821, lng: -65.4232 }
    const meters = haversineMeters(tucuman, salta)
    expect(meters).toBeGreaterThan(220_000)
    expect(meters).toBeLessThan(260_000)
  })

  it('is symmetric', () => {
    const a = { lat: -26.8, lng: -65.2 }
    const b = { lat: -26.9, lng: -65.3 }
    expect(haversineMeters(a, b)).toBeCloseTo(haversineMeters(b, a), 5)
  })
})

describe('formatDistancia', () => {
  it('returns dash for null/undefined/NaN', () => {
    expect(formatDistancia(null)).toBe('—')
    expect(formatDistancia(undefined)).toBe('—')
    expect(formatDistancia(NaN)).toBe('—')
  })

  it('uses meters under 1000', () => {
    expect(formatDistancia(0)).toBe('0 m')
    expect(formatDistancia(320)).toBe('320 m')
    expect(formatDistancia(999.4)).toBe('999 m')
  })

  it('uses km with one decimal above 1000', () => {
    expect(formatDistancia(1000)).toBe('1.0 km')
    expect(formatDistancia(1432)).toBe('1.4 km')
    expect(formatDistancia(5234)).toBe('5.2 km')
  })
})

describe('clasificarDistancia', () => {
  it('classifies thresholds correctly (ok <500m, cerca <1km, lejos >=1km)', () => {
    expect(clasificarDistancia(null)).toBe('sin_dato')
    expect(clasificarDistancia(undefined)).toBe('sin_dato')
    expect(clasificarDistancia(0)).toBe('ok')
    expect(clasificarDistancia(499)).toBe('ok')
    expect(clasificarDistancia(500)).toBe('cerca')
    expect(clasificarDistancia(999)).toBe('cerca')
    expect(clasificarDistancia(1000)).toBe('lejos')
    expect(clasificarDistancia(10_000)).toBe('lejos')
  })
})

describe('colorPreventista', () => {
  it('returns deterministic color for the same id', () => {
    const id = 'b1f2c3d4-1234-5678-9abc-def012345678'
    expect(colorPreventista(id)).toBe(colorPreventista(id))
  })

  it('returns a hex color from the palette', () => {
    const c = colorPreventista('abc')
    expect(c).toMatch(/^#[0-9a-f]{6}$/i)
  })

  it('different ids tend to get different colors', () => {
    const ids = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']
    const colors = new Set(ids.map(colorPreventista))
    // Palette has 8 entries; expect at least 3 distinct values across 8 inputs.
    expect(colors.size).toBeGreaterThanOrEqual(3)
  })
})
