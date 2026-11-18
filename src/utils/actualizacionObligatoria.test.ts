/**
 * D57 (1563-b8 de #1563): con una versión nueva, la app se actualiza sola al
 * volver a ella o al cambiar de pantalla. No con algo a medio cargar, y no en
 * loop si el salto no prospera.
 */
import { describe, it, expect } from 'vitest'
import { saltarAlBuildNuevo, type MomentoDeActualizar } from './actualizacionObligatoria'

const base: MomentoDeActualizar = { disparador: 'aviso', trabajoEnCurso: false, enEnfriamiento: false, recienAbierta: false }

describe('saltarAlBuildNuevo (D57)', () => {
  it('al volver a la app salta, aunque la app lleve rato abierta', () => {
    expect(saltarAlBuildNuevo({ ...base, disparador: 'volver' })).toBe(true)
  })

  it('al cambiar de pantalla salta', () => {
    expect(saltarAlBuildNuevo({ ...base, disparador: 'pantalla' })).toBe(true)
  })

  it('enterarse con la app en uso no salta: avisa el cartel y espera el próximo momento', () => {
    expect(saltarAlBuildNuevo(base)).toBe(false)
  })

  it('recién abierta la app salta al enterarse: no hay nada que perder', () => {
    expect(saltarAlBuildNuevo({ ...base, recienAbierta: true })).toBe(true)
  })

  it('con un modal abierto o un campo en edición no salta nunca', () => {
    for (const disparador of ['volver', 'pantalla', 'aviso'] as const) {
      expect(saltarAlBuildNuevo({ ...base, disparador, trabajoEnCurso: true, recienAbierta: true })).toBe(false)
    }
  })

  it('en el enfriamiento de un salto que no prosperó no salta', () => {
    expect(saltarAlBuildNuevo({ ...base, disparador: 'volver', enEnfriamiento: true })).toBe(false)
    expect(saltarAlBuildNuevo({ ...base, disparador: 'pantalla', enEnfriamiento: true })).toBe(false)
  })
})
