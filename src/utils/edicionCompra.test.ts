/**
 * Lo puro del modo 'editar' (utils/edicionCompra): payload, validaciones y
 * "cambios sin guardar". Porta el inventario de ModalEditarCompra, que se
 * retiró en la entrega B2; el test de punta a punta (abrir y guardar sin tocar
 * nada) está en ModalCompra.editar.test.tsx.
 */
import { describe, it, expect, vi } from 'vitest'

vi.mock('../lib/supabase', () => ({ supabase: { rpc: vi.fn(), from: vi.fn() } }))

import {
  armarEdicionCompra, edicionCompraTieneCambios, validarEdicionCompra, itemsConVencimientos,
  totalesDeEdicion, cargosLeidos,
} from './edicionCompra'
import { hidratarCompraGuardada } from './hidratarCompra'
import { calcularTotalesCompra } from './prorrateoCompra'
import { redondearSQL } from './calculations'
import {
  compraReducer, cargosParaMotor, iiDeclaradoParaMotor,
} from '../components/modals/ModalCompra.reducer'
import type { CompraState } from '../components/modals/ModalCompra.reducer'
import { compraTestigoEdicion } from '../test/fixtures/compraTestigoEdicion'
import type { CompraDBExtended } from '../types'

/** Los totales como los arma el modal (useCalculosImpuestos + totalesDeEdicion). */
function totalesDe(state: CompraState, compra: CompraDBExtended) {
  const base = calcularTotalesCompra(
    state.items, state.tipoFactura,
    { percepcionIva: state.percepcionIva, percepcionIibb: state.percepcionIibb, noGravado: state.noGravado, otrosImpuestos: Number(compra.otros_impuestos ?? 0) },
    cargosParaMotor(state.cargos), iiDeclaradoParaMotor(state.iiDeclarado, state.tipoFactura),
  )
  return totalesDeEdicion(compra, base)
}

function armar(compra: CompraDBExtended, state = hidratarCompraGuardada(compra).estado) {
  return armarEdicionCompra({ compra, state, totales: totalesDe(state, compra), usuarioId: 'u1' })
}

describe('armarEdicionCompra · sin tocar nada', () => {
  it('los totales recalculados son los guardados, al centavo', () => {
    const compra = compraTestigoEdicion()
    const p = armar(compra)
    expect(redondearSQL(p.subtotal, 2)).toBe(660000)
    expect(redondearSQL(p.iva, 2)).toBe(137340)
    expect(redondearSQL(p.impuestosInternos!, 2)).toBe(17400)
    expect(redondearSQL(p.total, 2)).toBe(813974.5)
    expect(p.bonificaciones).toBe(-6000)
    expect(p.noGravado).toBe(4000)
  })

  it('percepciones y otros impuestos NO viajan: la RPC conserva los suyos (pero entran al total)', () => {
    const compra = compraTestigoEdicion({ otros_impuestos: 500, total: 814474.5 })
    const p = armar(compra)
    expect(p.percepcionIva).toBeUndefined()
    expect(p.percepcionIibb).toBeUndefined()
    expect(p).not.toHaveProperty('otrosImpuestos')
    expect(redondearSQL(p.total, 2)).toBe(814474.5)
  })
})

