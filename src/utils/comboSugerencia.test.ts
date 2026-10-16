import { describe, it, expect } from 'vitest'
import { orquestarPrecios } from './orquestacionPrecios'
import { pricingMapDe } from './orquestacionPrecios.fixture'
import { aplicarCombosAlPedido } from './combosPedido'
import { carritoConAgregados, sugerirCombos, type EntradaSugerencias } from './comboSugerencia'
import type { ComboVigente } from './combos'
import type { ItemPedido } from './precioMayorista'

const FERNET = '10'
const COCA = '11'
const SPRITE = '12'

const PRECIOS: Record<string, number> = { [FERNET]: 10000, [COCA]: 2500, [SPRITE]: 2300 }

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

function cotizador(combos: ComboVigente[]) {
  return (items: ItemPedido[]) => {
    const o = orquestarPrecios({ items, pricingMap, productos: [], cliente: null })
    return aplicarCombosAlPedido({
      itemsBase: items,
      lineas: o.items,
      productosConPromo: o.promoResolucion.productosConPromo,
      pricingMap,
      productos: [],
      cliente: null,
      combos,
    })
  }
}

function sugerir(items: ItemPedido[], combos: ComboVigente[], extra: Partial<EntradaSugerencias> = {}) {
  const cotizar = cotizador(combos)
  return sugerirCombos({
    items,
    combos,
    actual: cotizar(items),
    cotizar,
    precioDe: p => PRECIOS[p] ?? 0,
    puedeAgregar: () => true,
    ...extra,
  })
}

const item = (productoId: string, cantidad: number, extra: Partial<ItemPedido> = {}): ItemPedido =>
  ({ productoId, cantidad, precioUnitario: PRECIOS[productoId], ...extra })

