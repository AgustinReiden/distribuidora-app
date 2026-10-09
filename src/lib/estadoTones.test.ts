import { describe, it, expect } from 'vitest'
import {
  toneDeEstadoPedido,
  toneDeEstadoPago,
  toneDeRol,
  toneDeEstadoCompra,
  ETIQUETA_ESTADO_COMPRA,
  type Tone,
} from './estadoTones'

describe('toneDeEstadoPedido', () => {
  it.each<[string, Tone]>([
    ['pendiente', 'neutral'],
    ['en_preparacion', 'warning'],
    ['asignado', 'brand'],
    ['entregado', 'success'],
    ['cancelado', 'danger'],
    ['anulado', 'danger'],
  ])('%s -> %s', (estado, tono) => {
    expect(toneDeEstadoPedido(estado)).toBe(tono)
  })

  it.each([null, undefined, '', 'inventado'])('%s cae en neutral', (estado) => {
    expect(toneDeEstadoPedido(estado)).toBe('neutral')
  })

  // Estados que alguna vez se usaron en el codigo pero que `pedidos_estado_check`
  // (mig 297) no admite y nunca tuvieron filas: ya no estan en el mapa ni en los
  // tipos, y caen en neutral como cualquier valor desconocido (lo mismo que hacia
  // getEstadoColor, ya borrado, con ellos).
  it.each(['en_camino', 'preparado', 'listo', 'en_reparto'])('%s (estado muerto) cae en neutral', (estado) => {
    expect(toneDeEstadoPedido(estado)).toBe('neutral')
  })
})

describe('toneDeEstadoPago', () => {
  it.each<[string, Tone]>([
    ['pagado', 'success'],
    ['parcial', 'warning'],
    ['pendiente', 'danger'],
  ])('%s -> %s', (estado, tono) => {
    expect(toneDeEstadoPago(estado)).toBe(tono)
  })

  // Contraintuitivo a proposito: un pago que no consta se muestra como deuda,
  // igual que hacia getEstadoPagoColor (ya borrado). Si este test se pone rojo,
  // no lo "arregles" cambiando el esperado sin leer el comentario de estadoTones.ts.
  it.each([null, undefined, '', 'inventado'])('%s cae en danger, no en neutral', (estado) => {
    expect(toneDeEstadoPago(estado)).toBe('danger')
  })
})

describe('toneDeRol', () => {
  it.each<[string, Tone]>([
    ['preventista', 'brand'],
    ['transportista', 'warning'],
    ['admin', 'neutral'],
    ['encargado', 'neutral'],
    ['deposito', 'neutral'],
  ])('%s -> %s', (rol, tono) => {
    expect(toneDeRol(rol)).toBe(tono)
  })

  it.each([null, undefined, '', 'inventado'])('%s cae en neutral', (rol) => {
    expect(toneDeRol(rol)).toBe('neutral')
  })
})

describe('toneDeEstadoCompra', () => {
  it.each<[string, Tone]>([
    ['pendiente', 'warning'],
    ['recibida', 'success'],
    ['parcial', 'brand'],
    ['cancelada', 'danger'],
  ])('%s -> %s', (estado, tono) => {
    expect(toneDeEstadoCompra(estado)).toBe(tono)
  })

  it.each([null, undefined, '', 'inventado'])('%s cae en neutral', (estado) => {
    expect(toneDeEstadoCompra(estado)).toBe('neutral')
  })
})

describe('ETIQUETA_ESTADO_COMPRA', () => {
  it('tiene los mismos labels que usaban los ESTADOS_COMPRA locales', () => {
    expect(ETIQUETA_ESTADO_COMPRA).toEqual({
      pendiente: 'Pendiente',
      recibida: 'Recibida',
      parcial: 'Parcial',
      cancelada: 'Cancelada',
    })
  })
})