describe('armarEdicionCompra · cargos e II declarado: null no es [] ni {}', () => {
  it('sin el embed de cargos manda null, y las bonificaciones guardadas entran al total', () => {
    const compra = compraTestigoEdicion({ cargos: undefined })
    expect(cargosLeidos(compra)).toBe(false)
    const p = armar(compra)
    expect(p.cargos).toBeNull()
    // No hay con qué recalcularlas: se reenvían las guardadas y suman.
    expect(p.bonificaciones).toBe(-6000)
    const sinCargos = calcularTotalesCompra(
      hidratarCompraGuardada(compra).estado.items, 'FC',
      { percepcionIva: 1234.5, noGravado: 4000 },
    )
    expect(p.total).toBeCloseTo(sinCargos.total - 6000, 6)
  })

  it('una compra sin cargos manda [] (es un dato, no "no sé")', () => {
    expect(armar(compraTestigoEdicion({ cargos: [], no_gravado: 0, bonificaciones: 0 })).cargos).toEqual([])
  })

  it('II declarado: null si la compra no tenía y no se tipeó; el guardado si tenía', () => {
    expect(armar(compraTestigoEdicion()).iiDeclarado).toBeNull()
    expect(armar(compraTestigoEdicion({ ii_declarado: { '10': 17000 } as never })).iiDeclarado).toEqual({ 10: 17000 })
  })

  it('II declarado borrado en la edición viaja como {} (la RPC lo deja en NULL)', () => {
    const compra = compraTestigoEdicion({ ii_declarado: { '10': 17000 } as never })
    const state = compraReducer(hidratarCompraGuardada(compra).estado, { type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 0 } })
    expect(armar(compra, state).iiDeclarado).toEqual({})
  })
})

describe('armarEdicionCompra · bonificaciones y no gravado RECALCULADOS', () => {
  it('editar el monto de la bonificación cambia `bonificaciones` (antes se reenviaba la guardada)', () => {
    const compra = compraTestigoEdicion()
    const { estado } = hidratarCompraGuardada(compra)
    const bonif = estado.cargos.find(c => c.concepto === 'Bonificacion 3L')!
    const state = compraReducer(estado, { type: 'ACTUALIZAR_CARGO', payload: { id: bonif.id, cambios: { monto: -7000 } } })
    expect(armar(compra, state).bonificaciones).toBe(-7000)
  })

  it('el no gravado sigue a los pallets si no estaba tipeado', () => {
    const compra = compraTestigoEdicion()
    const { estado } = hidratarCompraGuardada(compra)
    const pallets = estado.cargos.find(c => c.concepto === 'Pallets')!
    const state = compraReducer(estado, { type: 'ACTUALIZAR_CARGO', payload: { id: pallets.id, cambios: { monto: 5000 } } })
    expect(armar(compra, state).noGravado).toBe(5000)
  })

  it('y si lo guardado no coincidía con los cargos (tipeado), se respeta', () => {
    const compra = compraTestigoEdicion({ no_gravado: 4500, total: 814474.5 })
    const { estado } = hidratarCompraGuardada(compra)
    const pallets = estado.cargos.find(c => c.concepto === 'Pallets')!
    const state = compraReducer(estado, { type: 'ACTUALIZAR_CARGO', payload: { id: pallets.id, cambios: { monto: 5000 } } })
    expect(armar(compra, state).noGravado).toBe(4500)
  })

  it('en ZZ: no gravado 0, y condición/alícuota normalizadas como las guarda la RPC', () => {
    const compra = compraTestigoEdicion({ tipo_factura: 'ZZ', no_gravado: 0 })
    const p = armar(compra)
    expect(p.noGravado).toBe(0)
    for (const it of p.items) expect(it).toMatchObject({ condicionIva: 'gravado', porcentajeIva: 0, impuestosInternos: 0 })
  })
})

