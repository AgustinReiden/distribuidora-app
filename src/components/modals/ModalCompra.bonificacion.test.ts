/**
 * #908 · Bonificación no descontada, a nivel reducer: la sugerencia que arma el
 * formulario y las dos acciones que la resuelven (agregar / descartar).
 *
 * Datos sintéticos.
 */
import { describe, it, expect } from 'vitest'
import {
  compraReducer, initialState, sugerenciasBonificacion, cargosParaMotor, alicuotasIIExplicadas,
  cuadreImpuestoInterno, resolucionBasesII, validarCargos,
} from './ModalCompra.reducer'
import type { CompraItemForm, CompraState } from './ModalCompra.reducer'
import type { CargoPlantillaCompra } from '../../types'
import type { ConceptoCargo } from '../../utils/medidasCargo'
import { redondearSQL } from '../../utils/calculations'
import { calcularCostosCompra } from '../../utils/prorrateoCompra'

type Accion = Parameters<typeof compraReducer>[1]
const correr = (acciones: Accion[], desde: CompraState = initialState): CompraState =>
  acciones.reduce(compraReducer, desde)

const T = 8.6957
const item = (productoId: string, cantidad: number, costoUnitario: number, impuestosInternos: number,
  extra: Partial<CompraItemForm> = {}): CompraItemForm => ({
  productoId, productoNombre: `Prod ${productoId}`, cantidad, bonificacion: 0, costoUnitario,
  impuestosInternos, porcentajeIva: 21, condicionIva: 'gravado', stockActual: 0, ...extra,
})

const ITEMS = [
  item('cola3', 100, 5000, T),     // neto 500.000
  item('cola600', 80, 4500, T),    // neto 360.000
  item('soda', 40, 1500, 0),       // neto  60.000
  item('pinda', 30, 3000, 0, { condicionIva: 'exento', porcentajeIva: 0 }),
]
const BONIF = 25_000
const DECLARADO = redondearSQL((860_000 + BONIF) * T / 100, 2)

const CONCEPTO: ConceptoCargo = {
  id: '13', nombre: 'Bonificación', signo: -1, condicionIva: 'gravado', enFactura: true,
  prorrateaAlCosto: true, baseProrrateo: 'monto', medidaId: null, activo: true,
}

const conFactura = () => correr([
  { type: 'IMPORTAR_ITEMS', payload: ITEMS },
  { type: 'SET_II_DECLARADO', payload: { tasa: T, monto: DECLARADO } },
])

const control = (s: CompraState, gravadoImpreso: number) => {
  const r = calcularCostosCompra(
    s.items.map(i => ({ id: i.lineaId!, cantidad: i.cantidad, costoUnitario: i.costoUnitario, bonificacion: i.bonificacion,
      impuestosInternos: i.impuestosInternos, porcentajeIva: i.porcentajeIva, condicionIva: i.condicionIva })),
    cargosParaMotor(s.cargos), {})
  return { gravadoImpreso, gravadoCalculado: r.totales.netoGravado, totalImpreso: 0, totalCalculado: 0 }
}

describe('sugerenciasBonificacion (borde del formulario)', () => {
  it('con el gravado del papel, sugiere el monto exacto sobre las líneas del 8,6957%', () => {
    const s = conFactura()
    const [sug, ...resto] = sugerenciasBonificacion(s, control(s, 920_000 - BONIF), null)
    expect(resto).toEqual([])
    expect(sug.monto).toBe(BONIF)
    expect(sug.lineaIds).toEqual([1, 2])
  })

  it('en ZZ no sugiere nada', () => {
    const s = correr([{ type: 'SET_TIPO_FACTURA', payload: 'ZZ' }], conFactura())
    expect(sugerenciasBonificacion(s, null, null)).toEqual([])
  })

  it('el alcance de la compra anterior manda sobre la alícuota entera', () => {
    const plantilla: CargoPlantillaCompra[] = [{
      concepto: 'Bonificación', condicionIva: 'gravado', enFactura: true, prorrateaAlCosto: true,
      afectaBaseII: false, baseProrrateo: 'monto', pesosPorProducto: { cola3: 1, soda: 1 },
    }]
    expect(sugerenciasBonificacion(conFactura(), null, plantilla)[0].lineaIds).toEqual([1])
  })
})

