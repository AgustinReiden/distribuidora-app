/**
 * #908 a nivel reducer: aceptar y descartar la sugerencia de bonificación.
 * Fixtures sintéticos (el repo es público).
 */
import { describe, it, expect } from 'vitest'
import { compraReducer, initialState, cargosParaRPC, lineaEnAlcance } from './ModalCompra.reducer'
import type { CompraState } from './ModalCompra.reducer'
import { sugerirBonificaciones } from '../../utils/sugerenciasBonificacion'
import type { PromocionProveedor, SugerenciaBonificacion } from '../../utils/sugerenciasBonificacion'
import type { ConceptoCargo } from '../../utils/medidasCargo'
import { compraTieneCambios } from '../../utils/compraTieneCambios'
import type { ProductoDB } from '../../types'

type Accion = Parameters<typeof compraReducer>[1]

const producto = (id: string, costo: number): ProductoDB => ({
  id, nombre: `Producto ${id}`, codigo: id, costo_sin_iva: costo,
  impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado', stock: 10,
} as unknown as ProductoDB)

const correr = (acciones: Accion[], desde: CompraState = initialState): CompraState =>
  acciones.reduce(compraReducer, desde)

const conceptoBonif: ConceptoCargo = {
  id: '4', nombre: 'Bonificación', signo: -1, condicionIva: 'gravado', enFactura: true,
  prorrateaAlCosto: true, baseProrrateo: 'monto', medidaId: null, activo: true,
}

const promo: PromocionProveedor = {
  id: '9', nombre: 'Promo sintética', tipo: 'monto_por_unidad', montoPorUnidad: 100, porcentaje: null,
  vigenteDesde: null, vigenteHasta: null, activo: true, productoIds: ['a', 'b'],
}

/** a (10 u.) y b (4 u.) en la promo; c (6 u.) afuera. */
const factura = () => correr([
  { type: 'AGREGAR_ITEM', payload: producto('a', 1000) },
  { type: 'AGREGAR_ITEM', payload: producto('b', 2000) },
  { type: 'AGREGAR_ITEM', payload: producto('c', 500) },
  { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 10 } },
  { type: 'ACTUALIZAR_ITEM', payload: { index: 1, campo: 'cantidad', valor: 4 } },
  { type: 'ACTUALIZAR_ITEM', payload: { index: 2, campo: 'cantidad', valor: 6 } },
])

const sugerir = (s: CompraState): SugerenciaBonificacion[] => sugerirBonificaciones({
  lineas: s.items.map(i => ({
    lineaId: i.lineaId as number, productoId: i.productoId, cantidad: i.cantidad,
    costoUnitario: i.costoUnitario, bonificacion: i.bonificacion,
  })),
  cargos: s.cargos,
  promos: [promo],
  fechaCompra: s.fechaCompra,
  descartadas: s.sugerenciasDescartadas ?? [],
})

describe('AGREGAR_CARGO_SUGERIDO', () => {
  it('agrega la bonificación con el concepto del catálogo, en factura y con su alcance', () => {
    const s0 = factura()
    const [sug] = sugerir(s0)
    expect(sug.monto).toBe(-1400)
    const s = correr([{ type: 'AGREGAR_CARGO_SUGERIDO', payload: { sugerencia: sug, concepto: conceptoBonif } }], s0)
    expect(s.cargos).toHaveLength(1)
    const c = s.cargos[0]
    expect(c.concepto).toBe('Bonificación')
    expect(c.conceptoId).toBe('4')
    expect(c.monto).toBe(-1400)
    expect(c.condicionIva).toBe('gravado')
    // En factura, como el catálogo (y como se cargaban a mano).
    expect(c.enFactura).toBe(true)
    expect(c.prorrateaAlCosto).toBe(true)
    expect(c.afectaBaseIIManual).toBe(false)
    expect(c.baseProrrateo).toBe('cantidad')
    expect(c.pesos).toEqual({ 1: 10, 2: 4, 3: 0 })
    expect(c.sugerencia).toEqual({ promoId: '9', productoIds: ['a', 'b'] })
  })

  it('una vez aplicada no se vuelve a sugerir, y dos clics no la duplican', () => {
    const s0 = factura()
    const [sug] = sugerir(s0)
    const accion: Accion = { type: 'AGREGAR_CARGO_SUGERIDO', payload: { sugerencia: sug, concepto: conceptoBonif } }
    const s = correr([accion, accion], s0)
    expect(s.cargos).toHaveLength(1)
    expect(sugerir(s)).toEqual([])
  })

  it('el alcance sigue por producto: una línea nueva de otro producto entra en 0', () => {
    const s0 = factura()
    const [sug] = sugerir(s0)
    const s = correr([
      { type: 'AGREGAR_CARGO_SUGERIDO', payload: { sugerencia: sug, concepto: conceptoBonif } },
      { type: 'AGREGAR_ITEM', payload: producto('d', 700) },
    ], s0)
    expect(s.cargos[0].pesos[4]).toBe(0)
    expect(lineaEnAlcance(s.cargos[0], 'd')).toBe(false)
    expect(lineaEnAlcance(s.cargos[0], 'a')).toBe(true)
    // Y el peso de una línea del alcance sigue a la cantidad.
    const s2 = correr([{ type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 12 } }], s)
    expect(s2.cargos[0].pesos[1]).toBe(12)
  })

  it('sin el concepto en el catálogo, entra como "Bonificación" de texto', () => {
    const s0 = factura()
    const [sug] = sugerir(s0)
    const s = correr([{ type: 'AGREGAR_CARGO_SUGERIDO', payload: { sugerencia: sug, concepto: null } }], s0)
    expect(s.cargos[0].concepto).toBe('Bonificación')
    expect(s.cargos[0].conceptoId).toBeNull()
    expect(s.cargos[0].monto).toBe(-1400)
  })

  it('la marca de la sugerencia no viaja a la RPC', () => {
    const s0 = factura()
    const [sug] = sugerir(s0)
    const s = correr([{ type: 'AGREGAR_CARGO_SUGERIDO', payload: { sugerencia: sug, concepto: conceptoBonif } }], s0)
    const [rpc] = cargosParaRPC(s.items, s.cargos)
    expect(rpc).not.toHaveProperty('sugerencia')
    expect(rpc.monto).toBe(-1400)
    expect(rpc.enFactura).toBe(true)
  })
})

describe('DESCARTAR_SUGERENCIA', () => {
  it('no vuelve a sugerir la promo descartada y no agrega cargos', () => {
    const s0 = factura()
    const s = correr([
      { type: 'DESCARTAR_SUGERENCIA', payload: { promoId: '9' } },
      { type: 'DESCARTAR_SUGERENCIA', payload: { promoId: '9' } },
    ], s0)
    expect(s.sugerenciasDescartadas).toEqual(['9'])
    expect(s.cargos).toEqual([])
    expect(sugerir(s)).toEqual([])
  })

  it('tolera un borrador viejo sin el campo', () => {
    const viejo = { ...factura() }
    delete viejo.sugerenciasDescartadas
    const s = correr([{ type: 'DESCARTAR_SUGERENCIA', payload: { promoId: '9' } }], viejo)
    expect(s.sugerenciasDescartadas).toEqual(['9'])
  })

  it('descartar no cuenta como cambio de la compra', () => {
    const s = correr([{ type: 'DESCARTAR_SUGERENCIA', payload: { promoId: '9' } }])
    expect(compraTieneCambios(s)).toBe(false)
  })
})