describe('sugerirCombos', () => {
  it('con el Fernet y sin la Coca sugiere agregar 1 Coca y el ahorro que da armarCombos', () => {
    const s = sugerir([item(FERNET, 1)], [fernetCoca])
    expect(s).toEqual([{ comboId: '500', nombre: 'Fernet + Coca', agregar: [{ productoId: COCA, cantidad: 1 }], ahorro: 1500 }])
    // El ahorro es el mismo que da el pedido una vez agregado lo que falta.
    const r = cotizador([fernetCoca])([item(FERNET, 1), item(COCA, 1)])
    expect(r.ahorro).toBe(1500)
  })

  it('con el combo completo no sugiere nada', () => {
    expect(sugerir([item(FERNET, 1), item(COCA, 1)], [fernetCoca])).toEqual([])
  })

  it('con un combo armado y un Fernet suelto sugiere el segundo combo', () => {
    const s = sugerir([item(FERNET, 2), item(COCA, 1)], [fernetCoca])
    expect(s).toHaveLength(1)
    expect(s[0].agregar).toEqual([{ productoId: COCA, cantidad: 1 }])
    expect(s[0].ahorro).toBe(1500)
  })

  it('sin ningún componente en el carrito no sugiere', () => {
    expect(sugerir([item(SPRITE, 3)], [fernetCoca])).toEqual([])
  })

  it('pide la cantidad justa para completar el lugar (2 + 1)', () => {
    const dosCocas: ComboVigente = {
      ...fernetCoca,
      precio: 13000,
      componentes: [
        { componente: 1, cantidad: 1, productos: [FERNET] },
        { componente: 2, cantidad: 2, productos: [COCA] },
      ],
    }
    expect(sugerir([item(FERNET, 1)], [dosCocas])[0].agregar).toEqual([{ productoId: COCA, cantidad: 2 }])
    expect(sugerir([item(FERNET, 1), item(COCA, 1)], [dosCocas])[0].agregar).toEqual([{ productoId: COCA, cantidad: 1 }])
  })

  it('no sugiere si llegó al tope', () => {
    expect(sugerir([item(FERNET, 1)], [{ ...fernetCoca, topeRestante: 0 }])).toEqual([])
    // Con tope 1 y un combo ya armado, el segundo no se ofrece.
    expect(sugerir([item(FERNET, 2), item(COCA, 1)], [{ ...fernetCoca, topeRestante: 1 }])).toEqual([])
  })

  it('no sugiere si el combo no baja el total ("no conviene")', () => {
    expect(sugerir([item(FERNET, 1)], [{ ...fernetCoca, precio: 12500 }])).toEqual([])
  })

  it('no sugiere si falta stock del componente', () => {
    const puedeAgregar = (p: string) => p !== COCA
    expect(sugerir([item(FERNET, 1)], [fernetCoca], { puedeAgregar })).toEqual([])
  })

  it('le pasa a puedeAgregar lo que suma y el total que queda en el carrito', () => {
    const llamadas: Array<[string, number, number]> = []
    sugerir([item(FERNET, 3), item(COCA, 1)], [fernetCoca], {
      puedeAgregar: (p, a, t) => { llamadas.push([p, a, t]); return true },
    })
    // Un combo armado y dos Fernet sueltos: se sugiere de a un combo.
    expect(llamadas).toEqual([[COCA, 1, 2]])
  })

  it('no sugiere el combo descartado para este pedido', () => {
    expect(sugerir([item(FERNET, 1)], [fernetCoca], { descartados: new Set(['500']) })).toEqual([])
  })

  it('no toca un producto con precio manual', () => {
    expect(sugerir([item(FERNET, 1), item(COCA, 1, { precioUnitario: 1, precioOverride: true })], [fernetCoca])).toEqual([])
    // Y la línea manual del Fernet no cuenta como "presente".
    expect(sugerir([item(FERNET, 1, { precioUnitario: 9000, precioOverride: true })], [fernetCoca])).toEqual([])
  })

  it('con alternativas en el lugar elige la que ya está en el carrito o, si no, la más barata', () => {
    const conAlternativa: ComboVigente = {
      ...fernetCoca,
      componentes: [
        { componente: 1, cantidad: 1, productos: [FERNET] },
        { componente: 2, cantidad: 1, productos: [COCA, SPRITE] },
      ],
    }
    expect(sugerir([item(FERNET, 1)], [conAlternativa])[0].agregar).toEqual([{ productoId: SPRITE, cantidad: 1 }])
    // Con el Fernet de más y una Coca sola, falta el Fernet: se sugiere el lugar que falta.
    expect(sugerir([item(COCA, 1)], [conAlternativa])[0].agregar).toEqual([{ productoId: FERNET, cantidad: 1 }])
  })

  it('escala excluyente: no sugiere el combo que le haría perder el mayorista a las Cocas', () => {
    // 48 Coca a mayorista + nada de Fernet: sumar el Fernet arma un combo que
    // saca una Coca del conteo y las 47 restantes pierden la escala.
    expect(sugerir([item(COCA, 48)], [fernetCoca])).toEqual([])
    // Con 60 Cocas sí conviene.
    expect(sugerir([item(COCA, 60)], [fernetCoca])).toHaveLength(1)
  })

  it('ordena por ahorro, una línea por combo', () => {
    const otro: ComboVigente = { ...fernetCoca, id: '501', nombre: 'Fernet + Sprite', precio: 11800, componentes: [
      { componente: 1, cantidad: 1, productos: [FERNET] },
      { componente: 2, cantidad: 1, productos: [SPRITE] },
    ] }
    const s = sugerir([item(FERNET, 1)], [otro, fernetCoca])
    expect(s.map(x => x.comboId)).toEqual(['500', '501'])
    expect(s.map(x => x.ahorro)).toEqual([1500, 500])
  })
})

describe('carritoConAgregados', () => {
  it('suma a la línea existente y agrega las nuevas a precio de lista', () => {
    expect(carritoConAgregados([item(FERNET, 1)], [{ productoId: FERNET, cantidad: 1 }, { productoId: COCA, cantidad: 2 }], p => PRECIOS[p]))
      .toEqual([item(FERNET, 2), item(COCA, 2)])
  })
})