describe('AGREGAR_BONIFICACION_SUGERIDA', () => {
  const aceptar = (s: CompraState, concepto: ConceptoCargo | null = CONCEPTO) => {
    const [sug] = sugerenciasBonificacion(s, control(s, 920_000 - BONIF), null)
    return correr([{ type: 'AGREGAR_BONIFICACION_SUGERIDA', payload: { sugerencia: sug, concepto } }], s)
  }

  it('agrega el cargo del catálogo: −Y, gravado, en factura, base monto, sólo sobre el alcance', () => {
    const s = aceptar(conFactura())
    expect(s.cargos).toHaveLength(1)
    const c = s.cargos[0]
    expect(c).toMatchObject({
      concepto: 'Bonificación', conceptoId: '13', monto: -BONIF, condicionIva: 'gravado',
      enFactura: true, prorrateaAlCosto: true, baseProrrateo: 'monto', afectaBaseII: false,
      afectaBaseIIManual: false,
    })
    // Pre-llenado por neto en las del 8,6957%; la soda y el Pindapoy en 0.
    expect(c.pesos).toEqual({ 1: 500_000, 2: 360_000, 3: 0, 4: 0 })
    expect(c.pesosManuales).toEqual({})
  })

  it('después de agregarla la sugerencia desaparece', () => {
    const s = aceptar(conFactura())
    expect(sugerenciasBonificacion(s, control(s, 920_000 - BONIF), null)).toEqual([])
  })

  it('una línea que se agrega después queda fuera de la bonificación', () => {
    const s = correr([{ type: 'IMPORTAR_ITEMS', payload: [item('soda2', 10, 1000, 0)] }], aceptar(conFactura()))
    expect(s.cargos[0].pesos[5]).toBe(0)
    // Y la del alcance sigue al neto si cambia la cantidad.
    const t = correr([{ type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 50 } }], s)
    expect(t.cargos[0].pesos[1]).toBe(250_000)
  })

  it('sin catálogo cargado, usa el nombre "Bonificación" sin id', () => {
    const c = aceptar(conFactura(), null).cargos[0]
    expect(c.concepto).toBe('Bonificación')
    expect(c.conceptoId).toBeNull()
  })

  it('reemplaza el renglón de bonificación que trajo la plantilla sin monto', () => {
    const s = correr([{
      type: 'APLICAR_PLANTILLA_PROVEEDOR',
      payload: { proveedorId: 'p', cargos: [
        { concepto: 'Bonificación', condicionIva: 'gravado', enFactura: true, prorrateaAlCosto: true,
          afectaBaseII: false, baseProrrateo: 'monto', pesosPorProducto: { cola3: 1 } },
        { concepto: 'Flete', condicionIva: 'no_gravado', enFactura: false, prorrateaAlCosto: true,
          afectaBaseII: false, baseProrrateo: 'monto', pesosPorProducto: { cola3: 1 } },
      ] },
    }], conFactura())
    const r = aceptar(s)
    expect(r.cargos.map(c => c.concepto)).toEqual(['Flete', 'Bonificación'])
    expect(r.cargos[1].monto).toBe(-BONIF)
  })

  it('una sugerencia sin líneas vigentes no hace nada', () => {
    const s = conFactura()
    const r = correr([{
      type: 'AGREGAR_BONIFICACION_SUGERIDA',
      payload: { sugerencia: { clave: 'ii:8.6957', caso: 'impuesto_interno', tasa: T, diferenciaII: 1, baseImplicita: 1, monto: 1, origenMonto: 'impuesto_interno', lineaIds: [99], alcance: 'alicuota' }, concepto: CONCEPTO },
    }], s)
    expect(r).toBe(s)
  })
})

describe('DESCARTAR_BONIFICACION_SUGERIDA', () => {
  it('oculta la sugerencia de esa alícuota y no toca los cargos', () => {
    const s = correr([{ type: 'DESCARTAR_BONIFICACION_SUGERIDA', payload: { clave: `ii:${T}` } }], conFactura())
    expect(s.bonificacionesDescartadas).toEqual([`ii:${T}`])
    expect(s.cargos).toEqual([])
    expect(sugerenciasBonificacion(s, null, null)).toEqual([])
  })

  it('descartar dos veces no duplica', () => {
    const s = correr([
      { type: 'DESCARTAR_BONIFICACION_SUGERIDA', payload: { clave: `ii:${T}` } },
      { type: 'DESCARTAR_BONIFICACION_SUGERIDA', payload: { clave: `ii:${T}` } },
    ], conFactura())
    expect(s.bonificacionesDescartadas).toEqual([`ii:${T}`])
  })
})

