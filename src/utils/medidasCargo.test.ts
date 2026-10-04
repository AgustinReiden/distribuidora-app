/**
 * Medidas para repartir cargos (mig 278). Datos sintéticos.
 */
import { describe, it, expect } from 'vitest'
import {
  CONTEXTO_MEDIDAS_VACIO, conValorDeCompra, conceptoPorNombre, fichaTieneValor, guardarEnFichaPorDefecto,
  medidaEditable, medidasParaFicha, normalizarNombreConcepto, pesoPorMedida, pluralMedida, resolverMedida,
  textoMedidaLinea, unidadesPorDesdeCantidadDeMedidas,
} from './medidasCargo'
import type { ConceptoCargo, ContextoMedidas } from './medidasCargo'

// 1 = Pallet, 2 = Separador, 3 = Lugar en el flete (base: Pallet)
const ctx = (over: Partial<ContextoMedidas> = {}): ContextoMedidas => ({
  bases: { '1': null, '2': null, '3': '1' },
  ficha: {},
  compra: {},
  ...over,
})

describe('resolverMedida', () => {
  it('sin medida o sin valor en ningun lado: null', () => {
    expect(resolverMedida('a', null, ctx())).toBeNull()
    expect(resolverMedida('a', '1', ctx())).toBeNull()
  })

  it('la ficha da el valor', () => {
    expect(resolverMedida('a', '1', ctx({ ficha: { a: { '1': 120 } } })))
      .toEqual({ unidadesPor: 120, medidaId: '1', origen: 'ficha', porBase: false })
  })

  it('lo tipeado en la compra gana sobre la ficha', () => {
    const c = ctx({ ficha: { a: { '1': 120 } }, compra: { a: { '1': { unidadesPor: 100, guardarEnFicha: false } } } })
    expect(resolverMedida('a', '1', c)).toMatchObject({ unidadesPor: 100, origen: 'compra' })
  })

  it('sin valor propio cae a la medida base (un nivel)', () => {
    const c = ctx({ ficha: { a: { '1': 120 } } })
    expect(resolverMedida('a', '3', c)).toEqual({ unidadesPor: 120, medidaId: '1', origen: 'ficha', porBase: true })
  })

  it('el valor propio gana aunque la base venga de la compra (Placer 500cc)', () => {
    const c = ctx({
      ficha: { a: { '3': 300 } },
      compra: { a: { '1': { unidadesPor: 150, guardarEnFicha: true } } },
    })
    expect(resolverMedida('a', '3', c)).toMatchObject({ unidadesPor: 300, medidaId: '3', porBase: false })
  })

  it('ignora valores no positivos', () => {
    expect(resolverMedida('a', '1', ctx({ ficha: { a: { '1': 0 } } }))).toBeNull()
  })

  it('medidaEditable: la que resuelve, o la base si no resuelve', () => {
    expect(medidaEditable('a', '3', ctx())).toBe('1')
    expect(medidaEditable('a', '3', ctx({ ficha: { a: { '3': 10 } } }))).toBe('3')
    expect(medidaEditable('a', '2', ctx())).toBe('2')
  })
})

describe('pallets y unidades por pallet', () => {
  it('peso = cantidad / unidades_por, a 4 decimales', () => {
    expect(pesoPorMedida(240, 120)).toBe(2)
    expect(pesoPorMedida(75, 150)).toBe(0.5)
    expect(pesoPorMedida(100, 0)).toBe(0)
  })

  it('pallets tipeados vuelven exactos: no 3,0003', () => {
    const u = unidadesPorDesdeCantidadDeMedidas(1000, 3)!
    expect(u).toBeCloseTo(333.3333, 4)
    // Sin redondear las u/pallet el peso vuelve a dar los pallets tipeados.
    expect(pesoPorMedida(1000, u)).toBe(3)
    // Redondeadas a 2 decimales daría otra cosa: por eso se guardan crudas.
    expect(pesoPorMedida(1000, 333.33)).toBe(3)
    expect(pesoPorMedida(1000, 333.3)).not.toBe(3)
  })

  it('no deriva con 0 pallets ni cantidad 0', () => {
    expect(unidadesPorDesdeCantidadDeMedidas(100, 0)).toBeNull()
    expect(unidadesPorDesdeCantidadDeMedidas(0, 2)).toBeNull()
  })
})

