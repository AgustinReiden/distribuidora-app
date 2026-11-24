import { describe, it, expect } from 'vitest'
import { preventistaIdsDelAlta } from './asignacionClienteAlAlta'

describe('preventistaIdsDelAlta (FRV-2)', () => {
  it('el preventista queda asignado a sí mismo', () => {
    expect(preventistaIdsDelAlta({ isAdmin: false, isPreventista: true, userId: 'p1' })).toEqual(['p1'])
  })

  it('suma el suyo a lo que ya había, sin repetirlo', () => {
    expect(preventistaIdsDelAlta({ isAdmin: false, isPreventista: true, userId: 'p1', baseIds: ['p2', 'p1'] }))
      .toEqual(['p2', 'p1'])
  })

  it('el admin manda sólo lo que eligió (nada por defecto)', () => {
    expect(preventistaIdsDelAlta({ isAdmin: true, isPreventista: false, userId: 'a1' })).toEqual([])
    expect(preventistaIdsDelAlta({ isAdmin: true, isPreventista: false, userId: 'a1', baseIds: ['p2'] })).toEqual(['p2'])
  })

  it('un reservado a admin no lleva preventistas', () => {
    expect(preventistaIdsDelAlta({ isAdmin: true, isPreventista: false, userId: 'a1', baseIds: ['p2'], reservadoAdmin: true }))
      .toEqual([])
  })

  it('el encargado y el transportista no tocan las asignaciones', () => {
    expect(preventistaIdsDelAlta({ isAdmin: false, isPreventista: false, userId: 'e1' })).toBeUndefined()
  })

  it('sin usuario no se auto-asigna a nadie', () => {
    expect(preventistaIdsDelAlta({ isAdmin: false, isPreventista: true, userId: null })).toBeUndefined()
  })
})
