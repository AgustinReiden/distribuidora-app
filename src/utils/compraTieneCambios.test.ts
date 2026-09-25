import { describe, it, expect } from 'vitest'
import { compraTieneCambios } from './compraTieneCambios'
import { compraReducer, initialState } from '../components/modals/ModalCompra.reducer'
import type { CompraActionType, CompraState, FacturaEscaneada } from '../components/modals/ModalCompra.reducer'
import type { ProductoDB } from '../types'

/**
 * Los estados salen del reducer real, a partir del estado con el que arranca el
 * modal: así se prueba lo que el formulario puede producir y no un objeto que
 * el reducer nunca armaría.
 */
const tras = (...acciones: CompraActionType[]): CompraState =>
  acciones.reduce(compraReducer, initialState)

const ACEITE = {
  id: 'p1',
  nombre: 'Aceite Girasol 900ml',
  codigo: 'ACE900',
  stock: 12,
  costo_sin_iva: 100,
  impuestos_internos: 0,
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
} as unknown as ProductoDB

const ITEM_ESCANEADO = {
  codigo: null,
  descripcion: 'Gaseosa Cola 2.25L',
  cantidad: 6,
  costoUnitario: 900,
  bonificacion: 0,
  iva: 21,
}

const FACTURA: FacturaEscaneada = {
  proveedorNombre: 'Manaos SA',
  proveedorCuit: '30-11111111-1',
  numeroFactura: '0001-00012345',
  fechaCompra: '2026-09-15',
  items: [ITEM_ESCANEADO],
  subtotal: 5400,
  iva: 1134,
  total: 6534,
  formaPago: 'efectivo',
  confianza: 0.9,
}

