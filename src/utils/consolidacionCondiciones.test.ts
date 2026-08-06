import { describe, it, expect } from 'vitest'
import { detectarConsolidables } from './consolidacionCondiciones'
import type { GrupoPrecioConDetalles } from '../types'

let seq = 0

/** Condición de un solo producto, que es como está cargado el 93% de prod. */
function cond(
  nombre: string,
  productoId: string,
  escalas: Array<[number, number]>,
  over: Partial<GrupoPrecioConDetalles> = {},
): GrupoPrecioConDetalles {
  const id = `g${++seq}`
  return {
    id,
    nombre,
    descripcion: null,
    activo: true,
    productos: [{ id: `gp${seq}`, grupo_precio_id: id, producto_id: productoId }],
    escalas: escalas.map(([cantidad, precio], i) => ({
      id: `${id}-e${i}`,
      grupo_precio_id: id,
      cantidad_minima: cantidad,
      precio_unitario: precio,
    })),
    ...over,
  } as GrupoPrecioConDetalles
}

const NOMBRES = new Map([
  ['p1', 'CODITO COTELLA 500GRS'],
  ['p2', 'MOSTACHO COTELLA 500GRS'],
  ['p3', 'TIRABUZON COTELLA 500GRS'],
  ['p4', 'SPAGHETTI ROSCA COTELLA 500GRS'],
])

describe('detectarConsolidables', () => {
  it('junta los sabores que comparten el mismo perfil de escalas', () => {
    // El caso de prod: 3 sabores × 2 condiciones (½ fardo y fardo) = 6
    // condiciones que en realidad son un solo fardo surtido.
    const grupos = [
      cond('CODITO 1/2 FARDO', 'p1', [[6, 890]]),
      cond('CODITO FARDO', 'p1', [[12, 850]]),
      cond('MOSTACHO 1/2 FARDO', 'p2', [[6, 890]]),
      cond('MOSTACHO FARDO', 'p2', [[12, 850]]),
      cond('TIRABUZON 1/2 FARDO', 'p3', [[6, 890]]),
      cond('TIRABUZON FARDO', 'p3', [[12, 850]]),
    ]

    const [caso, ...resto] = detectarConsolidables(grupos, NOMBRES)
    expect(resto).toHaveLength(0)
    expect(caso.productoIds.sort()).toEqual(['p1', 'p2', 'p3'])
    expect(caso.condicionesOrigen).toHaveLength(6)
    expect(caso.escalas).toEqual([
      { cantidadMinima: 6, precioUnitario: 890, etiqueta: null },
      { cantidadMinima: 12, precioUnitario: 850, etiqueta: null },
    ])
  })

  it('separa los perfiles con precio distinto: son fardos distintos', () => {
    const grupos = [
      cond('CODITO 1/2', 'p1', [[6, 890]]),
      cond('CODITO FARDO', 'p1', [[12, 850]]),
      cond('ROSCA 1/2', 'p4', [[6, 1290]]),
      cond('ROSCA FARDO', 'p4', [[12, 1240]]),
    ]

    const casos = detectarConsolidables(grupos, NOMBRES)
    expect(casos).toHaveLength(2)
    expect(casos.every(c => c.productoIds.length === 1)).toBe(true)
    expect(casos.every(c => c.condicionesOrigen.length === 2)).toBe(true)
  })

  it('un solo producto con dos condiciones también se unifica', () => {
    const grupos = [
      cond('DEDALITO 1/2 FARDO', 'p1', [[6, 940]]),
      cond('DEDALITO X FARDO', 'p1', [[12, 900]]),
    ]
    const [caso] = detectarConsolidables(grupos, NOMBRES)
    expect(caso.productoIds).toEqual(['p1'])
    expect(caso.escalas).toHaveLength(2)
  })

  it('una condición sola no es una fusión', () => {
    expect(detectarConsolidables([cond('Sola', 'p1', [[12, 850]])], NOMBRES)).toHaveLength(0)
  })

  it('no toca las condiciones multi-producto: ya son un fardo surtido', () => {
    const surtida = cond('PAPAS SABORIZADAS', 'p1', [[12, 850]], {
      productos: [
        { id: 'x1', grupo_precio_id: 'gX', producto_id: 'p1' },
        { id: 'x2', grupo_precio_id: 'gX', producto_id: 'p2' },
      ],
    } as Partial<GrupoPrecioConDetalles>)
    expect(detectarConsolidables([surtida], NOMBRES)).toHaveLength(0)
  })

  it('deja afuera al producto que ya participa de una condición compartida', () => {
    // Si p1 está en una surtida, moverle las sueltas partiría su precio.
    const surtida = cond('SURTIDO', 'zz', [[12, 850]], {
      productos: [
        { id: 'x1', grupo_precio_id: 'gS', producto_id: 'p1' },
        { id: 'x2', grupo_precio_id: 'gS', producto_id: 'p9' },
      ],
    } as Partial<GrupoPrecioConDetalles>)
    const grupos = [
      surtida,
      cond('CODITO 1/2', 'p1', [[6, 890]]),
      cond('CODITO FARDO', 'p1', [[12, 850]]),
    ]
    expect(detectarConsolidables(grupos, NOMBRES)).toHaveLength(0)
  })

  it('ignora las condiciones desactivadas', () => {
    const grupos = [
      cond('CODITO 1/2', 'p1', [[6, 890]], { activo: false }),
      cond('CODITO FARDO', 'p1', [[12, 850]]),
    ]
    expect(detectarConsolidables(grupos, NOMBRES)).toHaveLength(0)
  })

  it('ignora las condiciones sin escalas', () => {
    const grupos = [
      cond('Vacia', 'p1', []),
      cond('CODITO FARDO', 'p1', [[12, 850]]),
    ]
    expect(detectarConsolidables(grupos, NOMBRES)).toHaveLength(0)
  })

  it('propone un nombre con lo que los sabores tienen en común', () => {
    const grupos = [
      cond('CODITO 1/2 FARDO', 'p1', [[12, 850]]),
      cond('MOSTACHO FARDO', 'p2', [[12, 850]]),
    ]
    // "CODITO 1/2 FARDO" describiria mal una condicion con dos sabores.
    expect(detectarConsolidables(grupos, NOMBRES)[0].nombreSugerido).toBe('COTELLA 500GRS')
  })

  it('ordena primero las fusiones que agrupan más sabores', () => {
    const grupos = [
      cond('A1', 'p1', [[10, 100]]),
      cond('A2', 'p1', [[20, 90]]),
      cond('B1', 'p2', [[12, 850]]),
      cond('B2', 'p3', [[12, 850]]),
      cond('B3', 'p4', [[12, 850]]),
    ]
    const casos = detectarConsolidables(grupos, NOMBRES)
    expect(casos[0].productoIds).toHaveLength(3)
    expect(casos[1].productoIds).toHaveLength(1)
  })
})
