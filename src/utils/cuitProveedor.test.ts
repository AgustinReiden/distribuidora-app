import { describe, it, expect } from 'vitest'
import { cuitLimpio, mismoCuit, patronCuit } from './cuitProveedor'

describe('cuitProveedor (1557-b10)', () => {
  it('cuitLimpio deja sólo los dígitos', () => {
    expect(cuitLimpio('30-71234567-8')).toBe('30712345678')
    expect(cuitLimpio(' 30 71234567 8 ')).toBe('30712345678')
    expect(cuitLimpio(null)).toBe('')
  })

  it('mismoCuit ignora guiones, espacios y puntos', () => {
    expect(mismoCuit('30-71234567-8', '30712345678')).toBe(true)
    expect(mismoCuit('30.71234567.8', '30 71234567 8')).toBe(true)
    expect(mismoCuit('30-71234567-8', '30-71234567-9')).toBe(false)
  })

  it('un CUIT sin dígitos no es igual a nada, ni a otro vacío', () => {
    expect(mismoCuit('', '')).toBe(false)
    expect(mismoCuit(null, '---')).toBe(false)
  })

  it('patronCuit acierta cualquier separador entre dígitos', () => {
    expect(patronCuit('30-71')).toBe('%3%0%7%1%')
    expect(patronCuit('---')).toBeNull()
  })
})
