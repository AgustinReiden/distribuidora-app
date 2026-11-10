/**
 * PRM-2 (#1515): las promos que dispararían con las líneas de un pedido guardado pero de las que
 * el pedido no tiene regalo. El modal las arranca quitadas: un pedido que ya existe no gana un
 * regalo que no tenía.
 */
import { describe, it, expect } from 'vitest'
import { promosSinRegaloEnElPedido } from './promosSinRegalo'
import type { PromoMap, PromocionActiva } from './promociones'
import type { ItemPedido } from './precioMayorista'

function promo(id: string, nombre: string, productoIds: string[], compra = 6, bonif = 2): PromocionActiva {
  return {
    id,
    nombre,
    tipo: 'bonificacion',
    productoIds,
    reglas: { cantidad_compra: compra, cantidad_bonificacion: bonif },
    productoRegaloId: '99',
    prioridad: 0,
    regaloMueveStock: true,
    modoExclusion: 'acumulable',
  }
}

function mapaDe(...promos: PromocionActiva[]): PromoMap {
  const m: PromoMap = new Map()
  for (const p of promos) {
    for (const pid of p.productoIds) m.set(pid, [...(m.get(pid) ?? []), p])
  }
  return m
}

const linea = (productoId: string, cantidad: number): ItemPedido => ({ productoId, cantidad, precioUnitario: 100 })

describe('promosSinRegaloEnElPedido', () => {
  const p13 = promo('13', 'Promo 6 + 2', ['1', '2'])

  it('sin promoMap devuelve []', () => {
    expect(promosSinRegaloEnElPedido([linea('1', 10)], undefined, [])).toEqual([])
  })

  it('sin ítems de venta devuelve []', () => {
    expect(promosSinRegaloEnElPedido([], mapaDe(p13), [])).toEqual([])
  })

  it('una promo que dispara y de la que el pedido no tiene regalo se devuelve con su nombre', () => {
    expect(promosSinRegaloEnElPedido([linea('1', 6)], mapaDe(p13), [])).toEqual([
      { promoId: '13', promoNombre: 'Promo 6 + 2' },
    ])
  })

  it('una promo que dispara y de la que el pedido sí tiene regalo no se devuelve', () => {
    expect(promosSinRegaloEnElPedido([linea('1', 6)], mapaDe(p13), ['13'])).toEqual([])
  })

  it('compara los ids como texto: el promocion_id de la base llega como número', () => {
    expect(promosSinRegaloEnElPedido([linea('1', 6)], mapaDe(p13), [13 as unknown as string])).toEqual([])
  })

  it('una promo que no llega a cantidad_compra no se devuelve', () => {
    expect(promosSinRegaloEnElPedido([linea('1', 5)], mapaDe(p13), [])).toEqual([])
  })

  it('dos líneas que disparan la misma promo la devuelven una sola vez', () => {
    const r = promosSinRegaloEnElPedido([linea('1', 3), linea('2', 3)], mapaDe(p13), [])
    expect(r).toEqual([{ promoId: '13', promoNombre: 'Promo 6 + 2' }])
  })

  it('con varias promos devuelve sólo las que el pedido no tiene', () => {
    const p14 = promo('14', 'Promo 3 + 1', ['3'], 3, 1)
    const r = promosSinRegaloEnElPedido([linea('1', 6), linea('3', 3)], mapaDe(p13, p14), ['14'])
    expect(r).toEqual([{ promoId: '13', promoNombre: 'Promo 6 + 2' }])
  })
})
