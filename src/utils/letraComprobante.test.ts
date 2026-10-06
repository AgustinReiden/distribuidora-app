import { describe, it, expect } from 'vitest'
import {
  avisoLetra, comprobanteDe, desdeComprobante, etiquetaComprobante, ivaComputable, letraEfectiva,
  normalizarLetra, tipoParaCosto,
} from './letraComprobante'
import { calcularTotalesCompra } from './prorrateoCompra'
import { compraReducer, initialState } from '../components/modals/ModalCompra.reducer'

describe('letra del comprobante (mig 293)', () => {
  it('la tabla del dueño: A/M discriminan IVA, B/C y ZZ cuestan lo pagado', () => {
    expect(['A', 'B', 'C', 'M'].map(l => [l, ivaComputable('FC', l as 'A'), tipoParaCosto('FC', l as 'A')])).toEqual([
      ['A', true, 'FC'], ['B', false, 'ZZ'], ['C', false, 'ZZ'], ['M', true, 'FC'],
    ])
    expect([ivaComputable('ZZ', null), tipoParaCosto('ZZ', null)]).toEqual([false, 'ZZ'])
  })

  it('una FC sin letra es A (legado); una ZZ nunca tiene letra', () => {
    expect(letraEfectiva('FC', null)).toBe('A')
    expect(letraEfectiva('FC', undefined)).toBe('A')
    expect(letraEfectiva('ZZ', 'B')).toBeNull()
    expect(tipoParaCosto('FC', null)).toBe('FC')
  })

  it('normaliza lo que venga y rechaza lo que no es una letra', () => {
    expect(normalizarLetra(' m ')).toBe('M')
    expect(normalizarLetra('X')).toBeNull()
    expect(normalizarLetra(null)).toBeNull()
    expect(normalizarLetra(3)).toBeNull()
  })

  it('comprobante ↔ tipo y letra, ida y vuelta', () => {
    expect(desdeComprobante('SF')).toEqual({ tipoFactura: 'ZZ', letraComprobante: null })
    expect(desdeComprobante('B')).toEqual({ tipoFactura: 'FC', letraComprobante: 'B' })
    expect(comprobanteDe('ZZ', null)).toBe('SF')
    expect(comprobanteDe('FC', null)).toBe('A')
    expect(etiquetaComprobante('FC', 'B')).toBe('FC B')
    expect(etiquetaComprobante('ZZ', null)).toBe('ZZ')
  })

  it('avisa B y M, no A, C ni ZZ', () => {
    expect(avisoLetra('FC', 'B')).toBe('Una factura B a un responsable inscripto es un error: pedile al proveedor la factura A.')
    expect(avisoLetra('FC', 'M')).toBe('Factura M: corresponde retenerle IVA y Ganancias al pagar (RG 1575).')
    expect([avisoLetra('FC', 'A'), avisoLetra('FC', 'C'), avisoLetra('ZZ', null)]).toEqual([null, null, null])
  })
})

describe('calcularTotalesCompra con letra (espejo de v_sin_credito)', () => {
  const items = [
    { cantidad: 10, costoUnitario: 100, porcentajeIva: 21, impuestosInternos: 10, lineaId: 1 },
    { cantidad: 5, costoUnitario: 200, porcentajeIva: 10.5, condicionIva: 'exento' as const, lineaId: 2 },
  ]
  const extras = { percepcionIva: 30, percepcionIibb: 20, noGravado: 7 }

  it('FC sin letra, A y M dan bit a bit lo mismo que antes de la letra', () => {
    const antes = calcularTotalesCompra(items, 'FC', extras, [], { 10: 105 })
    expect(calcularTotalesCompra(items, 'FC', extras, [], { 10: 105 }, null)).toEqual(antes)
    expect(calcularTotalesCompra(items, 'FC', extras, [], { 10: 105 }, 'A')).toEqual(antes)
    expect(calcularTotalesCompra(items, 'FC', extras, [], { 10: 105 }, 'M')).toEqual(antes)
  })

  it('ZZ da lo mismo con o sin letra', () => {
    expect(calcularTotalesCompra(items, 'ZZ', extras, [], {}, null)).toEqual(calcularTotalesCompra(items, 'ZZ', extras))
  })

  it('B y C: el IVA, el II y la apertura como ZZ; las percepciones y el no gravado como factura', () => {
    const zz = calcularTotalesCompra(items, 'ZZ', extras)
    for (const letra of ['B', 'C'] as const) {
      const t = calcularTotalesCompra(items, 'FC', extras, [], { 10: 105 }, letra)
      expect(t.iva).toBe(0)
      expect(t.impuestosInternos).toBe(0)
      expect(t.netoPorAlicuota).toEqual({})
      expect(t.subtotal).toBe(zz.subtotal)
      expect([t.percepcionIva, t.percepcionIibb, t.noGravado]).toEqual([30, 20, 7])
      expect(t.total).toBe(zz.subtotal + 30 + 20 + 7)
    }
  })
})

describe('reducer: el comprobante', () => {
  it('arranca en FC A; "sin factura" es ZZ sin letra; volver a una letra es FC', () => {
    expect([initialState.tipoFactura, initialState.letraComprobante]).toEqual(['FC', 'A'])
    const zz = compraReducer(initialState, { type: 'SET_COMPROBANTE', payload: 'SF' })
    expect([zz.tipoFactura, zz.letraComprobante]).toEqual(['ZZ', null])
    const b = compraReducer(zz, { type: 'SET_COMPROBANTE', payload: 'B' })
    expect([b.tipoFactura, b.letraComprobante]).toEqual(['FC', 'B'])
  })

  it('SET_TIPO_FACTURA (el FC/ZZ de antes) sigue funcionando: a FC sin letra cae en A', () => {
    const zz = compraReducer(initialState, { type: 'SET_TIPO_FACTURA', payload: 'ZZ' })
    expect(zz.letraComprobante).toBeNull()
    expect(compraReducer(zz, { type: 'SET_TIPO_FACTURA', payload: 'FC' }).letraComprobante).toBe('A')
  })

  it('el escaneo trae la letra con el tipo; sin tipo leído no toca la letra', () => {
    const base = { proveedorId: '', proveedorNombre: '', numeroFactura: '', fechaCompra: '', formaPago: '', items: [], pendientes: [] }
    const conM = compraReducer(initialState, { type: 'APLICAR_ESCANEO', payload: { ...base, tipoFactura: 'FC', letraComprobante: 'M' } })
    expect([conM.tipoFactura, conM.letraComprobante]).toEqual(['FC', 'M'])
    const sinTipo = compraReducer(conM, { type: 'APLICAR_ESCANEO', payload: { ...base, tipoFactura: null, letraComprobante: null } })
    expect([sinTipo.tipoFactura, sinTipo.letraComprobante]).toEqual(['FC', 'M'])
  })
})
