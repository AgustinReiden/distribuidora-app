import { describe, it, expect } from 'vitest'
import {
  unidadesDeLaBarra,
  sugerirCantidadPorValor,
  evaluarCambioRegalo,
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
  it('redondea al entero más cercano', () => {
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
    })!.cantidad).toBe(4) // 7000 / 1850 = 3,78
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

  it('mismo rubro sin bulto cargado: cae al factor de la promo, como hasta ahora', () => {
    expect(evaluarCambioRegalo({
      ...base, original: MANAOS_3L, sustituto: { ...MANAOS_NARANJA, unidades_por_bulto: null },
    })).toEqual({ tipo: 'mismo_empaque', factorSustituto: 6 })
  })

  it('mismo rubro con otro empaque: por valor', () => {
    const r = evaluarCambioRegalo({
      ...base, original: MANAOS_3L, sustituto: { ...MANAOS_NARANJA, unidades_por_bulto: 12, precio: 8500 },
    })
    expect(r.tipo).toBe('por_valor')
    if (r.tipo === 'por_valor') {
      expect(r.mismaCategoria).toBe(true)
      expect(r.factorSustituto).toBe(12)
      expect(r.sugerencia?.cantidad).toBe(16) // 11100 / (8500/12) = 15,67
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
