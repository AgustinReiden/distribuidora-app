import { describe, expect, it } from 'vitest'
import { getRolColor, getRolLabel } from './formatters'

describe('role formatters', () => {
  it('returns explicit labels for known roles', () => {
    expect(getRolLabel('admin')).toBe('Admin')
    expect(getRolLabel('preventista')).toBe('Preventista')
    expect(getRolLabel('transportista')).toBe('Transportista')
    expect(getRolLabel('deposito')).toBe('Deposito')
  })

  it('returns a neutral fallback for empty or unknown roles', () => {
    expect(getRolLabel('')).toBe('Sin rol')
    expect(getRolLabel('desconocido')).toBe('Sin rol')
    expect(getRolColor('')).toBe('bg-gray-100 text-gray-700')
    expect(getRolColor('desconocido')).toBe('bg-gray-100 text-gray-700')
  })
})
