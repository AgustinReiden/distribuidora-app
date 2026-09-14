/**
 * Escenarios compartidos para testear `orquestarPrecios`.
 *
 * Vive acá —y no adentro de un `.test.ts`— porque lo consumen las DOS suites:
 * la de vitest (`orquestacionPrecios.test.ts`) y la de Deno
 * (`supabase/functions/tests/orquestacion_precios.test.ts`). El archivo está
 * sincronizado byte a byte igual que los utils (ver `tests/sync_utils.test.ts`):
 * si los casos se escribieran dos veces, las dos suites podrían pasar mientras
 * app y bot cobran totales distintos, que es exactamente el bug que esto cuida.
 */

import type { ItemPedido, PricingMap, GrupoPrecioInfo } from './precioMayorista'
import type { PromoMap, PromocionActiva } from './promociones'
import type { ClienteConDescuentos, ProductoConCategoria } from './descuentoCliente'
import type { OrquestacionPreciosInput } from './orquestacionPrecios'

// =============================================================================
// HELPERS
// =============================================================================

/** Los totales se comparan redondeados: 28.33 * 3 da 84.99000000000001 en JS. */
export function redondear2(n: number): number {
  return Math.round(n * 100) / 100
}

export function pricingMapDe(grupos: GrupoPrecioInfo[]): PricingMap {
  const map: PricingMap = new Map()
  for (const grupo of grupos) {
    for (const pid of grupo.productoIds) {
      const arr = map.get(pid) ?? []
      arr.push(grupo)
      map.set(pid, arr)
    }
  }
  return map
}

