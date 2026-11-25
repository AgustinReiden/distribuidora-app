import { describe, it, expect } from 'vitest'
import {
  unidadesDeLaBarra,
  sugerirCantidadPorValor,
  evaluarCambioRegalo,
  topePorValor,
  topeSustitutoRegalo,
  regaloSinBulto,
  textoRegaloSinBulto,
  type ProductoConEmpaque,
} from './regaloOtroEmpaque'

// Precios de prod (2026-10): Manaos 3L $11.100 el fardo x6, Placer 500 $7.000 el fardo x12.
const MANAOS_3L: ProductoConEmpaque = { id: '82', nombre: 'Manaos Manzana 3L', precio: 11100, unidades_por_bulto: 6, categoria_id: 'manaos', subcategoria_id: '3l' }
const MANAOS_NARANJA: ProductoConEmpaque = { id: '80', nombre: 'Manaos Naranja 3L', precio: 11100, unidades_por_bulto: 6, categoria_id: 'manaos', subcategoria_id: '3l' }
const PLACER_500: ProductoConEmpaque = { id: '125', nombre: 'Placer 500', precio: '7000.00', unidades_por_bulto: 12, categoria_id: 'placer', subcategoria_id: '500' }
const PAPAS: ProductoConEmpaque = { id: '500', nombre: 'Papas', precio: 900, unidades_por_bulto: 1, categoria_id: 'snacks' }
const PAPAS_SIN_BULTO: ProductoConEmpaque = { ...PAPAS, unidades_por_bulto: null }

describe('unidadesDeLaBarra', () => {
  it('el bulto del contenedor manda sobre la promo', () => {
    expect(unidadesDeLaBarra(12, 6)).toBe(12)
  })
  it('sin bulto, el de la promo', () => {
    expect(unidadesDeLaBarra(null, 6)).toBe(6)
    expect(unidadesDeLaBarra(0, 6)).toBe(6)
  })
  it('sin ninguno, null', () => {
    expect(unidadesDeLaBarra(undefined, null)).toBeNull()
  })
})

describe('sugerirCantidadPorValor', () => {
  it('6 botellas de 3L (≈ $11.100) son ≈ 19 botellas de Placer 500', () => {
    const s = sugerirCantidadPorValor({
      cantidadOriginal: 6, precioOriginal: 11100, factorOriginal: 6,
      precioSustituto: 7000, factorSustituto: 12,
    })
    expect(s).not.toBeNull()
    expect(s!.valor).toBe(11100)
    expect(s!.precioSueltaOriginal).toBe(1850)
    expect(s!.cantidad).toBe(19) // 11100 / 583,33 = 19,03
  })
  it('redondea para abajo: el sustituto no vale más que el regalo (#1592)', () => {
    // 6 × 1850 / 900 = 12,33
    expect(sugerirCantidadPorValor({
      cantidadOriginal: 6, precioOriginal: 11100, factorOriginal: 6,
      precioSustituto: 900, factorSustituto: 1,
    })!.cantidad).toBe(12)
  })
  it('mínimo 1 aunque el sustituto valga mucho más', () => {
    expect(sugerirCantidadPorValor({
      cantidadOriginal: 1, precioOriginal: 600, factorOriginal: 6,
      precioSustituto: 50000, factorSustituto: 1,
    })!.cantidad).toBe(1)
  })
  it('acepta precios como string (numeric de Postgres)', () => {
    expect(sugerirCantidadPorValor({
      cantidadOriginal: 12, precioOriginal: '7000.00', factorOriginal: 12,
      precioSustituto: '11100.00', factorSustituto: 6,
    })!.cantidad).toBe(3) // 7000 / 1850 = 3,78: 4 valdrían más que el regalo
  })
  it.each([
    ['sin precio del original', { precioOriginal: null }],
    ['precio 0 del sustituto', { precioSustituto: 0 }],
    ['sin factor del sustituto', { factorSustituto: null }],
  ])('%s → null', (_n, cambio) => {
    expect(sugerirCantidadPorValor({
      cantidadOriginal: 6, precioOriginal: 11100, factorOriginal: 6,
      precioSustituto: 7000, factorSustituto: 12, ...cambio,
    })).toBeNull()
  })
})