describe('validarEdicionCompra', () => {
  const hidratado = () => hidratarCompraGuardada(compraTestigoEdicion()).estado

  it('lo guardado, sin tocar, valida', () => {
    expect(validarEdicionCompra(hidratado())).toBeNull()
  })

  it('sin líneas no se guarda: se anula', () => {
    expect(validarEdicionCompra({ ...hidratado(), items: [] })).toMatch(/al menos un item/)
  })

  it('el cargo huérfano: borrar la única línea donde pesaba la bonificación', () => {
    const s = compraReducer(hidratado(), { type: 'ELIMINAR_ITEM', payload: 2 }) // Gaseosa 3L
    expect(validarEdicionCompra(s)).toMatch(/"Bonificacion 3L" se quedaría sin ninguna línea/)
  })

  it('bonificación de línea en [0, 100)', () => {
    const s = compraReducer(hidratado(), { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'bonificacion', valor: 100 } })
    expect(validarEdicionCompra(s)).toMatch(/Bonificación fuera de rango en "Agua 600 x12"/)
  })

  it('cantidad entera y positiva', () => {
    const s = compraReducer(hidratado(), { type: 'ACTUALIZAR_ITEM', payload: { index: 1, campo: 'cantidad', valor: 0 } })
    expect(validarEdicionCompra(s)).toMatch(/Cantidad inválida en "Agua 2L"/)
  })

  it('vencimientos que exceden la línea', () => {
    const s = compraReducer(hidratado(), { type: 'SET_VENCIMIENTOS_ITEM', payload: { index: 2, vencimientos: [{ fecha: '2027-01-01', cantidad: 61 }] } })
    expect(validarEdicionCompra(s)).toMatch(/"Gaseosa 3L": etiquetaste 61 u\..*la línea tiene 60/)
  })

  it('un cargo sin concepto lo frena validarCargos', () => {
    const s0 = hidratado()
    const s = compraReducer(s0, { type: 'ACTUALIZAR_CARGO', payload: { id: s0.cargos[0].id, cambios: { concepto: '  ' } } })
    expect(validarEdicionCompra(s)).toMatch(/cargo sin concepto/)
  })
})

describe('edicionCompraTieneCambios (traba de "Cambiar proveedor")', () => {
  const hidratado = () => hidratarCompraGuardada(compraTestigoEdicion()).estado

  it('lo hidratado contra sí mismo no tiene cambios, aunque pase por el reducer', () => {
    const ref = hidratado()
    const tocadoYVuelto = compraReducer(
      compraReducer(ref, { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 241 } }),
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 240 } },
    )
    expect(edicionCompraTieneCambios(ref, ref)).toBe(false)
    expect(edicionCompraTieneCambios(ref, tocadoYVuelto)).toBe(false)
  })

  it('cuenta una línea, un borrado, un cargo, un peso, un vencimiento, el no gravado y el II', () => {
    const ref = hidratado()
    const flete = ref.cargos[0]
    const casos: Array<Parameters<typeof compraReducer>[1]> = [
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'costoUnitario', valor: 999 } },
      { type: 'ELIMINAR_ITEM', payload: 3 },
      { type: 'ACTUALIZAR_CARGO', payload: { id: flete.id, cambios: { monto: 9500 } } },
      { type: 'ACTUALIZAR_CARGO', payload: { id: flete.id, cambios: { enFactura: true } } },
      { type: 'SET_PESO_CARGO', payload: { cargoId: flete.id, lineaId: 4, peso: 1 } },
      { type: 'ELIMINAR_CARGO', payload: flete.id },
      { type: 'AGREGAR_CARGO' },
      { type: 'SET_VENCIMIENTOS_ITEM', payload: { index: 0, vencimientos: [{ fecha: '2027-01-01', cantidad: 5 }] } },
      { type: 'SET_EXTRAS', payload: { noGravado: 1 } },
      { type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 17000 } },
    ]
    for (const accion of casos) {
      expect(edicionCompraTieneCambios(ref, compraReducer(ref, accion)), accion.type).toBe(true)
    }
  })

  it('los vencimientos precargados son la referencia, no un cambio', () => {
    const lotes = [{ producto_id: 503, fecha_vencimiento: '2027-03-01', cantidad: 60 }]
    const ref = { ...hidratado(), items: itemsConVencimientos(hidratado().items, lotes) }
    const state = compraReducer(hidratado(), { type: 'PRECARGAR_VENCIMIENTOS', payload: { '503': [{ fecha: '2027-03-01', cantidad: 60 }] } })
    expect(edicionCompraTieneCambios(ref, state)).toBe(false)
  })
})
