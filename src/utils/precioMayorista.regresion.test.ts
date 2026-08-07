/**
 * Regresión con las condiciones REALES de producción (leídas el 2026-08-06).
 *
 * Existe para responder una sola pregunta: después de sacar el mínimo de la
 * condición, mover el panel a Productos y agregar el asistente de fusión,
 * ¿el preventista sigue viendo exactamente los mismos precios que antes?
 *
 * Los números de acá NO son inventados: son los grupos 1, 2, 37, 54, 61 y 62
 * tal como están cargados hoy. Si alguien toca el motor de precios y cambia lo
 * que se le cobra a un cliente, estos casos fallan.
 *
 * Nota sobre el grupo 1 (PAPAS SABORIZADAS): es la prueba de que la suma entre
 * productos ya funcionaba antes de todo este trabajo. Lo que faltaba era poder
 * armar condiciones así sin fricción.
 */
import { describe, it, expect } from 'vitest'
import { resolverPreciosMayorista } from './precioMayorista'
import type { GrupoPrecioInfo, PricingMap, EscalaPrecio, ItemPedido } from './precioMayorista'

function escala(cantidadMinima: number, precioUnitario: number): EscalaPrecio {
  return {
    cantidadMinima,
    precioUnitario,
    etiqueta: null,
    minProductosDistintos: 1,
    minimosPorProducto: new Map(),
  }
}

function grupo(
  grupoId: string,
  grupoNombre: string,
  productoIds: string[],
  escalas: EscalaPrecio[],
): GrupoPrecioInfo {
  return { grupoId, grupoNombre, escalas, productoIds }
}

/** Las condiciones tal cual están en prod. */
const GRUPOS: GrupoPrecioInfo[] = [
  // 3 sabores de papas a $2450 que YA suman entre sí: desde 18 → $2350.
  grupo('1', 'PAPAS SABORIZADAS', ['102', '103', '104'], [escala(18, 2350)]),
  // El mismo producto (101, lista $13200) repartido en dos condiciones.
  grupo('2', 'CAJA PAPAS 1 KG', ['101'], [escala(5, 13000)]),
  grupo('54', 'PAPA FACU 1 KG', ['101'], [escala(15, 12700)]),
  // 2 sabores de Alfatuc a $5800: desde 2 → $5600.
  grupo('37', 'Alfatuc Mayorista', ['156', '157'], [escala(2, 5600)]),
  // Codito (lista $920) en dos condiciones: ½ fardo y fardo.
  grupo('62', 'CODITO 1/2 FARDO', ['140'], [escala(6, 890)]),
  grupo('61', 'FIDEO X FARDO', ['140'], [escala(12, 850)]),
]

const PRICING_MAP: PricingMap = (() => {
  const map: PricingMap = new Map()
  for (const g of GRUPOS) {
    for (const pid of g.productoIds) {
      map.set(pid, [...(map.get(pid) ?? []), g])
    }
  }
  return map
})()

const LISTA: Record<string, number> = {
  '101': 13200, '102': 2450, '103': 2450, '104': 2450,
  '140': 920, '156': 5800, '157': 5800,
}

function item(productoId: string, cantidad: number): ItemPedido {
  return { productoId, cantidad, precioUnitario: LISTA[productoId] }
}

/** Precio que termina pagando cada producto del pedido. */
function precios(items: ItemPedido[]): Record<string, number> {
  const resueltos = resolverPreciosMayorista(items, PRICING_MAP)
  const salida: Record<string, number> = {}
  for (const it of items) {
    salida[it.productoId] = resueltos.get(it.productoId)?.precioResuelto ?? it.precioUnitario
  }
  return salida
}

