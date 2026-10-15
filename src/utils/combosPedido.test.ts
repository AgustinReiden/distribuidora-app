import { describe, it, expect } from 'vitest'
import { orquestarPrecios } from './orquestacionPrecios'
import { ESCENARIOS, PRODUCTOS, pricingMapDe } from './orquestacionPrecios.fixture'
import { aplicarCombosAlPedido, camposComboRPC, combinarCombosConFotos, crearOraculoPrecios } from './combosPedido'
import type { ComboVigente } from './combos'
import type { ItemPedido } from './precioMayorista'

const FERNET = '10'
const COCA = '11'

const fernetCoca: ComboVigente = {
  id: '500',
  nombre: 'Fernet + Coca',
  precio: 11000,
  combinaEscalas: false,
  prioridad: 0,
  topeRestante: null,
  componentes: [
    { componente: 1, cantidad: 1, productos: [FERNET] },
    { componente: 2, cantidad: 1, productos: [COCA] },
  ],
}

/** Coca a $2.000 desde 48 unidades del grupo. */
const pricingMap = pricingMapDe([{
  grupoId: 'g',
  grupoNombre: 'Coca',
  productoIds: [COCA],
  escalas: [{ escalaId: 'e', cantidadMinima: 48, precioUnitario: 2000, etiqueta: 'Mayorista', minProductosDistintos: 1, minimosPorProducto: new Map() }],
}])

function pedido(items: ItemPedido[], combos: ComboVigente[], cliente = null as { descuento_porcentaje: number } | null) {
  const o = orquestarPrecios({ items, pricingMap, productos: [], cliente })
  return aplicarCombosAlPedido({
    itemsBase: items,
    lineas: o.items,
    productosConPromo: o.promoResolucion.productosConPromo,
    pricingMap,
    productos: [],
    cliente,
    combos,
  })
}

const lista = (cantFernet: number, cantCoca: number): ItemPedido[] => [
  { productoId: FERNET, cantidad: cantFernet, precioUnitario: 10000 },
  { productoId: COCA, cantidad: cantCoca, precioUnitario: 2500 },
]

describe('crearOraculoPrecios', () => {
  // El oráculo arma los precios "sin combo" con las mismas piezas que la
  // orquestación. Sin unidades excluidas tiene que dar EXACTAMENTE lo que ella
  // resolvió: si no, el combo se armaría contra precios que no son los del
  // pedido. Se corre sobre los escenarios compartidos con el bot.
  it.each(ESCENARIOS.map(e => [e.nombre, e] as const))('sin exclusiones reproduce la orquestación: %s', (_n, e) => {
    const o = orquestarPrecios(e.input)
    const oraculo = crearOraculoPrecios({
      itemsBase: e.input.items,
      lineas: o.items,
      productosConPromo: o.promoResolucion.productosConPromo,
      pricingMap: e.input.pricingMap,
      productos: e.input.productos ?? PRODUCTOS,
      cliente: e.input.cliente ?? null,
    })
    for (const l of o.items) {
      if (l.esBonificacion) continue
      expect(oraculo.precioLibre(String(l.productoId), new Map())).toBe(l.precioUnitario)
    }
  })

  it('con unidades excluidas recalcula la escala sin contarlas', () => {
    const items = lista(1, 48)
    const o = orquestarPrecios({ items, pricingMap })
    const oraculo = crearOraculoPrecios({ itemsBase: items, lineas: o.items, productosConPromo: new Set(), pricingMap })
    expect(oraculo.precioLibre(COCA, new Map())).toBe(2000)
    expect(oraculo.precioLibre(COCA, new Map([[COCA, 1]]))).toBe(2500)
    expect(oraculo.precioSinEscala(COCA)).toBe(2500)
  })

  it('aplica el descuento del cliente a los dos precios', () => {
    const items = lista(1, 1)
    const cliente = { descuento_porcentaje: 10 }
    const o = orquestarPrecios({ items, pricingMap, cliente })
    const oraculo = crearOraculoPrecios({ itemsBase: items, lineas: o.items, productosConPromo: new Set(), pricingMap, cliente })
    expect(oraculo.precioSinEscala(FERNET)).toBe(9000)
  })
})

