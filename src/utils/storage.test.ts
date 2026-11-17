import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import { getStorageItem, setStorageItem, removeStorageItem } from './storage'

describe('storage seguro', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.mocked(localStorage.setItem).mockClear()
  })
  afterEach(() => vi.mocked(localStorage.setItem).mockClear())

  it('guarda y lee, con valor por defecto si no hay nada', () => {
    expect(getStorageItem('darkMode', null)).toBeNull()
    expect(setStorageItem('darkMode', true)).toBe(true)
    expect(getStorageItem<boolean | null>('darkMode', null)).toBe(true)
  })

  it('un valor corrupto vuelve al default y se limpia', () => {
    localStorage.setItem('darkMode', '{no es json')
    expect(getStorageItem('darkMode', false)).toBe(false)
    expect(localStorage.getItem('darkMode')).toBeNull()
  })

  it('removeStorageItem borra la clave', () => {
    localStorage.setItem('x', '1')
    expect(removeStorageItem('x')).toBe(true)
    expect(localStorage.getItem('x')).toBeNull()
  })

  // 1563 (código muerto de M8): al llenarse la cuota se recortaba la clave `notifications`,
  // que ya no existe (las notificaciones son de cada usuario). Ahora no toca nada ajeno.
  it('con la cuota llena no guarda y no toca ninguna otra clave', () => {
    const lista = Array.from({ length: 12 }, (_, i) => ({ id: i }))
    localStorage.setItem('notifications', JSON.stringify(lista))
    vi.mocked(localStorage.setItem).mockClear()
    const cuota = Object.assign(new Error('lleno'), { name: 'QuotaExceededError' })
    // `localStorage` es el de `src/test/setup.js` (en memoria, con `vi.fn`): sólo falla la primera escritura.
    vi.mocked(localStorage.setItem).mockImplementationOnce(() => { throw cuota })

    expect(setStorageItem('darkMode', true)).toBe(false)

    expect(vi.mocked(localStorage.setItem)).toHaveBeenCalledTimes(1)
    expect(JSON.parse(localStorage.getItem('notifications') ?? '[]')).toHaveLength(12)
  })
})
