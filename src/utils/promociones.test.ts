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
