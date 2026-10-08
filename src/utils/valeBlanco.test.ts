import { describe, it, expect } from 'vitest'
import {
  clienteHabilitadoVB,
  destinosTipoFactura,
  esTipoVB,
  itemsVBParaCrear,
  mensajeAltaVB,
  mensajeConversionTipoFactura,
  opcionesTipoFactura,
  tipoFacturaInicial,
  BLOQUEO_VB_CON_PAGOS,
  BLOQUEO_VB_CON_PROMOS,
  BLOQUEO_VB_CON_SALVEDADES,
  BLOQUEO_VB_EN_RUTA,
  type PedidoParaConversion,
} from './valeBlanco'

const CLIENTE_VB = { tipo_factura_default: 'VB' }
const CLIENTE_ZZ = { tipo_factura_default: 'ZZ' }

describe('esTipoVB / clienteHabilitadoVB / tipoFacturaInicial', () => {
  it('sólo "VB" es vale blanco', () => {
    expect(esTipoVB('VB')).toBe(true)
    for (const t of ['ZZ', 'FC', '', null, undefined, 'vb']) expect(esTipoVB(t)).toBe(false)
  })

  it('el cliente está habilitado sólo con default VB', () => {
    expect(clienteHabilitadoVB(CLIENTE_VB)).toBe(true)
    expect(clienteHabilitadoVB(CLIENTE_ZZ)).toBe(false)
    expect(clienteHabilitadoVB({ tipo_factura_default: 'FC' })).toBe(false)
    expect(clienteHabilitadoVB(null)).toBe(false)
    expect(clienteHabilitadoVB(undefined)).toBe(false)
  })

  it('un cliente VB arranca en VB; FC en FC; lo demás en ZZ', () => {
    expect(tipoFacturaInicial(CLIENTE_VB)).toBe('VB')
    expect(tipoFacturaInicial({ tipo_factura_default: 'FC' })).toBe('FC')
    expect(tipoFacturaInicial(CLIENTE_ZZ)).toBe('ZZ')
    expect(tipoFacturaInicial({ tipo_factura_default: 'XX' })).toBe('ZZ')
    expect(tipoFacturaInicial(undefined)).toBe('ZZ')
  })
})

describe('opcionesTipoFactura (select del alta)', () => {
  const valores = (v: string | undefined, hab: boolean) => opcionesTipoFactura(v, hab).map(o => o.value)

  it('sin habilitación: ZZ y FC', () => {
    expect(valores('ZZ', false)).toEqual(['ZZ', 'FC'])
  })

  it('cliente habilitado: además VB', () => {
    expect(valores('VB', true)).toEqual(['ZZ', 'FC', 'VB'])
    expect(valores('ZZ', true)).toEqual(['ZZ', 'FC', 'VB'])
  })

  it('tolera un valor que no está en la lista (no lo muestra como ZZ)', () => {
    expect(valores('VB', false)).toEqual(['ZZ', 'FC', 'VB'])
    expect(valores('XX', false)).toEqual(['ZZ', 'FC', 'XX'])
  })
})