describe('evaluarCambioRegalo', () => {
  const base = { cantidadOriginal: 6, factorOriginal: 6, regaloMueveStock: false, unidadesPorBloquePromo: 6 }

  it('mismo rubro y mismo empaque: la cantidad no se toca', () => {
    expect(evaluarCambioRegalo({ ...base, original: MANAOS_3L, sustituto: MANAOS_NARANJA }))
      .toEqual({ tipo: 'mismo_empaque', factorSustituto: 6 })
  })

  // promos-B1 (tanda 6 de #1603), cambió de regla: antes el mismo rubro sin bulto caía al factor
  // de la promo (el empaque del regalo) aunque descontara de su propio contenedor.
  it('mismo rubro sin bulto cargado y con su propio contenedor: hay que cargarlo', () => {
    const naranjaSinBulto = { ...MANAOS_NARANJA, unidades_por_bulto: null }
    expect(evaluarCambioRegalo({ ...base, original: MANAOS_3L, sustituto: naranjaSinBulto, contenedorPromoId: '82' }))
      .toEqual({ tipo: 'falta_bulto', productoACargar: naranjaSinBulto })
  })

  it('mismo rubro sin bulto que descuenta del contenedor de la promo: el factor de la promo', () => {
    const naranjaSinBulto = { ...MANAOS_NARANJA, unidades_por_bulto: null }
    const fardo = { id: '900', nombre: 'Fardo Manaos', unidades_por_bulto: null }
    expect(evaluarCambioRegalo({
      ...base, original: MANAOS_3L, sustituto: naranjaSinBulto, contenedorSustituto: fardo, contenedorPromoId: '900',
    })).toEqual({ tipo: 'mismo_empaque', factorSustituto: 6 })
  })

  it('el regalo de la promo sin bulto: el factor de la promo', () => {
    expect(evaluarCambioRegalo({
      ...base, original: MANAOS_NARANJA, sustituto: { ...MANAOS_3L, unidades_por_bulto: null }, regaloPromoId: '82',
    })).toEqual({ tipo: 'mismo_empaque', factorSustituto: 6 })
  })

  it('una promo sin unidades por bloque cuenta de a una: no pide el bulto', () => {
    expect(evaluarCambioRegalo({
      ...base, factorOriginal: 1, unidadesPorBloquePromo: null,
      original: MANAOS_3L, sustituto: { ...MANAOS_NARANJA, unidades_por_bulto: null },
    })).toEqual({ tipo: 'mismo_empaque', factorSustituto: 1 })
  })

  it('mismo rubro con otro empaque: por valor', () => {
    const r = evaluarCambioRegalo({
      ...base, original: MANAOS_3L, sustituto: { ...MANAOS_NARANJA, unidades_por_bulto: 12, precio: 8500 },
    })
    expect(r.tipo).toBe('por_valor')
    if (r.tipo === 'por_valor') {
      expect(r.mismaCategoria).toBe(true)
      expect(r.factorSustituto).toBe(12)
      expect(r.sugerencia?.cantidad).toBe(15) // 11100 / (8500/12) = 15,67, para abajo
    }
  })

  it('otro rubro: por valor, con el factor del sustituto (Placer x12)', () => {
    const r = evaluarCambioRegalo({ ...base, original: MANAOS_3L, sustituto: PLACER_500 })
    expect(r).toMatchObject({ tipo: 'por_valor', factorSustituto: 12, mismaCategoria: false })
    if (r.tipo === 'por_valor') expect(r.sugerencia?.cantidad).toBe(19)
  })

  it('otro rubro sin bulto cargado: hay que cargarlo', () => {
    expect(evaluarCambioRegalo({ ...base, original: MANAOS_3L, sustituto: PAPAS_SIN_BULTO }))
      .toEqual({ tipo: 'falta_bulto', productoACargar: PAPAS_SIN_BULTO })
  })

  it('el factor sale del contenedor del sustituto, no del sustituto', () => {
    const r = evaluarCambioRegalo({
      ...base, original: MANAOS_3L, sustituto: PAPAS_SIN_BULTO, contenedorSustituto: PAPAS,
    })
    expect(r).toMatchObject({ tipo: 'por_valor', factorSustituto: 1 })
  })

  it('modo A (mueve stock): factor 1 de los dos lados, por valor si es otro rubro', () => {
    const r = evaluarCambioRegalo({
      original: MANAOS_3L, sustituto: PAPAS_SIN_BULTO, cantidadOriginal: 1, factorOriginal: 1,
      regaloMueveStock: true, unidadesPorBloquePromo: null,
    })
    expect(r).toMatchObject({ tipo: 'por_valor', factorSustituto: 1 })
    if (r.tipo === 'por_valor') expect(r.sugerencia?.cantidad).toBe(12) // 11100 / 900
  })

  it('modo A, mismo rubro: la cantidad no se toca', () => {
    expect(evaluarCambioRegalo({
      original: MANAOS_3L, sustituto: MANAOS_NARANJA, cantidadOriginal: 2, factorOriginal: 1,
      regaloMueveStock: true,
    })).toEqual({ tipo: 'mismo_empaque', factorSustituto: 1 })
  })
})

