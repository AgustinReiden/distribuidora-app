/** Rut-B7 (#1554): el aviso del chofer antes de que el server rechace cerrar la ruta. */
import { describe, it, expect } from 'vitest'
import { avisoParadasSinMarcar } from './paradasSinMarcar'

describe('avisoParadasSinMarcar', () => {
  it('con todo marcado no avisa', () => {
    expect(avisoParadasSinMarcar(0)).toBeNull()
    expect(avisoParadasSinMarcar(-1)).toBeNull()
    expect(avisoParadasSinMarcar(Number.NaN)).toBeNull()
  })

  it('una parada, en singular', () => {
    expect(avisoParadasSinMarcar(1)).toBe(
      'Te queda 1 parada sin marcar: marcá cada una como entregada o no entregada. La ruta se cierra cuando estén todas marcadas.',
    )
  })

  it('tres paradas, en plural', () => {
    expect(avisoParadasSinMarcar(3)).toMatch(/^Te quedan 3 paradas sin marcar: /)
  })
})
