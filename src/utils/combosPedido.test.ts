import { describe, it, expect } from 'vitest'
import { orquestarPrecios } from './orquestacionPrecios'
import { ESCENARIOS, PRODUCTOS, pricingMapDe } from './orquestacionPrecios.fixture'
import { aplicarCombosAlPedido, camposComboRPC, combinarCombosConFotos, combosConPrecioCambiado, crearOraculoPrecios, textoComboConPrecioCambiado } from './combosPedido'
import type { ComboVigente } from './combos'
import { validarMOQPedido, type ItemPedido } from './precioMayorista'

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

describe('mínimo de venta con combos (#1470)', () => {
  // El mínimo es del producto en el pedido: se suman sus líneas de venta, la del
  // combo incluida. Es lo que hace validar_minimo_venta_item en el server al
  // confirmar. Antes el server lo medía por línea y rechazaba lo que el front
  // dejaba pasar: el caso de la auditoría es éste, mínimo 6 con 8 en el carrito
  // y 2 tomadas por el combo.
  const minimos = new Map([[COCA, 6]])
  const comoItems = (lineas: { productoId: string; cantidad: number; precioUnitario: number; esBonificacion?: boolean }[]): ItemPedido[] =>
    lineas.filter(l => !l.esBonificacion).map(l => ({ productoId: l.productoId, cantidad: l.cantidad, precioUnitario: l.precioUnitario }))

  it('8 en el carrito con 2 en el combo: pasa, antes y después de armarlo', () => {
    const items = lista(2, 8)
    expect(validarMOQPedido(items, minimos)).toEqual([])

    const r = pedido(items, [fernetCoca])
    const coca = r.lineas.filter(l => l.productoId === COCA)
    expect(coca.map(l => [l.cantidad, l.comboId ?? null])).toEqual([[2, '500'], [6, null]])
    // La línea del combo sola queda debajo del mínimo, y es legal.
    expect(coca[0].cantidad).toBeLessThan(6)
    expect(validarMOQPedido(comoItems(r.lineas), minimos)).toEqual([])
  })

  it('5 en total con 2 en el combo: no pasa, y la violación habla del producto entero', () => {
    const items = lista(2, 5)
    const antes = validarMOQPedido(items, minimos)
    expect(antes).toEqual([{ productoId: COCA, cantidadActual: 5, cantidadMinima: 6 }])

    const r = pedido(items, [fernetCoca])
    expect(r.lineas.filter(l => l.productoId === COCA).map(l => l.cantidad)).toEqual([2, 3])
    expect(validarMOQPedido(comoItems(r.lineas), minimos)).toEqual(antes)
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
    // promos-B5 (tanda 6 bis): con el precio cambiado, sólo el admin conserva el tope del vigente.
    const r = combinarCombosConFotos([vigente], [foto, viejo], { sumaConPrecioCambiado: true })
    expect(r.find(c => c.id === '500')).toMatchObject({ precio: 11000, topeRestante: 7, prioridad: 3 })
    expect(r.find(c => c.id === '501')).toMatchObject({ topeRestante: 1 })
  })
})

describe('combinarCombosConFotos · promos-B5 (tanda 6 bis de #1603): el combo que cambió de precio no crece', () => {
  // Decisión del dueño (25/11): a un pedido que ya tiene un combo cuyo precio cambió, quien no
  // es admin no le puede sumar más; conservar y bajar siguen andando. El combo valía $ 11.000.
  const foto = { ...fernetCoca, cantidadCombos: 1 }

  it('el precio subió: conserva el que tiene y lo demás queda suelto, y lo avisa', () => {
    const vigentes = [{ ...fernetCoca, precio: 11500 }]
    const r = pedido(lista(2, 2), combinarCombosConFotos(vigentes, [foto]))
    expect(r.aplicados.map(a => a.cantidadCombos)).toEqual([1])
    expect(r.total).toBe(11000 + 10000 + 2500)
    const avisos = combosConPrecioCambiado(vigentes, [foto])
    expect(avisos).toEqual([{ id: '500', nombre: 'Fernet + Coca', precioFoto: 11000, precioHoy: 11500, cantidadCombos: 1 }])
    expect(textoComboConPrecioCambiado(avisos[0])).toBe(
      'El combo «Fernet + Coca» cambió de precio desde que se armó el pedido: valía $ 11.000,00 y hoy vale $ 11.500,00. '
      + 'Este pedido puede conservar sus 1 o bajarlos; los combos nuevos cargalos en otro pedido.')
  })

  it('G2: con el precio cambiado también rige el tope del combo', () => {
    const vigentes = [{ ...fernetCoca, precio: 11500, topeRestante: 0 }]
    const dos = { ...fernetCoca, cantidadCombos: 2 }
    expect(combinarCombosConFotos(vigentes, [dos]).find(c => c.id === '500')?.topeRestante).toBe(0)
    expect(combinarCombosConFotos([{ ...vigentes[0], topeRestante: 1 }], [dos]).find(c => c.id === '500')?.topeRestante).toBe(1)
    expect(combinarCombosConFotos([{ ...vigentes[0], topeRestante: null }], [dos]).find(c => c.id === '500')?.topeRestante).toBe(2)
  })

  it('el precio bajó: igual', () => {
    const vigentes = [{ ...fernetCoca, precio: 10500 }]
    expect(pedido(lista(2, 2), combinarCombosConFotos(vigentes, [foto])).aplicados.map(a => a.cantidadCombos)).toEqual([1])
  })

  it('el admin sí le suma, a la plata de la foto', () => {
    const vigentes = [{ ...fernetCoca, precio: 11500 }]
    const r = pedido(lista(2, 2), combinarCombosConFotos(vigentes, [foto], { sumaConPrecioCambiado: true }))
    expect(r.aplicados.map(a => a.cantidadCombos)).toEqual([2])
    expect(r.total).toBe(22000)
  })

  it('sin cambio de precio suma como siempre, y no avisa nada', () => {
    const r = pedido(lista(3, 3), combinarCombosConFotos([fernetCoca], [{ ...fernetCoca, cantidadCombos: 2 }]))
    expect(r.aplicados.map(a => a.cantidadCombos)).toEqual([3])
    expect(r.total).toBe(33000)
    expect(combosConPrecioCambiado([fernetCoca], [foto])).toEqual([])
  })
})