describe('topeSustitutoRegalo (#1592, decisión del dueño del 16/11)', () => {
  const r4 = { corte: 4, precioRegalo: 100, factorRegalo: 1 }
  it('mismo rubro: todo el corte, aunque el sustituto sea más caro', () => {
    expect(topeSustitutoRegalo({ ...r4, precioSustituto: 110, factorSustituto: 1, mismoRubro: true })).toBe(4)
  })
  it('por valor: lo que entra en el regalo, para abajo', () => {
    expect(topeSustitutoRegalo({ ...r4, precioSustituto: 72, factorSustituto: 1, mismoRubro: false })).toBe(5)
    expect(topeSustitutoRegalo({ ...r4, precioSustituto: 10, factorSustituto: 1, mismoRubro: true })).toBe(40)
  })
  it('el valor exacto entra, sin el error de la división de punto flotante', () => {
    // 4 × 100 × 12 / (6 × 10) = 80; y 3 × 0,70 / 0,10, que en float da 20,999…
    expect(topePorValor({ corte: 4, precioRegalo: 100, factorRegalo: 6, precioSustituto: 10, factorSustituto: 12 })).toBe(80)
    expect(topePorValor({ corte: 3, precioRegalo: '0.70', factorRegalo: 1, precioSustituto: '0.10', factorSustituto: 1 })).toBe(21)
  })
  it('sin precio sólo cuenta el rubro', () => {
    expect(topeSustitutoRegalo({ ...r4, precioRegalo: null, precioSustituto: 10, factorSustituto: 1, mismoRubro: false })).toBe(0)
    expect(topeSustitutoRegalo({ ...r4, precioRegalo: null, precioSustituto: 10, factorSustituto: 1, mismoRubro: true })).toBe(4)
  })
})

describe('evaluarCambioRegalo con el regalo de la promo como referencia (#1592)', () => {
  it('sugiere por valor contra el regalo de la promo y su corte, no contra la línea', () => {
    // La línea ya es Placer (cambiada antes); la promo regala 6 botellas de Manaos 3L.
    const r = evaluarCambioRegalo({
      original: PLACER_500, sustituto: PAPAS, cantidadOriginal: 19, factorOriginal: 12,
      regaloMueveStock: false, unidadesPorBloquePromo: 6,
      referencia: { regalo: MANAOS_3L, factor: 6, corte: 6 },
    })
    expect(r.tipo).toBe('por_valor')
    if (r.tipo === 'por_valor') expect(r.sugerencia?.cantidad).toBe(12) // 6 × 1850 / 900 = 12,33
  })
})

describe('regaloSinBulto · promos-B1 en el alta y la edición (tanda 6 bis de #1603)', () => {
  // Promo de fracción «5 V dan 2 R», R es su propio contenedor (6 R = 1 R).
  const promo = { regaloMueveStock: false, unidadesPorBloque: 6, ajusteProductoId: 'R', productoRegaloId: 'R' }

  it('otro sabor sin bulto: no se puede regalar', () => {
    expect(regaloSinBulto({ promo, producto: { id: 'X', unidades_por_bulto: null } })).toBe(true)
    expect(textoRegaloSinBulto('Manaos Naranja')).toBe(
      'Para regalar Manaos Naranja hay que cargar en su ficha cuántas unidades sueltas trae cada unidad de stock (unidades por bulto).')
  })

  it('con su bulto, el regalo o el contenedor de la promo, sí', () => {
    expect(regaloSinBulto({ promo, producto: { id: 'X1', unidades_por_bulto: 1 } })).toBe(false)
    expect(regaloSinBulto({ promo, producto: { id: 'R', unidades_por_bulto: null } })).toBe(false)
    expect(regaloSinBulto({ promo: { ...promo, productoRegaloId: 'C', ajusteProductoId: 'K' }, producto: { id: 'K' } })).toBe(false)
  })

  it('una promo que mueve stock o sin unidades por bloque no lo pide', () => {
    expect(regaloSinBulto({ promo: { ...promo, regaloMueveStock: true }, producto: { id: 'X' } })).toBe(false)
    expect(regaloSinBulto({ promo: { ...promo, unidadesPorBloque: null }, producto: { id: 'X' } })).toBe(false)
  })
})
