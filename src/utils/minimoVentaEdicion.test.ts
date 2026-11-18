import { describe, it, expect } from 'vitest'
import { moqQueBloqueaLaEdicion } from './precioMayorista'
import { motivoPisoDeVentaEnLaEdicion, pisoDeVentaEnLaEdicion } from './minimoVentaEdicion'

describe('pisoDeVentaEnLaEdicion (H1 de la revisión de B23)', () => {
  it.each([
    ['renglón viejo de 3 con mínimo 6 hoy', 6, 3, 3],
    ['renglón viejo de 10 con mínimo 6', 6, 10, 6],
    ['renglón nuevo en la edición', 6, 0, 6],
    ['sin mínimo de venta', 1, 3, 1],
  ])('%s: mínimo %i, tenía %i, piso %i', (_caso, minimo, original, piso) => {
    const originales = new Map(original > 0 ? [['7', original]] : [])
    expect(pisoDeVentaEnLaEdicion('7', minimo, originales)).toBe(piso)
  })

  // Es la misma regla que frena el Guardar: todo lo que el campo deja (>= piso) la regla lo deja, y
  // todo lo que el campo pone en rojo la regla lo frena.
  it('coincide cantidad por cantidad con moqQueBloqueaLaEdicion', () => {
    for (const minimo of [1, 2, 6, 12]) {
      for (const original of [0, 1, 3, 5, 6, 8, 20]) {
        const originales = new Map(original > 0 ? [['7', original]] : [])
        const piso = pisoDeVentaEnLaEdicion('7', minimo, originales)
        for (let c = 1; c <= 25; c++) {
          const violaciones = c < minimo ? [{ productoId: '7', cantidadActual: c, cantidadMinima: minimo }] : []
          const bloquea = moqQueBloqueaLaEdicion(violaciones, originales).length > 0
          expect(c >= piso, `mínimo ${minimo}, original ${original}, cantidad ${c}`).toBe(!bloquea)
        }
      }
    }
  })

  it('el motivo dice lo que el pedido ya tenía cuando rige eso', () => {
    expect(motivoPisoDeVentaEnLaEdicion(6, 3)).toBe('El mínimo de venta es 6; este pedido ya tenía 3')
    expect(motivoPisoDeVentaEnLaEdicion(6, 6)).toBe('El mínimo de venta es 6')
    expect(motivoPisoDeVentaEnLaEdicion(1, 1)).toBeUndefined()
  })
})
