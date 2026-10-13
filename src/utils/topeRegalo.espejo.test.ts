import { describe, it, expect } from 'vitest'
import fixture from './topeRegalo.espejo.json'
import { resolverPromociones, type PromoMap, type PromocionActiva } from './promociones'
import type { ItemPedido } from './precioMayorista'

/**
 * PARIDAD DEL TOPE DE REGALO DE UNA PROMO (#1123), lado TypeScript.
 *
 * La fórmula está escrita dos veces: `resolverPromociones()` acá (lo que el
 * front le regala al pedido) y `regalo_tope_promo()` en el server, con la que
 * `crear_pedido_completo` y `actualizar_pedido_items` limitan el regalo de quien
 * no es admin. Las dos corren los MISMOS casos de `topeRegalo.espejo.json`
 * contra el mismo resultado esperado, escrito a mano: este archivo el TS, y
 * `scripts/espejo-tope-regalo.mjs` el SQL, en el gate de integridad, donde hay
 * credenciales. Si una de las dos cambia la fórmula sin la otra, su lado se
 * pone rojo.
 *
 * El front calcula el regalo con las líneas de VENTA (los regalos no entran a
 * resolverPromociones), así que acá se filtran las bonificadas; el SQL recibe
 * todas y las saltea adentro.
 */

interface ItemEspejo {
  producto_id: number
  cantidad: number
  precio_unitario: number
  es_bonificacion?: boolean
  precio_override?: boolean
}

interface CasoEspejo {
  caso: string
  items: ItemEspejo[]
  productos: number[]
  compra: number | null
  bonif: number | null
  esperado: number
}

const casos = fixture.casos as unknown as CasoEspejo[]

function topeTs(c: CasoEspejo): number {
  const reglas: Record<string, number> = {}
  if (c.compra != null) reglas['cantidad_compra'] = c.compra
  if (c.bonif != null) reglas['cantidad_bonificacion'] = c.bonif
  const promo: PromocionActiva = {
    id: '1',
    nombre: 'espejo',
    tipo: 'bonificacion',
    productoIds: c.productos.map(String),
    reglas,
    productoRegaloId: '999',
  }
  const promoMap: PromoMap = new Map(c.productos.map(p => [String(p), [promo]]))
  const items: ItemPedido[] = c.items
    .filter(i => !i.es_bonificacion)
    .map(i => ({
      productoId: String(i.producto_id),
      cantidad: i.cantidad,
      precioUnitario: i.precio_unitario,
      precioOverride: i.precio_override,
    }))
  const bonif = resolverPromociones(items, promoMap).bonificaciones.find(b => b.promoId === '1')
  return bonif?.cantidadBonificacion ?? 0
}

describe('Paridad del tope de regalo (TS contra el fixture compartido con el SQL)', () => {
  it.each(casos.map(c => [c.caso, c] as const))('%s', (_nombre, c) => {
    expect(topeTs(c)).toBe(c.esperado)
  })

  it('los casos tienen nombres únicos (el script del SQL los reporta por nombre)', () => {
    const nombres = casos.map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })
})