describe('aplicarCombosAlPedido', () => {
  it('sin combos devuelve las líneas tal cual', () => {
    const r = pedido(lista(1, 1), [])
    expect(r.aplicados).toHaveLength(0)
    expect(r.lineas.map(l => [l.productoId, l.cantidad, l.precioUnitario])).toEqual([[FERNET, 1, 10000], [COCA, 1, 2500]])
    expect(r.total).toBe(12500)
  })

  it('parte cada producto en la parte del combo y la suelta', () => {
    const r = pedido(lista(2, 3), [fernetCoca])
    expect(r.aplicados[0].cantidadCombos).toBe(2)
    const coca = r.lineas.filter(l => l.productoId === COCA)
    expect(coca.map(l => [l.cantidad, l.precioUnitario, l.comboId ?? null])).toEqual([[2, 2200, '500'], [1, 2500, null]])
    const fernet = r.lineas.filter(l => l.productoId === FERNET)
    expect(fernet.map(l => [l.cantidad, l.precioUnitario, l.precioSinCombo])).toEqual([[2, 8800, 10000]])
    expect(r.total).toBe(2 * 11000 + 2500)
    expect(r.ahorro).toBe(3000)
  })

  it('excluyente: con 60 Coca arma el combo y las sueltas siguen a mayorista', () => {
    const r = pedido(lista(1, 60), [fernetCoca])
    expect(r.aplicados[0].cantidadCombos).toBe(1)
    const suelta = r.lineas.find(l => l.productoId === COCA && !l.comboId)
    expect(suelta).toMatchObject({ cantidad: 59, precioUnitario: 2000 })
    expect(r.total).toBe(11000 + 59 * 2000)
  })

  it('excluyente: con 48 Coca no arma el combo', () => {
    expect(pedido(lista(1, 48), [fernetCoca]).aplicados).toHaveLength(0)
  })

  it('acumulable: la Coca del combo va contra la escala y lleva su precio sin escala', () => {
    const r = pedido(lista(1, 48), [{ ...fernetCoca, combinaEscalas: true }])
    const coca = r.lineas.find(l => l.productoId === COCA && l.comboId)
    expect(coca?.precioSinCombo).toBe(2000)
    expect(coca?.precioSinEscala).toBe(2500)
    expect(r.total).toBe(10500 + 47 * 2000)
  })

  it('una línea con precio manual no entra en combos', () => {
    const items: ItemPedido[] = [
      { productoId: FERNET, cantidad: 1, precioUnitario: 9000, precioOverride: true },
      { productoId: COCA, cantidad: 1, precioUnitario: 2500 },
    ]
    expect(pedido(items, [fernetCoca]).aplicados).toHaveLength(0)
  })

  it('el descuento del cliente no se suma al combo', () => {
    const r = pedido(lista(1, 1), [fernetCoca], { descuento_porcentaje: 10 })
    // Sin combo: 9.000 + 2.250 = 11.250 > 11.000, conviene; el combo sale 11.000.
    expect(r.aplicados[0].cantidadCombos).toBe(1)
    expect(r.total).toBe(11000)
  })
})

describe('camposComboRPC', () => {
  it('manda el combo y su precio sin combo; el sin escala sólo si vino', () => {
    expect(camposComboRPC({ comboId: '5', precioSinCombo: 2500 })).toEqual({ combo_id: 5, precio_sin_combo_unitario: 2500 })
    expect(camposComboRPC({ comboId: '5', precioSinCombo: 2000, precioSinEscala: 2500 }))
      .toEqual({ combo_id: 5, precio_sin_combo_unitario: 2000, precio_sin_escala_unitario: 2500 })
    expect(camposComboRPC({})).toEqual({})
  })
})

describe('combinarCombosConFotos', () => {
  it('la foto manda sobre la definición vigente y un combo que ya no está no crece', () => {
    const vigente = { ...fernetCoca, precio: 10500, topeRestante: 7, prioridad: 3 }
    const foto = { ...fernetCoca, cantidadCombos: 2 }
    const viejo = { ...fernetCoca, id: '501', cantidadCombos: 1 }
    const r = combinarCombosConFotos([vigente], [foto, viejo])
    expect(r.find(c => c.id === '500')).toMatchObject({ precio: 11000, topeRestante: 7, prioridad: 3 })
    expect(r.find(c => c.id === '501')).toMatchObject({ topeRestante: 1 })
  })
})
