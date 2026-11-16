/** FRV-1 (#1598): cuándo la edición vuelve a armar sus líneas desde lo guardado. */
import { describe, it, expect } from 'vitest'
import { debeReiniciarLineas, huellaLineasGuardadas } from './lineasEdicionPedido'

const linea = { id: 1, producto_id: 97, cantidad: 10, precio_unitario: 1000, origen_precio: 'lista' }

describe('huellaLineasGuardadas', () => {
  it('no cambia con una copia ni con los ids como string', () => {
    const copia = { ...linea, id: '1', producto_id: '97', cantidad: '10', precio_unitario: '1000' }
    expect(huellaLineasGuardadas([copia])).toBe(huellaLineasGuardadas([linea]))
  })

  it('cambia con la cantidad, el precio o las líneas reinsertadas', () => {
    const base = huellaLineasGuardadas([linea])
    expect(huellaLineasGuardadas([{ ...linea, cantidad: 8 }])).not.toBe(base)
    expect(huellaLineasGuardadas([{ ...linea, precio_unitario: 900 }])).not.toBe(base)
    expect(huellaLineasGuardadas([{ ...linea, id: 2 }])).not.toBe(base)
  })
})

describe('debeReiniciarLineas', () => {
  const inicio = { pedidoId: '5', huella: 'h1' }

  it('la primera vez, sí', () => {
    expect(debeReiniciarLineas(null, inicio, false)).toBe(true)
  })

  it('el mismo pedido con lo guardado igual: sólo si no hay cambios sin guardar', () => {
    expect(debeReiniciarLineas(inicio, { ...inicio }, true)).toBe(false)
    expect(debeReiniciarLineas(inicio, { ...inicio }, false)).toBe(true)
  })

  it('otro pedido u otra versión guardada: sí, aunque haya cambios', () => {
    expect(debeReiniciarLineas(inicio, { pedidoId: '6', huella: 'h1' }, true)).toBe(true)
    expect(debeReiniciarLineas(inicio, { pedidoId: '5', huella: 'h2' }, true)).toBe(true)
  })
})
