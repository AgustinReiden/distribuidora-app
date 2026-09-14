/**
 * Tests de resolverPromociones — foco en `promosEliminadas` (quitar promo a mano
 * al crear/editar un pedido).
 */
import { describe, it, expect } from 'vitest'
import { resolverPromociones, type PromocionActiva, type PromoMap } from './promociones'
import type { ItemPedido } from './precioMayorista'

function promoMapDe(promos: PromocionActiva[]): PromoMap {
  const map: PromoMap = new Map()
  for (const promo of promos) {
    for (const pid of promo.productoIds) {
      const arr = map.get(pid) ?? []
      arr.push(promo)
      map.set(pid, arr)
    }
  }
  return map
}

const promo2x1: PromocionActiva = {
  id: '77',
  nombre: 'Promo 2+1',
  tipo: 'bonificacion',
  productoIds: ['10'],
  reglas: { cantidad_compra: 2, cantidad_bonificacion: 1 },
  productoRegaloId: '10',
}

const items: ItemPedido[] = [{ productoId: '10', cantidad: 4, precioUnitario: 100 }]

describe('resolverPromociones · promosEliminadas', () => {
  it('sin eliminar: la promo dispara (bonificación + producto reclamado)', () => {
    const r = resolverPromociones(items, promoMapDe([promo2x1]))
    expect(r.bonificaciones).toHaveLength(1)
    expect(r.bonificaciones[0].promoId).toBe('77')
    expect(r.bonificaciones[0].cantidadBonificacion).toBe(2) // floor(4/2) * 1
    expect(r.productosConPromo.has('10')).toBe(true)
  })

  it('con la promo en promosEliminadas: desaparece por completo', () => {
    const r = resolverPromociones(items, promoMapDe([promo2x1]), new Set(['77']))
    expect(r.bonificaciones).toHaveLength(0)
    expect(r.productosConPromo.has('10')).toBe(false)
  })

  it('un set vacío o con otros ids no afecta la resolución', () => {
    const r = resolverPromociones(items, promoMapDe([promo2x1]), new Set(['999']))
    expect(r.bonificaciones).toHaveLength(1)
    expect(r.productosConPromo.has('10')).toBe(true)
  })
})

describe('resolverPromociones · productosConPromo sale de las promos que DISPARAN', () => {
  const promo20x1: PromocionActiva = {
    id: '88',
    nombre: 'Promo 20+1',
    tipo: 'bonificacion',
    productoIds: ['10', '11'],
    reglas: { cantidad_compra: 20, cantidad_bonificacion: 1 },
    productoRegaloId: '99',
  }

  it('si no llega al umbral, no reclama ningún producto', () => {
    // 6 + 6 = 12 < 20. La promo existe y es vigente, pero no se usa: sus
    // disparadores tienen que seguir libres para tomar precio mayorista.
    const r = resolverPromociones(
      [
        { productoId: '10', cantidad: 6, precioUnitario: 100 },
        { productoId: '11', cantidad: 6, precioUnitario: 100 },
      ],
      promoMapDe([promo20x1]),
    )
    expect(r.bonificaciones).toHaveLength(0)
    expect(r.productosConPromo.size).toBe(0)
  })

  it('si llega al umbral, reclama todos sus disparadores presentes en el pedido', () => {
    const r = resolverPromociones(
      [
        { productoId: '10', cantidad: 10, precioUnitario: 100 },
        { productoId: '11', cantidad: 10, precioUnitario: 100 },
      ],
      promoMapDe([promo20x1]),
    )
    expect(r.bonificaciones).toHaveLength(1)
    expect([...r.productosConPromo].sort()).toEqual(['10', '11'])
  })

  it('una excluyente que pierde el conflicto no reclama productos propios', () => {
    // 3+1 (tier alto) gana sobre 2+1 en el producto compartido '10'. La
    // perdedora también toca '12', que no debe quedar reclamado por ella.
    const ganadora: PromocionActiva = {
      id: '1',
      nombre: '3+1',
      tipo: 'bonificacion',
      productoIds: ['10'],
      reglas: { cantidad_compra: 3, cantidad_bonificacion: 1 },
      modoExclusion: 'excluyente',
      productoRegaloId: '10',
    }
    const perdedora: PromocionActiva = {
      id: '2',
      nombre: '2+1',
      tipo: 'bonificacion',
      productoIds: ['10', '12'],
      reglas: { cantidad_compra: 2, cantidad_bonificacion: 1 },
      modoExclusion: 'excluyente',
      productoRegaloId: '12',
    }
    const r = resolverPromociones(
      [
        { productoId: '10', cantidad: 6, precioUnitario: 100 },
        { productoId: '12', cantidad: 1, precioUnitario: 100 },
      ],
      promoMapDe([ganadora, perdedora]),
    )
    expect(r.bonificaciones.map(b => b.promoId)).toEqual(['1'])
    expect([...r.productosConPromo]).toEqual(['10'])
  })
})