describe('caso B · II que cierra y gravado del papel más bajo', () => {
  const II_CIERRA = redondearSQL(860_000 * T / 100, 2)
  const conFacturaB = () => correr([
    { type: 'IMPORTAR_ITEMS', payload: ITEMS },
    { type: 'SET_II_DECLARADO', payload: { tasa: T, monto: II_CIERRA } },
  ])

  it('sugiere el monto exacto sobre la única alícuota con II', () => {
    const s = conFacturaB()
    const [sug, ...resto] = sugerenciasBonificacion(s, control(s, 920_000 - BONIF), null)
    expect(resto).toEqual([])
    expect(sug).toMatchObject({ caso: 'papel', monto: BONIF, lineaIds: [1, 2], alcance: 'alicuota' })
  })

  it('al aceptarla, afectaBaseII queda en false A MANO y el II sigue cerrando con el solver corriendo', () => {
    const s = conFacturaB()
    const [sug] = sugerenciasBonificacion(s, control(s, 920_000 - BONIF), null)
    const r = correr([{ type: 'AGREGAR_BONIFICACION_SUGERIDA', payload: { sugerencia: sug, concepto: CONCEPTO } }], s)
    expect(r.cargos[0]).toMatchObject({ monto: -BONIF, afectaBaseII: false, afectaBaseIIManual: true })
    expect(r.cargos[0].pesos).toEqual({ 1: 500_000, 2: 360_000, 3: 0, 4: 0 })
    const [cuadre] = cuadreImpuestoInterno(r.items, r.cargos, r.iiDeclarado, r.tipoFactura)!
    expect(Math.abs(cuadre.declarado! - cuadre.calculado)).toBeLessThan(0.01)
    expect(resolucionBasesII(r.items, r.cargos, r.iiDeclarado, r.tipoFactura)!.estado).not.toBe('sin_solucion')
    // Y desaparece.
    expect(sugerenciasBonificacion(r, control(r, 920_000 - BONIF), null)).toEqual([])
  })

  it('sin alcance (dos alícuotas, sin compra anterior): entra con todo en 0 y el guardado pide elegir líneas', () => {
    const s = correr([
      { type: 'IMPORTAR_ITEMS', payload: [...ITEMS, item('lima', 60, 4000, 4.1667)] },
      { type: 'SET_II_DECLARADO', payload: { tasa: T, monto: II_CIERRA } },
      { type: 'SET_II_DECLARADO', payload: { tasa: 4.1667, monto: 10_000.08 } },
    ])
    const [sug] = sugerenciasBonificacion(s, control(s, 1_160_000 - BONIF), null)
    expect(sug).toMatchObject({ caso: 'papel', alcance: 'sin_alcance', lineaIds: [] })
    const r = correr([{ type: 'AGREGAR_BONIFICACION_SUGERIDA', payload: { sugerencia: sug, concepto: CONCEPTO } }], s)
    expect(Object.values(r.cargos[0].pesos).every(p => p === 0)).toBe(true)
    expect(validarCargos(r.cargos)).toMatch(/ninguna línea asignada/)
    // El usuario elige la Cola 3L: queda, y una línea nueva no se suma sola.
    const t = correr([
      { type: 'SET_PESO_CARGO', payload: { cargoId: r.cargos[0].id, lineaId: 1, peso: 1 } },
      { type: 'IMPORTAR_ITEMS', payload: [item('otra', 1, 100, T)] },
    ], r)
    expect(t.cargos[0].pesos[1]).toBe(1)
    expect(t.cargos[0].pesos[6]).toBe(0)
    expect(validarCargos(t.cargos)).toBeNull()
  })
})

describe('alicuotasIIExplicadas (el resumen después de aceptar el caso A)', () => {
  it('antes de aceptar no hay alícuota explicada; después, la del 8,6957% sí', () => {
    const s = conFactura()
    expect(alicuotasIIExplicadas(s)).toEqual([])
    const [sug] = sugerenciasBonificacion(s, null, null)
    const r = correr([{ type: 'AGREGAR_BONIFICACION_SUGERIDA', payload: { sugerencia: sug, concepto: CONCEPTO } }], s)
    expect(alicuotasIIExplicadas(r)).toEqual([T])
  })

  it('en ZZ, nada', () => {
    expect(alicuotasIIExplicadas({ ...conFactura(), tipoFactura: 'ZZ' })).toEqual([])
  })
})
