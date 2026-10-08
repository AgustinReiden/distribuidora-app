/**
 * Espejo en el front de cómo `crear_pedido_completo` arma `v_cantidades_stock`
 * (mig 132, vigente en prod): por producto, suma la venta y suma el regalo SÓLO
 * si su promo tiene `regalo_mueve_stock`. Sin esa suma, offline cada línea se
 * revisaba por separado y el rechazo llegaba recién al sincronizar (#961).
 */
import { describe, it, expect } from 'vitest'
import {
  cantidadesQueDescuentanStock,
  indexarRegaloMueveStock,
} from './stockDelPedido'
import type { PromoMap, PromocionActiva } from './promociones'

describe('cantidadesQueDescuentanStock', () => {
  it('suma las líneas de venta del mismo producto', () => {
    const r = cantidadesQueDescuentanStock([
      { productoId: 'a', cantidad: 10 },
      { productoId: 'a', cantidad: 5 },
      { productoId: 'b', cantidad: 3 },
    ])
    expect(r.get('a')).toBe(15)
    expect(r.get('b')).toBe(3)
  })

  it('un producto comprado y regalado (promo que mueve stock) suma las dos líneas', () => {
    const r = cantidadesQueDescuentanStock([
      { productoId: 'naranja', cantidad: 48 },
      { productoId: 'naranja', cantidad: 12, esBonificacion: true, regaloMueveStock: true },
    ])
    expect(r.get('naranja')).toBe(60)
  })

  it('dos líneas de regalo de la misma promo repartida en sabores suman por producto', () => {
    const r = cantidadesQueDescuentanStock([
      { productoId: 'manzana', cantidad: 40 },
      { productoId: 'naranja', cantidad: 12, esBonificacion: true, regaloMueveStock: true },
      { productoId: 'manzana', cantidad: 12, esBonificacion: true, regaloMueveStock: true },
    ])
    expect(r.get('manzana')).toBe(52)
    expect(r.get('naranja')).toBe(12)
  })

  it('un regalo cuya promo NO mueve stock (fracción) no suma', () => {
    const r = cantidadesQueDescuentanStock([
      { productoId: 'naranja', cantidad: 48 },
      { productoId: 'naranja', cantidad: 12, esBonificacion: true, regaloMueveStock: false },
    ])
    expect(r.get('naranja')).toBe(48)
  })

  it('un regalo sin dato de la promo no suma: igual que el servidor, que lo toma como false', () => {
    const r = cantidadesQueDescuentanStock([
      { productoId: 'naranja', cantidad: 12, esBonificacion: true },
      { productoId: 'manzana', cantidad: 6, esBonificacion: true },
    ])
    expect(r.get('naranja') ?? 0).toBe(0)
    expect(r.get('manzana') ?? 0).toBe(0)
  })

  it('ignora cantidades no positivas o no numéricas', () => {
    const r = cantidadesQueDescuentanStock([
      { productoId: 'a', cantidad: 0 },
      { productoId: 'a', cantidad: -4 },
      { productoId: 'a', cantidad: Number.NaN },
      { productoId: 'a', cantidad: 7 },
    ])
    expect(r.get('a')).toBe(7)
  })

  it('el id numérico y el string del mismo producto son el mismo producto', () => {
    const r = cantidadesQueDescuentanStock([
      { productoId: '7', cantidad: 2 },
      { productoId: 7 as unknown as string, cantidad: 3 },
    ])
    expect(r.get('7')).toBe(5)
  })
})

describe('indexarRegaloMueveStock', () => {
  const promo = (id: string, regaloMueveStock?: boolean): PromocionActiva => ({
    id, nombre: id, tipo: 'bonificacion', productoIds: ['a'], reglas: {}, regaloMueveStock,
  })

  it('indexa por id de promo, sin importar por cuántos productos aparezca', () => {
    const p1 = promo('1', true)
    const p2 = promo('2', false)
    const promoMap: PromoMap = new Map([
      ['a', [p1, p2]],
      ['b', [p1]],
    ])
    const r = indexarRegaloMueveStock(promoMap)
    expect(r.get('1')).toBe(true)
    expect(r.get('2')).toBe(false)
  })

  it('una promo sin la bandera cuenta como false', () => {
    const r = indexarRegaloMueveStock(new Map([['a', [promo('3')]]]))
    expect(r.get('3')).toBe(false)
  })

  it('sin promociones devuelve un índice vacío', () => {
    expect(indexarRegaloMueveStock(undefined).size).toBe(0)
  })
})
