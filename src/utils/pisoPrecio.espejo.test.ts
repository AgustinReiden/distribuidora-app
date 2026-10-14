import { describe, it, expect } from 'vitest'
import fixture from './pisoPrecio.espejo.json'
import { orquestarPrecios } from './orquestacionPrecios'
import type { EscalaPrecio, GrupoPrecioInfo, ItemPedido, PricingMap } from './precioMayorista'
import type { PromoMap, PromocionActiva } from './promociones'

/**
 * PARIDAD DEL PISO DE PRECIO (#1139), lado TypeScript.
 *
 * Para quien no es admin, `crear_pedido_completo` y `actualizar_pedido_items`
 * rechazan una línea de venta por debajo de `precio_piso_linea()` - 0,01: lista o
 * escala aplicable menos el descuento del cliente. El piso es PERMISIVO a
 * propósito: evalúa las escalas sobre todas las líneas de venta (el front saca
 * las que reclamó una promo), omite la regla 2 de `escalaAplica` y toma la
 * escala más barata de las que aplican. El invariante es que el server nunca
 * rechace lo que cobra el front: este archivo corre `orquestarPrecios` sobre los
 * casos de `pisoPrecio.espejo.json` y exige que su precio no quede por debajo de
 * `esperado` - 0,01, e igual a `esperado` en los casos `exacto`.
 * `scripts/espejo-piso-precio.mjs` corre el SQL contra el mismo `esperado`, en
 * el gate de integridad. Si cambia uno, cambia el otro y se suma el caso.
 */

interface ItemEspejo {
  producto_id: number
  cantidad: number
  precio_unitario: number
  es_bonificacion?: boolean
}

interface EscalaEspejo {
  cantidad_minima: number
  precio_unitario: number
  min_productos_distintos: number
  minimos: { producto_id: number; cantidad_minima_por_item: number; precio_unitario_override: number | null }[]
}

interface CasoEspejo {
  caso: string
  items: ItemEspejo[]
  grupos: { grupo_id: number; productos: number[]; escalas: EscalaEspejo[] }[]
  promo?: { productos: number[]; compra: number; bonif: number; regalo: number }
  cliente: { descuento_porcentaje: number; descuentos_categoria: { categoria: string; descuento_porcentaje: number }[] }
  categorias: Record<string, string>
  producto_id: number
  lista: number
  esperado: number | null
  exacto: boolean
}

const casos = fixture.casos as unknown as CasoEspejo[]

// La tolerancia del server (precio_fuera_de_politica): precio >= piso - 0,01.
const TOLERANCIA = 0.01
const EPS = 1e-9

function pricingMapDe(c: CasoEspejo): PricingMap {
  const map: PricingMap = new Map()
  for (const g of c.grupos) {
    const escalas: EscalaPrecio[] = g.escalas.map(e => ({
      cantidadMinima: e.cantidad_minima,
      precioUnitario: e.precio_unitario,
      etiqueta: null,
      minProductosDistintos: e.min_productos_distintos,
      minimosPorProducto: new Map(e.minimos.map(m => [
        String(m.producto_id),
        { cantidad: m.cantidad_minima_por_item, precioOverride: m.precio_unitario_override },
      ])),
    }))
    const info: GrupoPrecioInfo = {
      grupoId: String(g.grupo_id),
      grupoNombre: `grupo ${g.grupo_id}`,
      escalas,
      productoIds: g.productos.map(String),
    }
    for (const p of g.productos) {
      const lista = map.get(String(p)) ?? []
      lista.push(info)
      map.set(String(p), lista)
    }
  }
  return map
}

function promoMapDe(c: CasoEspejo): PromoMap | null {
  if (!c.promo) return null
  const promo: PromocionActiva = {
    id: '1',
    nombre: 'espejo',
    tipo: 'bonificacion',
    productoIds: c.promo.productos.map(String),
    reglas: { cantidad_compra: c.promo.compra, cantidad_bonificacion: c.promo.bonif },
    productoRegaloId: String(c.promo.regalo),
  }
  return new Map(c.promo.productos.map(p => [String(p), [promo]]))
}

/** El precio que el front le pone al producto evaluado. */
function precioFront(c: CasoEspejo): number {
  // El front arma la venta con la lista de cada producto; los regalos los
  // genera la promo, no entran como input.
  const items: ItemPedido[] = c.items
    .filter(i => !i.es_bonificacion)
    .map(i => ({ productoId: String(i.producto_id), cantidad: i.cantidad, precioUnitario: i.precio_unitario }))
  const productos = [...new Set(c.items.map(i => i.producto_id))]
    .map(id => ({ id: String(id), categoria: c.categorias[String(id)] ?? null }))
  const r = orquestarPrecios({
    items,
    promoMap: promoMapDe(c),
    pricingMap: pricingMapDe(c),
    productos,
    cliente: c.cliente,
  })
  const linea = r.items.find(i => !i.esBonificacion && i.productoId === String(c.producto_id))
  if (!linea) throw new Error(`el front no devolvió la línea del producto ${c.producto_id}`)
  return linea.precioUnitario
}

describe('Paridad del piso de precio (TS contra el fixture compartido con el SQL)', () => {
  const conPiso = casos.filter(c => c.esperado !== null)

  it.each(conPiso.map(c => [c.caso, c] as const))('%s: el front nunca cobra menos que el piso', (_n, c) => {
    expect(precioFront(c)).toBeGreaterThanOrEqual((c.esperado as number) - TOLERANCIA - EPS)
  })

  it.each(conPiso.filter(c => c.exacto).map(c => [c.caso, c] as const))('%s: el piso es el precio del front', (_n, c) => {
    expect(precioFront(c)).toBeCloseTo(c.esperado as number, 6)
  })

  it('sin piso solo cuando no hay lista (el server rechaza)', () => {
    for (const c of casos.filter(x => x.esperado === null)) {
      expect(c.lista).toBeLessThanOrEqual(0)
    }
  })

  it('los casos tienen nombres únicos (el script del SQL los reporta por nombre)', () => {
    const nombres = casos.map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })

  it('la lista de cada caso es el precio con que el front manda el producto', () => {
    for (const c of casos) {
      const item = c.items.find(i => !i.es_bonificacion && i.producto_id === c.producto_id)
      expect(item?.precio_unitario).toBe(c.lista)
    }
  })
})
