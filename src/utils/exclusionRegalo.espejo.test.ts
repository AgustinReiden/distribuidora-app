import { describe, it, expect } from 'vitest'
import fixture from './exclusionRegalo.espejo.json'
import { resolverPromociones, type PromoMap, type PromocionActiva, type ModoExclusion } from './promociones'
import type { ItemPedido } from './precioMayorista'

/**
 * PARIDAD DE LA EXCLUSIÓN ENTRE PROMOS EXCLUYENTES (#1136), lado TypeScript.
 *
 * El front elige, por cada grupo de promos excluyentes que comparten productos
 * del pedido, una sola ganadora (`resolverConflictosExcluyentes`, dentro de
 * `resolverPromociones`). El usuario puede quitar promos a mano, así que lo que
 * el front puede llegar a regalar es cualquier conjunto que salga de quitar
 * algunas. El server no replica el union-find: rechaza el regalo de dos
 * excluyentes que comparten el producto de una línea de venta
 * (`regalo_excluyentes_en_conflicto`, que llama `regalo_fuera_de_promo`).
 *
 * Las dos tienen que coincidir: un conjunto de promos con regalo es alcanzable
 * desde el front si y solo si el server no encuentra un par en conflicto. Este
 * archivo prueba el lado del front recorriendo todos los subconjuntos de promos
 * quitadas, contra el `conflicto` escrito a mano en `exclusionRegalo.espejo.json`;
 * `scripts/espejo-exclusion-regalo.mjs` prueba el SQL contra el mismo fixture,
 * en el gate de integridad.
 *
 * El front calcula los regalos con las líneas de VENTA (`ItemPedido` no tiene
 * `es_bonificacion`), así que acá se filtran las bonificadas; el SQL recibe
 * todas y las ignora adentro.
 */

interface ItemEspejo {
  producto_id: number
  cantidad: number
  precio_unitario: number
  es_bonificacion?: boolean
  promocion_id?: number
  precio_override?: boolean
}

interface PromoEspejo {
  id: number
  productos: number[]
  compra: number
  bonif: number
  modo: ModoExclusion
  prioridad: number
}

interface CasoEspejo {
  caso: string
  items: ItemEspejo[]
  promos: PromoEspejo[]
  regalan: number[]
  conflicto: [number, number] | null
}

const casos = fixture.casos as unknown as CasoEspejo[]

function promoMapDe(c: CasoEspejo): PromoMap {
  const map: PromoMap = new Map()
  for (const p of c.promos) {
    const promo: PromocionActiva = {
      id: String(p.id),
      nombre: `espejo ${p.id}`,
      tipo: 'bonificacion',
      productoIds: p.productos.map(String),
      reglas: { cantidad_compra: p.compra, cantidad_bonificacion: p.bonif },
      productoRegaloId: '999',
      prioridad: p.prioridad,
      modoExclusion: p.modo,
    }
    for (const prod of p.productos) {
      const lista = map.get(String(prod)) ?? []
      lista.push(promo)
      map.set(String(prod), lista)
    }
  }
  return map
}

function ventasDe(c: CasoEspejo): ItemPedido[] {
  return c.items
    .filter(i => !i.es_bonificacion)
    .map(i => ({
      productoId: String(i.producto_id),
      cantidad: i.cantidad,
      precioUnitario: i.precio_unitario,
      precioOverride: i.precio_override,
    }))
}

/** ¿Hay algún conjunto de promos quitadas a mano con el que el front regala exactamente `regalan`? */
function alcanzableDesdeElFront(c: CasoEspejo): boolean {
  const map = promoMapDe(c)
  const ventas = ventasDe(c)
  const ids = c.promos.map(p => String(p.id))
  const buscado = [...c.regalan].map(String).sort().join(',')
  for (let mask = 0; mask < 1 << ids.length; mask++) {
    const quitadas = new Set(ids.filter((_, i) => (mask >> i) & 1))
    const regaladas = resolverPromociones(ventas, map, quitadas).bonificaciones
      .filter(b => b.cantidadBonificacion > 0)
      .map(b => b.promoId)
    if ([...new Set(regaladas)].sort().join(',') === buscado) return true
  }
  return false
}

describe('Paridad de la exclusión de regalos (TS contra el fixture compartido con el SQL)', () => {
  it.each(casos.map(c => [c.caso, c] as const))('%s', (_nombre, c) => {
    expect(alcanzableDesdeElFront(c)).toBe(c.conflicto === null)
  })

  it('todas las promos que regalan disparan con las líneas de venta (regla 1 del fixture)', () => {
    for (const c of casos) {
      const map = promoMapDe(c)
      const ventas = ventasDe(c)
      for (const id of c.regalan) {
        const otras = new Set(c.promos.map(p => String(p.id)).filter(x => x !== String(id)))
        const sola = resolverPromociones(ventas, map, otras).bonificaciones.find(b => b.promoId === String(id))
        expect(sola?.cantidadBonificacion ?? 0, `${c.caso}: la promo ${id} no dispara`).toBeGreaterThan(0)
      }
    }
  })

  it('los casos tienen nombres únicos (el script del SQL los reporta por nombre)', () => {
    const nombres = casos.map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })

  it('a lo sumo 5 promos por caso (el test recorre 2^n subconjuntos)', () => {
    for (const c of casos) expect(c.promos.length).toBeLessThanOrEqual(5)
  })
})
