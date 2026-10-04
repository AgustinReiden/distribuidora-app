/**
 * Pesos manuales que quedan viejos al editar una compra guardada.
 *
 * La regla de la entrega B2: al cambiar la cantidad de una línea, el peso
 * MANUAL de un cargo por cantidad no se pisa solo —puede ser un número de
 * pallets que no depende de nada— pero tampoco se calla: se marca y se ofrece
 * recalcular. Datos sintéticos con la forma de la compra 304 (pallets tipeados).
 */
import { describe, it, expect } from 'vitest'
import { pesosDesactualizados, pesoProporcional, recalcularPesosDesactualizados } from './pesosDesactualizados'
import { compraReducer, initialState } from '../components/modals/ModalCompra.reducer'
import type { CargoCompraForm, CompraItemForm, CompraState } from '../components/modals/ModalCompra.reducer'

const item = (lineaId: number, cantidad: number): CompraItemForm => ({
  productoId: String(500 + lineaId), productoNombre: `P${lineaId}`, cantidad, bonificacion: 0,
  costoUnitario: 100, impuestosInternos: 0, porcentajeIva: 21, condicionIva: 'gravado', stockActual: 0, lineaId,
})

const flete = (over: Partial<CargoCompraForm> = {}): CargoCompraForm => ({
  id: 1, concepto: 'Flete', monto: 9000, condicionIva: 'no_gravado', enFactura: false,
  prorrateaAlCosto: true, afectaBaseII: false, afectaBaseIIManual: true, baseProrrateo: 'cantidad',
  // 2 pallets de 120, 8 de 120, y el 500cc a medio pallet: no son las cantidades.
  pesos: { 1: 2, 2: 8, 3: 0.5, 4: 0 },
  pesosManuales: { 1: true, 2: true, 3: true, 4: true },
  cantidadesReferencia: { 1: 240, 2: 960, 3: 75, 4: 60 },
  ...over,
})

const items = (c1 = 240): CompraItemForm[] => [item(1, c1), item(2, 960), item(3, 75), item(4, 60)]

describe('pesosDesactualizados', () => {
  it('sin cambios de cantidad no hay nada desactualizado', () => {
    expect(pesosDesactualizados(flete(), items())).toEqual([])
  })

  it('cambiar la cantidad marca el peso manual, con el recalculado en proporción', () => {
    expect(pesosDesactualizados(flete(), items(480))).toEqual([
      { lineaId: 1, peso: 2, cantidadReferencia: 240, cantidadActual: 480, pesoRecalculado: 4 },
    ])
  })

  it('un 0 es exclusión y no escala', () => {
    const its = [item(1, 240), item(2, 960), item(3, 75), item(4, 600)]
    expect(pesosDesactualizados(flete(), its)).toEqual([])
  })

  it("sólo la base 'cantidad': 'unidades' es partes iguales y 'monto' no entra en esta regla", () => {
    expect(pesosDesactualizados(flete({ baseProrrateo: 'unidades' }), items(480))).toEqual([])
    expect(pesosDesactualizados(flete({ baseProrrateo: 'monto' }), items(480))).toEqual([])
  })

  it('en una compra nueva (sin referencia) nunca hay desactualizados', () => {
    expect(pesosDesactualizados(flete({ cantidadesReferencia: undefined }), items(480))).toEqual([])
  })

  it('un peso pre-llenado (no manual) no se marca: ya sigue a la cantidad', () => {
    expect(pesosDesactualizados(flete({ pesosManuales: { 2: true, 3: true, 4: true } }), items(480))).toEqual([])
  })

  it('la proporción va a 4 decimales y no inventa con referencia 0', () => {
    expect(pesoProporcional(0.5, 75, 100)).toBe(0.6667)
    expect(pesoProporcional(3, 0, 10)).toBe(3)
  })

  it('recalcular escala sólo los viejos, los deja manuales y mueve la referencia', () => {
    const r = recalcularPesosDesactualizados(flete(), items(480))
    expect(r.pesos).toEqual({ 1: 4, 2: 8, 3: 0.5, 4: 0 })
    expect(r.pesosManuales).toEqual({ 1: true, 2: true, 3: true, 4: true })
    expect(r.cantidadesReferencia).toEqual({ 1: 480, 2: 960, 3: 75, 4: 60 })
    expect(pesosDesactualizados(r, items(480))).toEqual([])
  })
})

describe('el reducer y los pesos desactualizados', () => {
  const estado = (): CompraState => ({ ...initialState, items: items(), cargos: [flete()] })

  it('cambiar la cantidad NO pisa el peso manual: lo deja marcado', () => {
    const s = compraReducer(estado(), { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 480 } })
    expect(s.cargos[0].pesos).toEqual({ 1: 2, 2: 8, 3: 0.5, 4: 0 })
    expect(pesosDesactualizados(s.cargos[0], s.items).map(d => d.lineaId)).toEqual([1])
  })

  it('"recalcular" lleva el peso a la cantidad nueva', () => {
    let s = compraReducer(estado(), { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 480 } })
    s = compraReducer(s, { type: 'RECALCULAR_PESOS_DESACTUALIZADOS', payload: { cargoId: 1 } })
    expect(s.cargos[0].pesos[1]).toBe(4)
    expect(pesosDesactualizados(s.cargos[0], s.items)).toEqual([])
  })

  it('tipear el peso a mano lo fija contra la cantidad de ahora', () => {
    let s = compraReducer(estado(), { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 480 } })
    s = compraReducer(s, { type: 'SET_PESO_CARGO', payload: { cargoId: 1, lineaId: 1, peso: 3 } })
    expect(s.cargos[0].pesos[1]).toBe(3)
    expect(s.cargos[0].cantidadesReferencia?.[1]).toBe(480)
    expect(pesosDesactualizados(s.cargos[0], s.items)).toEqual([])
  })

  it('re-elegir la base vuelve el cargo al pre-llenado y le saca la referencia', () => {
    const s = compraReducer(estado(), { type: 'ACTUALIZAR_CARGO', payload: { id: 1, cambios: { baseProrrateo: 'cantidad' } } })
    expect(s.cargos[0].cantidadesReferencia).toBeUndefined()
    expect(s.cargos[0].pesos).toEqual({ 1: 240, 2: 960, 3: 75, 4: 60 })
  })

  it('una línea agregada al editar entra a un cargo guardado con peso 0', () => {
    const producto = { id: '777', nombre: 'Nuevo', codigo: null, stock: 0, costo_sin_iva: 50, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' }
    const s = compraReducer(estado(), { type: 'AGREGAR_ITEM', payload: producto as never })
    const nueva = s.items[4].lineaId!
    expect(s.cargos[0].pesos[nueva]).toBe(0)
    expect(s.cargos[0].pesosManuales[nueva]).toBe(true)
    // Y el resto del vector, intacto.
    expect(s.cargos[0].pesos).toMatchObject({ 1: 2, 2: 8, 3: 0.5, 4: 0 })
  })

  it('en un cargo de carga (sin referencia) la línea nueva sí se pre-llena, como siempre', () => {
    const base = { ...estado(), cargos: [flete({ cantidadesReferencia: undefined, pesosManuales: {} })] }
    const producto = { id: '777', nombre: 'Nuevo', codigo: null, stock: 0, costo_sin_iva: 50, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' }
    const s = compraReducer(base, { type: 'AGREGAR_ITEM', payload: producto as never })
    expect(s.cargos[0].pesos[s.items[4].lineaId!]).toBe(1)
  })
})