describe('destinosTipoFactura (menú de conversión, N10)', () => {
  const zz = (over: Partial<PedidoParaConversion> = {}): PedidoParaConversion => ({
    estado: 'pendiente',
    tipo_factura: 'ZZ',
    monto_pagado: 0,
    pagos: [],
    salvedades: [],
    items: [{ es_bonificacion: false, promocion_id: null }],
    cliente: CLIENTE_VB,
    ...over,
  })
  const tipos = (p: PedidoParaConversion, rol: { isAdmin?: boolean; isEncargado?: boolean }) =>
    destinosTipoFactura(p, rol).map(d => d.bloqueo ? `${d.tipo}!` : d.tipo)

  it('cancelado o anulado: nada, para nadie', () => {
    expect(tipos(zz({ estado: 'cancelado' }), { isAdmin: true })).toEqual([])
    expect(tipos(zz({ estado: 'anulado' }), { isAdmin: true })).toEqual([])
    expect(tipos(zz({ estado: 'cancelado', tipo_factura: 'VB' }), { isAdmin: true })).toEqual([])
  })

  it('cliente no habilitado: el flip ZZ↔FC de siempre, sin VB', () => {
    expect(tipos(zz({ cliente: CLIENTE_ZZ }), { isAdmin: true })).toEqual(['FC'])
    expect(tipos(zz({ cliente: CLIENTE_ZZ, tipo_factura: 'FC' }), { isEncargado: true })).toEqual(['ZZ'])
    expect(tipos(zz({ cliente: CLIENTE_ZZ, estado: 'entregado' }), { isEncargado: true })).toEqual([])
    expect(tipos(zz({ cliente: undefined }), { isAdmin: true })).toEqual(['FC'])
  })

  it('cliente habilitado, no entregado: admin y encargado pueden pasar a VB', () => {
    expect(tipos(zz(), { isAdmin: true })).toEqual(['FC', 'VB'])
    expect(tipos(zz(), { isEncargado: true })).toEqual(['FC', 'VB'])
    expect(tipos(zz(), {})).toEqual([])
  })

  it('cliente habilitado, entregado: sólo admin (el encargado no tiene ni el flip)', () => {
    expect(tipos(zz({ estado: 'entregado' }), { isAdmin: true })).toEqual(['FC', 'VB'])
    expect(tipos(zz({ estado: 'entregado' }), { isEncargado: true })).toEqual([])
  })

  it.each([
    ['en ruta (asignado)', { estado: 'asignado' }, BLOQUEO_VB_EN_RUTA],
    ['en preparación', { estado: 'en_preparacion' }, BLOQUEO_VB_EN_RUTA],
    ['con monto pagado', { monto_pagado: 100 }, BLOQUEO_VB_CON_PAGOS],
    ['con una fila de pago', { pagos: [{ monto: 50 }] }, BLOQUEO_VB_CON_PAGOS],
    ['con salvedad pendiente', { estado: 'entregado', salvedades: [{ estado_resolucion: 'pendiente' }] }, BLOQUEO_VB_CON_SALVEDADES],
    ['con regalo', { items: [{ es_bonificacion: true }] }, BLOQUEO_VB_CON_PROMOS],
    ['con promoción', { items: [{ es_bonificacion: false, promocion_id: '14' }] }, BLOQUEO_VB_CON_PROMOS],
  ])('%s: VB se ofrece bloqueado con el motivo', (_, over, motivo) => {
    const vb = destinosTipoFactura(zz(over as Partial<PedidoParaConversion>), { isAdmin: true }).find(d => d.tipo === 'VB')
    expect(vb?.bloqueo).toBe(motivo)
  })

  it('una salvedad anulada no bloquea', () => {
    const vb = destinosTipoFactura(zz({ salvedades: [{ estado_resolucion: 'anulada' }] }), { isAdmin: true }).find(d => d.tipo === 'VB')
    expect(vb).toEqual({ tipo: 'VB' })
  })

  it('un VB: sólo el admin lo pasa a ZZ o FC', () => {
    const vb = zz({ tipo_factura: 'VB', estado: 'entregado', monto_pagado: 5000 })
    expect(tipos(vb, { isAdmin: true })).toEqual(['ZZ', 'FC'])
    expect(tipos(vb, { isEncargado: true })).toEqual([])
    expect(tipos(vb, {})).toEqual([])
  })
})

describe('mensajes', () => {
  it('a VB avisa que quedó saldado a costo; desde VB, que queda pendiente de cobro y fuera de toda rendición', () => {
    expect(mensajeConversionTipoFactura('ZZ', 'VB')).toMatch(/vale blanco/)
    const desdeVB = mensajeConversionTipoFactura('VB', 'ZZ')
    expect(desdeVB).toMatch(/pendiente de cobro/)
    expect(desdeVB).toMatch(/rendición/)
    expect(mensajeConversionTipoFactura('ZZ', 'FC')).toBeNull()
  })

  it('alta: con el total del servidor lo muestra; sin él, no inventa uno', () => {
    const fmt = (n: number) => `$${n}`
    expect(mensajeAltaVB(1234.5, fmt)).toContain('$1234.5')
    expect(mensajeAltaVB(null, fmt)).not.toContain('$')
  })
})

describe('itemsVBParaCrear', () => {
  it('sólo producto y cantidad, precio 0 (lo pone el servidor), sin cantidades nulas', () => {
    expect(itemsVBParaCrear([
      { productoId: 101, cantidad: 3 },
      { productoId: '102', cantidad: 0 },
    ])).toEqual([{ productoId: '101', cantidad: 3, precioUnitario: 0 }])
  })
})
