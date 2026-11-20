/**
 * 1590-c (#1590): la devolución por lote (Vencimientos) tiene el mismo tope que la
 * devolución de la compra: si la compra ya tiene un ajuste vigente, no puede pasar
 * lo que le queda (su total menos sus notas vigentes). La pantalla del lote no lo
 * decía y el usuario se enteraba por el rechazo del server.
 */
import { describe, it, expect } from 'vitest'
import { restanteDevolucionCompra } from './notaCredito'

describe('restanteDevolucionCompra', () => {
  it('con un ajuste vigente, es el total menos las notas vigentes', () => {
    expect(restanteDevolucionCompra(1000, [
      { total: 800, tipo: 'ajuste', anulada: false },
      { total: 50, tipo: 'devolucion', anulada: false },
      { total: 100, tipo: 'devolucion', anulada: true },
    ])).toBe(150)
  })

  it('sin ajuste no hay tope: devolver toda la mercadería entra siempre', () => {
    expect(restanteDevolucionCompra(1000, [{ total: 300, tipo: 'devolucion', anulada: false }])).toBeNull()
  })

  it('un ajuste anulado no pone tope', () => {
    expect(restanteDevolucionCompra(1000, [{ total: 800, tipo: 'ajuste', anulada: true }])).toBeNull()
  })

  it('sin el total de la compra no se puede decir', () => {
    expect(restanteDevolucionCompra(null, [{ total: 800, tipo: 'ajuste', anulada: false }])).toBeNull()
  })

  it('no baja de 0 aunque las notas pasen el total (datos viejos)', () => {
    expect(restanteDevolucionCompra(1000, [{ total: 1200, tipo: 'ajuste', anulada: false }])).toBe(0)
  })
})
