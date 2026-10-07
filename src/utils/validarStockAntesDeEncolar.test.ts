/**
 * #961 — Sin señal, la validación revisaba cada línea por separado. Un producto
 * comprado y regalado (o dos líneas de regalo de la misma promo) pasaba la
 * encolada y el rechazo llegaba recién al sincronizar. Los tests de siempre de
 * esta función viven en `lib/businessLogic.test.js` y no se tocan.
 */
import { describe, it, expect } from 'vitest'
import { validarStockAntesDeEncolar } from './validarStockAntesDeEncolar'

const productos = [
  { id: 'naranja', nombre: 'Manaos Naranja 3L', stock: 50 },
  { id: 'manzana', nombre: 'Manaos Manzana 3L', stock: 50 },
  { id: 'sinstock', nombre: 'Agotado', stock: 0 },
]

const regalo = (productoId: string, cantidad: number, mueve?: boolean) => ({
  productoId, cantidad, esBonificacion: true as const, promocionId: 'p1',
  ...(mueve === undefined ? {} : { regaloMueveStock: mueve }),
})

describe('validarStockAntesDeEncolar — suma por producto como el servidor', () => {
  it('comprado + regalado (promo que mueve stock): cada línea entra sola, juntas no', () => {
    const { itemsSinStock } = validarStockAntesDeEncolar([
      { productoId: 'naranja', cantidad: 45 },
      regalo('naranja', 10, true),
    ], productos)
    expect(itemsSinStock).toEqual([
      { productoId: 'naranja', nombre: 'Manaos Naranja 3L', solicitado: 55, disponible: 50 },
    ])
  })

  it('regalo repartido en sabores: la parte que cae en un producto ya comprado se suma', () => {
    const { itemsSinStock } = validarStockAntesDeEncolar([
      { productoId: 'manzana', cantidad: 40 },
      regalo('naranja', 12, true),
      regalo('manzana', 12, true),
    ], productos)
    expect(itemsSinStock).toHaveLength(1)
    expect(itemsSinStock[0]).toMatchObject({ productoId: 'manzana', solicitado: 52, disponible: 50 })
  })

  it('devuelve una sola entrada por producto aunque tenga varias líneas', () => {
    const { itemsSinStock } = validarStockAntesDeEncolar([
      { productoId: 'naranja', cantidad: 30 },
      { productoId: 'naranja', cantidad: 30 },
      regalo('naranja', 1, true),
    ], productos)
    expect(itemsSinStock).toHaveLength(1)
    expect(itemsSinStock[0].solicitado).toBe(61)
  })

  it('un regalo que no mueve stock no cuenta, ni siquiera contra un producto agotado', () => {
    const { itemsSinStock } = validarStockAntesDeEncolar([
      { productoId: 'naranja', cantidad: 50 },
      regalo('naranja', 12, false),
      regalo('sinstock', 6, false),
    ], productos)
    expect(itemsSinStock).toEqual([])
  })

  it('un regalo sin dato de la promo tampoco cuenta (el servidor lo toma como false)', () => {
    const { itemsSinStock } = validarStockAntesDeEncolar([
      { productoId: 'naranja', cantidad: 50 },
      regalo('naranja', 12),
    ], productos)
    expect(itemsSinStock).toEqual([])
  })

  it('un regalo que mueve stock sobre un producto agotado se rechaza', () => {
    const { itemsSinStock } = validarStockAntesDeEncolar([regalo('sinstock', 2, true)], productos)
    expect(itemsSinStock).toEqual([
      { productoId: 'sinstock', nombre: 'Agotado', solicitado: 2, disponible: 0 },
    ])
  })

  it('un producto que no está en el catálogo no se juzga: no hay dato', () => {
    const { itemsSinStock, stockSnapshot } = validarStockAntesDeEncolar([
      { productoId: 'fantasma', cantidad: 999 },
    ], productos)
    expect(itemsSinStock).toEqual([])
    expect(stockSnapshot).toEqual({})
  })

  it('un producto con el stock sin cargar se trata como 0', () => {
    const { itemsSinStock } = validarStockAntesDeEncolar(
      [{ productoId: 'x', cantidad: 1 }],
      [{ id: 'x', nombre: 'Sin cargar' } as unknown as { id: string; nombre: string; stock: number }],
    )
    expect(itemsSinStock).toEqual([
      { productoId: 'x', nombre: 'Sin cargar', solicitado: 1, disponible: 0 },
    ])
  })

  it('las reservas de los pedidos pendientes siguen la misma regla: el regalo reserva sólo si mueve stock', () => {
    const pendientes = [{
      items: [
        { productoId: 'naranja', cantidad: 20 },
        regalo('naranja', 10, true),
        regalo('naranja', 99, false),
      ],
    }]
    const { itemsSinStock, stockSnapshot } = validarStockAntesDeEncolar(
      [{ productoId: 'naranja', cantidad: 21 }], productos, pendientes,
    )
    expect(stockSnapshot.naranja).toEqual({ stockAlMomento: 50, reservadoOffline: 30, disponible: 20 })
    expect(itemsSinStock).toEqual([
      { productoId: 'naranja', nombre: 'Manaos Naranja 3L', solicitado: 21, disponible: 20 },
    ])
  })

  it('la snapshot incluye a los productos que sólo van de regalo sin mover stock', () => {
    const { stockSnapshot } = validarStockAntesDeEncolar([regalo('manzana', 3, false)], productos)
    expect(stockSnapshot.manzana).toEqual({ stockAlMomento: 50, reservadoOffline: 0, disponible: 50 })
  })
})
