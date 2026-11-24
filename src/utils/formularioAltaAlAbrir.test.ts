import { describe, it, expect } from 'vitest'
import { formularioAltaAlAbrir } from './formularioAltaAlAbrir'

const blanco = { clienteId: '', items: [] as unknown[], notas: '', fecha: '2026-11-23', otro: 1 }

describe('formularioAltaAlAbrir (frv-B1)', () => {
  it('un formulario en blanco de ayer toma hoy y conserva el resto', () => {
    expect(formularioAltaAlAbrir(blanco, '2026-11-24')).toEqual({ ...blanco, fecha: '2026-11-24' })
  })

  it('si ya es de hoy devuelve el mismo objeto (no re-renderiza)', () => {
    const hoy = { ...blanco, fecha: '2026-11-24' }
    expect(formularioAltaAlAbrir(hoy, '2026-11-24')).toBe(hoy)
  })

  it('no toca uno con cliente, renglones o notas', () => {
    for (const cargado of [
      { ...blanco, clienteId: '9' },
      { ...blanco, items: [{}] },
      { ...blanco, notas: 'llamar antes' },
    ]) {
      expect(formularioAltaAlAbrir(cargado, '2026-11-24')).toBe(cargado)
    }
  })
})
