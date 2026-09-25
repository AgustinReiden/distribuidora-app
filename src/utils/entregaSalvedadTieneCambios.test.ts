import { describe, it, expect } from 'vitest'
import { entregaSalvedadTieneCambios } from './entregaSalvedadTieneCambios'

describe('entregaSalvedadTieneCambios', () => {
  it('en la selección sin nada tildado no hay nada que perder', () => {
    expect(entregaSalvedadTieneCambios({ paso: 'seleccion', seleccionados: 0 })).toBe(false)
  })

  it.each([1, 2, 7])('en la selección con %i ítem(s) tildado(s) hay cambios', (seleccionados) => {
    expect(entregaSalvedadTieneCambios({ paso: 'seleccion', seleccionados })).toBe(true)
  })

  it('el paso de confirmación cuenta como cambios aunque el conteo diga 0', () => {
    // No se llega a confirmación sin tildar nada, pero la regla no depende de
    // eso: en ese paso puede haber un guardado en vuelo.
    expect(entregaSalvedadTieneCambios({ paso: 'confirmacion', seleccionados: 0 })).toBe(true)
  })

  it('el paso de confirmación con ítems tildados también', () => {
    expect(entregaSalvedadTieneCambios({ paso: 'confirmacion', seleccionados: 3 })).toBe(true)
  })
})