describe('guardar en la ficha', () => {
  it('marcado si la ficha no tenia valor; desmarcado si tenia', () => {
    expect(guardarEnFichaPorDefecto(false)).toBe(true)
    expect(guardarEnFichaPorDefecto(true)).toBe(false)
    const sinFicha = conValorDeCompra(ctx(), 'a', '1', 120)
    expect(sinFicha.compra.a['1']).toEqual({ unidadesPor: 120, guardarEnFicha: true })
    const conFicha = conValorDeCompra(ctx({ ficha: { a: { '1': 100 } } }), 'a', '1', 90)
    expect(conFicha.compra.a['1'].guardarEnFicha).toBe(false)
    expect(fichaTieneValor('a', '1', ctx({ ficha: { a: { '1': 100 } } }))).toBe(true)
  })

  it('re-tipear conserva la decision del check; null vuelve a la ficha', () => {
    let c = conValorDeCompra(ctx(), 'a', '1', 120)
    c = { ...c, compra: { a: { '1': { ...c.compra.a['1'], guardarEnFicha: false } } } }
    c = conValorDeCompra(c, 'a', '1', 130)
    expect(c.compra.a['1']).toEqual({ unidadesPor: 130, guardarEnFicha: false })
    expect(conValorDeCompra(c, 'a', '1', null).compra).toEqual({})
  })

  it('medidasParaFicha: solo lo marcado, de productos en la compra, y si cambia algo', () => {
    const c = ctx({
      ficha: { b: { '1': 80 } },
      compra: {
        a: { '1': { unidadesPor: 120, guardarEnFicha: true }, '2': { unidadesPor: 60, guardarEnFicha: false } },
        b: { '1': { unidadesPor: 80, guardarEnFicha: true } },
        z: { '1': { unidadesPor: 10, guardarEnFicha: true } },
      },
    })
    expect(medidasParaFicha(c, ['a', 'b'])).toEqual([{ productoId: 'a', medidaId: '1', unidadesPor: 120 }])
    expect(medidasParaFicha(CONTEXTO_MEDIDAS_VACIO, ['a'])).toEqual([])
  })
})

describe('conceptos', () => {
  const concepto = (nombre: string, id: string): ConceptoCargo => ({
    id, nombre, signo: 1, condicionIva: 'no_gravado', enFactura: true, prorrateaAlCosto: true,
    baseProrrateo: 'monto', medidaId: null, activo: true,
  })

  it('normaliza como la mig 278: sin tildes, minusculas, espacios colapsados', () => {
    expect(normalizarNombreConcepto('  Bonificación \t  Manaos ')).toBe('bonificacion manaos')
  })

  it('busca por nombre normalizado', () => {
    const lista = [concepto('Flete', '1'), concepto('Bonificación', '4')]
    expect(conceptoPorNombre(lista, ' BONIFICACION')?.id).toBe('4')
    expect(conceptoPorNombre(lista, 'Estiba')).toBeUndefined()
    expect(conceptoPorNombre(lista, '  ')).toBeUndefined()
  })
})

describe('texto de la linea', () => {
  it('"2 pallets (120 u/pallet)"', () => {
    expect(textoMedidaLinea(2, 120, 'pallet')).toBe('2 pallets (120 u/pallet)')
    expect(textoMedidaLinea(0.5, 150, 'lugar')).toBe('0,5 lugares (150 u/lugar)')
    expect(textoMedidaLinea(1, 60, 'separador')).toBe('1 separador (60 u/separador)')
    expect(pluralMedida('separador', 3)).toBe('separadores')
  })
})