export function promoMapDe(promos: PromocionActiva[]): PromoMap {
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

// =============================================================================
// CATÁLOGO
// =============================================================================

export const PRODUCTOS: ProductoConCategoria[] = [
  { id: '1', categoria: 'GASEOSAS' },
  { id: '2', categoria: 'GASEOSAS' },
  { id: '3', categoria: 'AGUAS' },
  { id: '4', categoria: 'VARIOS' },
]

/** Condición mayorista "fardo surtido": cualquier mezcla de 1 y 2 suma. */
function grupoGaseosas(cantidadMinima: number): GrupoPrecioInfo {
  return {
    grupoId: 'g1',
    grupoNombre: 'Gaseosas 600cc',
    productoIds: ['1', '2'],
    escalas: [
      {
        escalaId: 'e1',
        cantidadMinima,
        precioUnitario: 80,
        etiqueta: 'Fardo',
        minProductosDistintos: 1,
        minimosPorProducto: new Map(),
      },
    ],
  }
}

function promoBonificacion(cantidadCompra: number): PromocionActiva {
  return {
    id: '77',
    nombre: 'Promo Cola',
    tipo: 'bonificacion',
    productoIds: ['1'],
    reglas: { cantidad_compra: cantidadCompra, cantidad_bonificacion: 1 },
    productoRegaloId: '4',
  }
}

/** Cliente con 10% general y la categoría AGUAS excluida (0% explícito). */
const CLIENTE_10_CON_AGUAS_EXCLUIDAS: ClienteConDescuentos = {
  descuento_porcentaje: 10,
  descuentos_categoria: [{ categoria: 'Aguas', descuento_porcentaje: 0 }],
}

// =============================================================================
// ESCENARIOS
// =============================================================================

export interface EscenarioOrquestacion {
  nombre: string
  input: OrquestacionPreciosInput
  esperado: {
    totalOriginal: number
    totalSinDescuentoCliente: number
    total: number
    /** productoIds reclamados por una promo que efectivamente disparó. */
    productosConPromo: string[]
    bonificaciones: Array<{ productoId: string; cantidad: number }>
    /** Precio unitario final (post descuento) por productoId, sin bonificaciones. */
    precioFinalPorProducto: Record<string, number>
  }
}

const items = (...defs: Array<[string, number, number, boolean?]>): ItemPedido[] =>
  defs.map(([productoId, cantidad, precioUnitario, precioOverride]) => ({
    productoId,
    cantidad,
    precioUnitario,
    ...(precioOverride ? { precioOverride: true } : {}),
  }))

export const ESCENARIOS: EscenarioOrquestacion[] = [
  {
    // La regresión: la promo NO llega al umbral (6 de 20), así que el producto 1
    // no queda reclamado. Toma precio mayorista Y su cantidad le sigue sumando
    // la escala al producto 2 (12 >= 10). Antes, el producto 1 salía del grupo y
    // los dos sabores se quedaban sin escala.
    nombre: 'promo que no dispara: el disparador conserva mayorista y sigue sumando al grupo',
    input: {
      items: items(['1', 6, 100], ['2', 6, 100]),
      promoMap: promoMapDe([promoBonificacion(20)]),
      pricingMap: pricingMapDe([grupoGaseosas(10)]),
      productos: PRODUCTOS,
      cliente: null,
    },
    esperado: {
      totalOriginal: 1200,
      totalSinDescuentoCliente: 960,
      total: 960,
      productosConPromo: [],
      bonificaciones: [],
      precioFinalPorProducto: { '1': 80, '2': 80 },
    },
  },
  {
    // El pedido completo: promo → mayorista → descuento del cliente.
    //   1: promo (6/6) → queda a lista 100 → −10% = 90
    //   2: mayorista (6 >= 5) → 80 → −10% = 72
    //   3: sin grupo → 50, y AGUAS está en 0% → queda en 50
    //   4: regalo, precio 0, no se toca
    nombre: 'promo + mayorista + descuento del cliente (categoría en 0% excluye del general)',
    input: {
      items: items(['1', 6, 100], ['2', 6, 100], ['3', 2, 50]),
      promoMap: promoMapDe([promoBonificacion(6)]),
      pricingMap: pricingMapDe([grupoGaseosas(5)]),
      productos: PRODUCTOS,
      cliente: CLIENTE_10_CON_AGUAS_EXCLUIDAS,
    },
    esperado: {
      totalOriginal: 1300,
      totalSinDescuentoCliente: 1180,
      total: 1072,
      productosConPromo: ['1'],
      bonificaciones: [{ productoId: '4', cantidad: 1 }],
      precioFinalPorProducto: { '1': 90, '2': 72, '3': 50 },
    },
  },
  {
    // El precio tipeado a mano gana sobre las tres capas, pero su cantidad
    // sigue contando para la escala del resto del grupo (10 + 2 >= 5).
    nombre: 'precioOverride: ni mayorista ni descuento del cliente lo tocan',
    input: {
      items: items(['1', 10, 95, true], ['2', 2, 100]),
      promoMap: promoMapDe([]),
      pricingMap: pricingMapDe([grupoGaseosas(5)]),
      productos: PRODUCTOS,
      cliente: { descuento_porcentaje: 10 },
    },
    esperado: {
      totalOriginal: 1150,
      totalSinDescuentoCliente: 1110,
      total: 1094,
      productosConPromo: [],
      bonificaciones: [],
      precioFinalPorProducto: { '1': 95, '2': 72 },
    },
  },
  {
    // Redondeo a 2 decimales: 33.33 − 15% = 28.3305 → 28.33.
    nombre: 'descuento general con redondeo a 2 decimales',
    input: {
      items: items(['3', 3, 33.33]),
      promoMap: promoMapDe([]),
      pricingMap: pricingMapDe([]),
      productos: PRODUCTOS,
      cliente: { descuento_porcentaje: 15 },
    },
    esperado: {
      totalOriginal: 99.99,
      totalSinDescuentoCliente: 99.99,
      total: 84.99,
      productosConPromo: [],
      bonificaciones: [],
      precioFinalPorProducto: { '3': 28.33 },
    },
  },
]