describe('regresión con las condiciones reales de producción', () => {
  describe('PAPAS SABORIZADAS — 3 sabores que suman entre sí (grupo 1)', () => {
    it('6+6+6 de sabores distintos llega a 18 y los tres pagan $2350', () => {
      // Esto ya funcionaba antes de todo el trabajo: los 3 sabores comparten
      // condición. Es exactamente lo que NO pasaba con los fideos, porque cada
      // sabor tenía condición propia.
      expect(precios([item('102', 6), item('103', 6), item('104', 6)])).toEqual({
        '102': 2350, '103': 2350, '104': 2350,
      })
    })

    it('17 en total no alcanza: los tres pagan lista', () => {
      expect(precios([item('102', 6), item('103', 6), item('104', 5)])).toEqual({
        '102': 2450, '103': 2450, '104': 2450,
      })
    })

    it('18 de un solo sabor también activa la escala', () => {
      expect(precios([item('102', 18)])['102']).toBe(2350)
    })
  })

  describe('PAPAS FRITAS X 1KG — un producto en dos condiciones (grupos 2 y 54)', () => {
    it('4 unidades: no llega a ninguna, paga lista', () => {
      expect(precios([item('101', 4)])['101']).toBe(13200)
    })

    it('5 unidades: entra la de 5 → $13000', () => {
      expect(precios([item('101', 5)])['101']).toBe(13000)
    })

    it('14 unidades: sigue en $13000, la de 15 todavía no', () => {
      expect(precios([item('101', 14)])['101']).toBe(13000)
    })

    it('15 unidades: gana la más barata de las dos → $12700', () => {
      expect(precios([item('101', 15)])['101']).toBe(12700)
    })
  })

  describe('CODITO COTELLA — ½ fardo y fardo en condiciones separadas (62 y 61)', () => {
    it('5 unidades: paga lista', () => {
      expect(precios([item('140', 5)])['140']).toBe(920)
    })

    it('6 unidades: ½ fardo → $890', () => {
      expect(precios([item('140', 6)])['140']).toBe(890)
    })

    it('11 unidades: sigue en ½ fardo', () => {
      expect(precios([item('140', 11)])['140']).toBe(890)
    })

    it('12 unidades: fardo → $850', () => {
      expect(precios([item('140', 12)])['140']).toBe(850)
    })

    it('consolidar las dos condiciones da el MISMO precio en cada tramo', () => {
      // Lo que haría el asistente: una condición con las dos escalas.
      const unificada = grupo('99', 'CODITO COTELLA', ['140'], [escala(6, 890), escala(12, 850)])
      const mapa: PricingMap = new Map([['140', [unificada]]])
      const conUnaSola = (cantidad: number) =>
        resolverPreciosMayorista([item('140', cantidad)], mapa).get('140')?.precioResuelto

      expect(conUnaSola(5)).toBe(920)
      expect(conUnaSola(6)).toBe(890)
      expect(conUnaSola(11)).toBe(890)
      expect(conUnaSola(12)).toBe(850)
    })
  })

  describe('ALFATUC — 2 sabores desde 2 unidades (grupo 37)', () => {
    it('1 de cada sabor suma 2 y los dos pagan $5600', () => {
      expect(precios([item('156', 1), item('157', 1)])).toEqual({ '156': 5600, '157': 5600 })
    })

    it('1 solo no alcanza', () => {
      expect(precios([item('156', 1)])['156']).toBe(5800)
    })
  })

  describe('el precio mayorista nunca sube el precio', () => {
    it('un producto sin condición queda en su precio de lista', () => {
      const resueltos = resolverPreciosMayorista([item('999', 100)], PRICING_MAP)
      expect(resueltos.get('999')?.esMayorista ?? false).toBe(false)
    })

    it('un precio puesto a mano no lo pisa el mayorista', () => {
      const manual: ItemPedido = { productoId: '140', cantidad: 12, precioUnitario: 700, precioOverride: true }
      const resueltos = resolverPreciosMayorista([manual], PRICING_MAP)
      expect(resueltos.get('140')?.precioResuelto).toBe(700)
    })
  })
})