describe('compraTieneCambios', () => {
  it('el modal recién abierto no tiene nada que perder', () => {
    expect(compraTieneCambios(initialState)).toBe(false)
  })

  describe('cuenta lo que viaja en la compra', () => {
    it.each<[string, CompraActionType[]]>([
      ['un proveedor elegido', [{ type: 'SET_PROVEEDOR_ID', payload: 'prov-1' }]],
      ['el nombre de un proveedor nuevo', [{ type: 'SET_PROVEEDOR_NOMBRE', payload: 'Proveedor Nuevo SRL' }]],
      ['el modo "proveedor nuevo", aun sin nombre', [{ type: 'SET_USAR_PROVEEDOR_NUEVO', payload: true }]],
      ['el comprobante pasado a ZZ', [{ type: 'SET_TIPO_FACTURA', payload: 'ZZ' }]],
      ['el número de factura', [{ type: 'SET_NUMERO_FACTURA', payload: '0001-00012345' }]],
      ['otra fecha de compra', [{ type: 'SET_FECHA_COMPRA', payload: '2020-01-31' }]],
      ['la fecha borrada', [{ type: 'SET_FECHA_COMPRA', payload: '' }]],
      ['otra forma de pago', [{ type: 'SET_FORMA_PAGO', payload: 'transferencia' }]],
      ['notas', [{ type: 'SET_NOTAS', payload: 'Entregó el chofer nuevo' }]],
      ['una línea', [{ type: 'AGREGAR_ITEM', payload: ACEITE }]],
      ['un cargo, aunque todavía no tenga concepto', [{ type: 'AGREGAR_CARGO' }]],
      ['la percepción de IVA', [{ type: 'SET_EXTRAS', payload: { percepcionIva: 30 } }]],
      ['la percepción de IIBB', [{ type: 'SET_EXTRAS', payload: { percepcionIibb: 15 } }]],
      ['un 0 tipeado en el no gravado', [{ type: 'SET_EXTRAS', payload: { noGravado: 0 } }]],
      ['el impuesto interno declarado', [{ type: 'SET_II_DECLARADO', payload: { tasa: 8, monto: 120 } }]],
      ['un importe del control contra factura', [{ type: 'SET_CONTROL', payload: { total: 6534 } }]],
    ])('%s', (_caso, acciones) => {
      expect(compraTieneCambios(tras(...acciones))).toBe(true)
    })
  })

  // Los dos criterios del no gravado, cada uno por su lado. Por el reducer no se
  // pueden separar: `SET_EXTRAS` con `noGravado` prende también la marca de
  // manual, y un caso armado así da verde aunque el criterio del importe no
  // exista. Por eso el estado se arma a mano.
  describe('el no gravado, criterio por criterio', () => {
    it('un importe distinto del default, sin la marca de manual (pre-llenado de los cargos)', () => {
      const state: CompraState = { ...initialState, noGravado: 500, noGravadoManual: false }
      expect(compraTieneCambios(state)).toBe(true)
    })

    it('la marca de manual con el importe en el default: un 0 tipeado es un dato', () => {
      const state: CompraState = {
        ...initialState,
        noGravado: initialState.noGravado,
        noGravadoManual: true,
      }
      expect(compraTieneCambios(state)).toBe(true)
    })
  })

  describe('cuenta el escaneo de factura', () => {
    it('uno en vuelo: lo que traiga es carga', () => {
      expect(compraTieneCambios(tras({ type: 'SET_ESCANEANDO', payload: true }))).toBe(true)
    })

    it('uno terminado que todavía no se aplicó', () => {
      expect(compraTieneCambios(tras({ type: 'SET_RESULTADO_ESCANEO', payload: FACTURA }))).toBe(true)
    })

    it('ítems escaneados esperando revisión, aunque no haya líneas', () => {
      const state = tras({
        type: 'APLICAR_ESCANEO',
        payload: {
          proveedorId: '',
          proveedorNombre: '',
          numeroFactura: '',
          fechaCompra: '',
          formaPago: '',
          items: [],
          pendientes: [ITEM_ESCANEADO],
        },
      })
      expect(state.items).toHaveLength(0)
      expect(compraTieneCambios(state)).toBe(true)
    })

    it('un escaneo que falló no deja nada que perder', () => {
      const state = tras(
        { type: 'SET_ESCANEANDO', payload: true },
        { type: 'SET_ERROR_ESCANEO', payload: 'No se pudo procesar la factura' },
      )
      expect(compraTieneCambios(state)).toBe(false)
    })
  })

  it('cuenta el alta rápida de producto abierta: lo tipeado ahí no está en el reducer', () => {
    expect(compraTieneCambios(tras({ type: 'SET_MODO_ITEM_RAPIDO', payload: true }))).toBe(true)
  })

  describe('no cuenta lo que es de la pantalla', () => {
    it.each<[string, CompraActionType[]]>([
      ['la lista del buscador abierta', [{ type: 'SET_MOSTRAR_BUSCADOR', payload: true }]],
      ['un término en el buscador', [{ type: 'SET_BUSQUEDA', payload: 'acei' }]],
      ['un guardado en vuelo', [{ type: 'SET_GUARDANDO', payload: true }]],
      ['un error de validación a la vista', [{ type: 'SET_ERROR', payload: 'Debe agregar al menos un producto' }]],
      ['texto que es sólo espacios', [
        { type: 'SET_NUMERO_FACTURA', payload: '   ' },
        { type: 'SET_NOTAS', payload: '\n  ' },
        { type: 'SET_PROVEEDOR_NOMBRE', payload: ' ' },
      ]],
    ])('%s', (_caso, acciones) => {
      expect(compraTieneCambios(tras(...acciones))).toBe(false)
    })
  })

  describe('volver al default deja de contar', () => {
    it.each<[string, CompraActionType[]]>([
      ['borrar la única línea', [
        { type: 'AGREGAR_ITEM', payload: ACEITE },
        { type: 'ELIMINAR_ITEM', payload: 0 },
      ]],
      ['ir a ZZ y volver a FC', [
        { type: 'SET_TIPO_FACTURA', payload: 'ZZ' },
        { type: 'SET_TIPO_FACTURA', payload: 'FC' },
      ]],
      ['elegir un proveedor y volver a "Seleccionar proveedor..."', [
        { type: 'SET_PROVEEDOR_ID', payload: 'prov-1' },
        { type: 'SET_PROVEEDOR_ID', payload: '' },
      ]],
      ['borrar el impuesto interno declarado', [
        { type: 'SET_II_DECLARADO', payload: { tasa: 8, monto: 120 } },
        { type: 'SET_II_DECLARADO', payload: { tasa: 8, monto: 0 } },
      ]],
      ['descartar el escaneo sin aplicarlo', [
        { type: 'SET_RESULTADO_ESCANEO', payload: FACTURA },
        { type: 'SET_RESULTADO_ESCANEO', payload: null },
      ]],
    ])('%s', (_caso, acciones) => {
      expect(compraTieneCambios(tras(...acciones))).toBe(false)
    })
  })
})
