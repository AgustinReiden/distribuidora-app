import { describe, it, expect, afterEach } from 'vitest'
import type { Mock } from 'vitest'
import {
  VERSION_BORRADOR_COMPRA, claveBorradorCompra, serializarBorrador, leerBorrador,
  estadoDesdeBorrador, estadoParaBorrador, fechaHoraBorrador, lineasSinProductoVigente,
  leerStorage, escribirStorage, borrarStorage,
} from './borradorCompra'
import { compraReducer, initialState } from '../components/modals/ModalCompra.reducer'
import type { CompraState } from '../components/modals/ModalCompra.reducer'
import type { ProductoDB } from '../types'

const producto = (id: string, extra: Partial<ProductoDB> = {}): ProductoDB => ({
  id, nombre: `Producto ${id}`, codigo: id, costo_sin_iva: 100, impuestos_internos: 0,
  porcentaje_iva: 21, condicion_iva: 'gravado', stock: 0, ...extra,
} as unknown as ProductoDB)

type Accion = Parameters<typeof compraReducer>[1]

const cargada = (): CompraState => ([
  { type: 'AGREGAR_ITEM', payload: producto('a') },
  { type: 'AGREGAR_ITEM', payload: producto('b') },
  { type: 'AGREGAR_CARGO' },
  { type: 'SET_PESO_CARGO', payload: { cargoId: 1, lineaId: 1, peso: 3 } },
  { type: 'SET_NUMERO_FACTURA', payload: '0005-00001234' },
  { type: 'SET_BUSQUEDA', payload: 'algo a medio buscar' },
  { type: 'SET_ERROR', payload: 'un error viejo' },
] as Accion[]).reduce(compraReducer, initialState)

describe('claveBorradorCompra', () => {
  it('una por sucursal y usuario', () => {
    expect(claveBorradorCompra(1, 'u1')).not.toBe(claveBorradorCompra(2, 'u1'))
    expect(claveBorradorCompra(1, 'u1')).not.toBe(claveBorradorCompra(1, 'u2'))
  })
})

describe('serializar y leer', () => {
  it('ida y vuelta: el estado vuelve igual, sin lo de pantalla', () => {
    const s = cargada()
    const lectura = leerBorrador(serializarBorrador(s, new Date('2026-10-03T17:20:00Z')))
    expect(lectura.tipo).toBe('ok')
    if (lectura.tipo !== 'ok') return
    expect(lectura.borrador.version).toBe(VERSION_BORRADOR_COMPRA)
    expect(lectura.borrador.guardadoEn).toBe('2026-10-03T17:20:00.000Z')

    const restaurado = estadoDesdeBorrador(lectura.borrador)
    expect(restaurado.busquedaProducto).toBe('')
    expect(restaurado.mostrarBuscador).toBe(false)
    expect(restaurado.error).toBe('')
    expect(estadoParaBorrador(restaurado)).toEqual(estadoParaBorrador(s))
    expect(restaurado.cargos[0].pesosManuales).toEqual({ 1: true })
  })

  it('no guarda lo de pantalla', () => {
    const json = JSON.parse(serializarBorrador(cargada(), new Date()))
    expect(json.estado).not.toHaveProperty('busquedaProducto')
    expect(json.estado).not.toHaveProperty('error')
    expect(json.estado).not.toHaveProperty('guardando')
  })

  it('nada guardado', () => {
    expect(leerBorrador(null)).toEqual({ tipo: 'ninguno' })
    expect(leerBorrador('')).toEqual({ tipo: 'ninguno' })
  })

  it('otra versión no se carga: se ofrece con lo crudo', () => {
    const crudo = JSON.stringify({ version: VERSION_BORRADOR_COMPRA - 1 + 100, guardadoEn: '2026-10-01T10:00:00Z', estado: {} })
    const l = leerBorrador(crudo)
    expect(l.tipo).toBe('otra_version')
    if (l.tipo !== 'otra_version') return
    expect(l.crudo).toBe(crudo)
    expect(l.guardadoEn).toBe('2026-10-01T10:00:00Z')

    expect(leerBorrador(JSON.stringify({ estado: {} })).tipo).toBe('otra_version')
  })

  it('ilegible: no es JSON o le falta forma', () => {
    expect(leerBorrador('{no es json').tipo).toBe('ilegible')
    expect(leerBorrador('[]').tipo).toBe('ilegible')
    expect(leerBorrador(JSON.stringify({
      version: VERSION_BORRADOR_COMPRA, guardadoEn: 'x', estado: { items: 'no', cargos: [] },
    })).tipo).toBe('ilegible')
  })
})

describe('fechaHoraBorrador', () => {
  it('dd/mm hh:mm en hora local', () => {
    const d = new Date(2026, 9, 3, 14, 5)
    expect(fechaHoraBorrador(d.toISOString())).toBe('03/10 14:05')
    expect(fechaHoraBorrador('basura')).toBe('')
    expect(fechaHoraBorrador(null)).toBe('')
  })
})

describe('lineasSinProductoVigente', () => {
  it('marca las de productos borrados o inactivos', () => {
    const s = cargada()
    const productos = [producto('a', { activo: false } as Partial<ProductoDB>)]
    expect(lineasSinProductoVigente(s.items, productos).map(i => i.productoId)).toEqual(['a', 'b'])
    expect(lineasSinProductoVigente(s.items, [producto('a'), producto('b')])).toEqual([])
  })
})

describe('localStorage envuelto', () => {
  afterEach(() => {
    window.localStorage.clear()
  })

  it('escribe, lee y borra', () => {
    expect(escribirStorage('k', 'v')).toBe(true)
    expect(leerStorage('k')).toBe('v')
    borrarStorage('k')
    expect(leerStorage('k')).toBeNull()
  })

  it('si el storage tira (modo privado), no tira', () => {
    const ls = window.localStorage as unknown as Record<'setItem' | 'getItem' | 'removeItem', Mock>
    ls.setItem.mockImplementationOnce(() => { throw new Error('QuotaExceededError') })
    ls.getItem.mockImplementationOnce(() => { throw new Error('SecurityError') })
    ls.removeItem.mockImplementationOnce(() => { throw new Error('SecurityError') })
    expect(escribirStorage('k', 'v')).toBe(false)
    expect(leerStorage('k')).toBeNull()
    expect(() => borrarStorage('k')).not.toThrow()
  })
})
