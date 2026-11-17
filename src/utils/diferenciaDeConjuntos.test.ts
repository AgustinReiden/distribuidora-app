import { describe, it, expect } from 'vitest'
import { diferenciaDeConjuntos } from './diferenciaDeConjuntos'

describe('diferenciaDeConjuntos', () => {
  it('sin cambios no hay nada que quitar ni agregar', () => {
    expect(diferenciaDeConjuntos(['a', 'b'], ['b', 'a'])).toEqual({ quitar: [], agregar: [] })
  })

  it('separa lo que se quita de lo que se agrega', () => {
    expect(diferenciaDeConjuntos(['a', 'b'], ['b', 'c'])).toEqual({ quitar: ['a'], agregar: ['c'] })
  })

  it('desde vacío agrega todo, hasta vacío quita todo', () => {
    expect(diferenciaDeConjuntos([], ['a'])).toEqual({ quitar: [], agregar: ['a'] })
    expect(diferenciaDeConjuntos(['a'], [])).toEqual({ quitar: ['a'], agregar: [] })
  })

  it('ignora los repetidos', () => {
    expect(diferenciaDeConjuntos(['a', 'a'], ['a', 'b', 'b'])).toEqual({ quitar: [], agregar: ['b'] })
  })
})
