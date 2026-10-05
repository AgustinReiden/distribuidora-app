/**
 * #866 (mig 281) — el IVA del flete con factura del transportista. Vive adentro
 * del cargo: sólo para un cargo gravado que NO viene en la factura del
 * proveedor, viaja únicamente cuando aplica, y la hidratación de una compra
 * guardada lo devuelve tal cual. Datos sintéticos.
 */
import { describe, it, expect, vi } from 'vitest'

vi.mock('../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn(), storage: { from: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
import {
  compraReducer, initialState, cargosParaRPC,
  aplicaComprobanteTercero, ivaTerceroPorDefecto, ivaTerceroEfectivo,
} from './ModalCompra.reducer'
import type { CompraState } from './ModalCompra.reducer'
import type { ProductoDB } from '../../types'
import { paramsActualizarCompraItems } from '../../hooks/queries/useComprasQuery'
import { hidratarCompraGuardada } from '../../utils/hidratarCompra'
import { edicionCompraTieneCambios } from '../../utils/edicionCompra'
import { compraTestigoEdicion } from '../../test/fixtures/compraTestigoEdicion'

type Accion = Parameters<typeof compraReducer>[1]
const correr = (acciones: Accion[], desde: CompraState = initialState): CompraState =>
  acciones.reduce(compraReducer, desde)

const producto = { id: 'a', nombre: 'A', codigo: 'a', costo_sin_iva: 100, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado', stock: 1 } as unknown as ProductoDB

/** Una línea y un flete de 5.000 gravado, fuera de la factura, con factura del transportista. */
function conFleteTercero(cambios: Record<string, unknown> = {}) {
  const base = correr([{ type: 'AGREGAR_ITEM', payload: producto }, { type: 'AGREGAR_CARGO' }])
  const id = base.cargos[0].id
  return correr([{ type: 'ACTUALIZAR_CARGO', payload: { id, cambios: {
    concepto: 'Flete', monto: 5000, condicionIva: 'gravado', enFactura: false,
    comprobanteTercero: true, terceroNombre: '  Transportes Sintéticos ', terceroComprobante: 'A-0001-00000042',
    ...cambios,
  } } }], base)
}

describe('aplicaComprobanteTercero', () => {
  it('sólo un cargo gravado que no viene en la factura del proveedor', () => {
    expect(aplicaComprobanteTercero({ enFactura: false, condicionIva: 'gravado' })).toBe(true)
    expect(aplicaComprobanteTercero({ enFactura: true, condicionIva: 'gravado' })).toBe(false)
    expect(aplicaComprobanteTercero({ enFactura: false, condicionIva: 'no_gravado' })).toBe(false)
    expect(aplicaComprobanteTercero({ enFactura: false, condicionIva: 'exento' })).toBe(false)
  })
})

describe('IVA del tercero', () => {
  it('por defecto es el 21% del monto y lo sigue mientras nadie lo tipee', () => {
    expect(ivaTerceroPorDefecto(5000)).toBe(1050)
    expect(ivaTerceroPorDefecto(333.33)).toBe(70)
    expect(ivaTerceroEfectivo({ monto: 5000, ivaTercero: null })).toBe(1050)
    expect(ivaTerceroEfectivo({ monto: 5000, ivaTercero: 1000 })).toBe(1000)
  })
})

describe('cargosParaRPC con factura de un tercero', () => {
  it('viaja con el IVA (21% por defecto) y los datos del transportista, recortados', () => {
    const s = conFleteTercero()
    expect(cargosParaRPC(s.items, s.cargos)[0]).toMatchObject({
      comprobanteTercero: true, ivaMonto: 1050,
      terceroNombre: 'Transportes Sintéticos', terceroComprobante: 'A-0001-00000042',
    })
  })

  it('el IVA tipeado gana sobre el 21%', () => {
    const s = conFleteTercero({ ivaTercero: 987.65 })
    expect(cargosParaRPC(s.items, s.cargos)[0].ivaMonto).toBe(987.65)
  })

  it('si deja de aplicar (pasa a "viene en la factura" o a no gravado) no viaja nada', () => {
    for (const cambios of [{ enFactura: true }, { condicionIva: 'no_gravado' }]) {
      const s = conFleteTercero(cambios)
      const cargo = cargosParaRPC(s.items, s.cargos)[0]
      expect(cargo).not.toHaveProperty('comprobanteTercero')
      expect(cargo).not.toHaveProperty('ivaMonto')
    }
  })

  it('un cargo común no cambia de forma (sin claves nuevas)', () => {
    const s = conFleteTercero({ comprobanteTercero: false })
    const cargo = cargosParaRPC(s.items, s.cargos)[0]
    expect(Object.keys(cargo).sort()).toEqual([
      'afectaBaseII', 'baseProrrateo', 'concepto', 'conceptoId', 'condicionIva', 'enFactura',
      'medidaId', 'monto', 'pesos', 'prorrateaAlCosto',
    ])
  })

  it('el serializado a la RPC lleva las claves de la mig 281 en snake_case', () => {
    const s = conFleteTercero({ ivaTercero: 1000 })
    const params = paramsActualizarCompraItems({
      compraId: '1', items: [], subtotal: 0, iva: 0, total: 0, usuarioId: 'u1',
      cargos: cargosParaRPC(s.items, s.cargos),
    } as never)
    expect((params.p_cargos as Array<Record<string, unknown>>)[0]).toMatchObject({
      comprobante_tercero: true, iva_monto: 1000,
      tercero_nombre: 'Transportes Sintéticos', tercero_comprobante: 'A-0001-00000042',
    })
  })
})

describe('compra guardada con flete de un tercero', () => {
  const guardada = () => {
    const c = compraTestigoEdicion()
    c.cargos = c.cargos!.map(k => k.concepto === 'Flete'
      ? { ...k, condicion_iva: 'gravado', comprobante_tercero: true, iva_monto: '1890.00', tercero_nombre: 'Transportes Sintéticos', tercero_comprobante: 'A-0001-00000042' }
      : k)
    return c
  }

  it('la hidratación trae el IVA guardado como número, no como 21% del monto', () => {
    const { estado } = hidratarCompraGuardada(guardada())
    const flete = estado.cargos.find(c => c.concepto === 'Flete')!
    expect(flete).toMatchObject({
      comprobanteTercero: true, ivaTercero: 1890,
      terceroNombre: 'Transportes Sintéticos', terceroComprobante: 'A-0001-00000042',
    })
    // 21% de 9.000 sería 1.890 también: el guardado no depende de eso.
    expect(cargosParaRPC(estado.items, estado.cargos).find(c => c.concepto === 'Flete')).toMatchObject({
      comprobanteTercero: true, ivaMonto: 1890,
    })
  })

  it('una fila anterior a la mig 281 hidrata sin tercero', () => {
    const { estado } = hidratarCompraGuardada(compraTestigoEdicion())
    expect(estado.cargos.every(c => !c.comprobanteTercero && c.ivaTercero == null)).toBe(true)
  })

  it('tocar el IVA, el transportista o el comprobante es un cambio sin guardar', () => {
    const { estado } = hidratarCompraGuardada(guardada())
    const flete = estado.cargos.find(c => c.concepto === 'Flete')!
    for (const cambios of [{ ivaTercero: 1900 }, { terceroNombre: 'Otro' }, { terceroComprobante: 'B-1' }, { comprobanteTercero: false }]) {
      const tocado = compraReducer(estado, { type: 'ACTUALIZAR_CARGO', payload: { id: flete.id, cambios } })
      expect(edicionCompraTieneCambios(estado, tocado)).toBe(true)
    }
    expect(edicionCompraTieneCambios(estado, estado)).toBe(false)
  })
})
