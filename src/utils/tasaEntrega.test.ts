import { describe, it, expect } from 'vitest'
import { MOTIVOS_ADMINISTRATIVOS } from '../constants/desenlacePedido'
import { calcularTasaEntrega, contarRechazosTotales, esRechazoTotal } from './tasaEntrega'

describe('esRechazoTotal', () => {
  it('un cancelado por motivo de no entrega es rechazo', () => {
    expect(esRechazoTotal({ estado: 'cancelado', canal: 'app', motivo_cancelacion_tipo: 'cerrado' })).toBe(true)
  })

  it('un cancelado sin motivo cuenta como rechazo (mig 179)', () => {
    expect(esRechazoTotal({ estado: 'cancelado', canal: 'app', motivo_cancelacion_tipo: null })).toBe(true)
    expect(esRechazoTotal({ estado: 'cancelado' })).toBe(true)
  })

  it('cliente_cancelo es rechazo aunque viva entre los motivos de oficina', () => {
    expect(esRechazoTotal({ estado: 'cancelado', motivo_cancelacion_tipo: 'cliente_cancelo' })).toBe(true)
  })

  it.each([...MOTIVOS_ADMINISTRATIVOS])('%s no es rechazo', (motivo) => {
    expect(esRechazoTotal({ estado: 'cancelado', canal: 'app', motivo_cancelacion_tipo: motivo })).toBe(false)
  })

  it('un canje cancelado no cuenta', () => {
    expect(esRechazoTotal({ estado: 'cancelado', canal: 'cambio', motivo_cancelacion_tipo: 'cerrado' })).toBe(false)
  })

  it.each(['entregado', 'pendiente', 'asignado', 'anulado'])('%s no es rechazo', (estado) => {
    expect(esRechazoTotal({ estado, motivo_cancelacion_tipo: 'cerrado' })).toBe(false)
  })
})

describe('contarRechazosTotales', () => {
  it('cuenta sólo los rechazos', () => {
    expect(contarRechazosTotales([
      { estado: 'cancelado', motivo_cancelacion_tipo: 'cerrado' },
      { estado: 'cancelado', motivo_cancelacion_tipo: 'prueba' },
      { estado: 'cancelado', canal: 'cambio', motivo_cancelacion_tipo: null },
      { estado: 'cancelado', motivo_cancelacion_tipo: null },
    ])).toBe(2)
  })
})

describe('calcularTasaEntrega', () => {
  it('un mes cerrado con rechazos no da 100% (#1197)', () => {
    // Tucumán, septiembre 2026: 863 entregados y 34 rechazos.
    const tasa = calcularTasaEntrega({ pendiente: 0, asignado: 0, entregado: 863 }, 34)
    expect(tasa.toFixed(1)).toBe('96.2')
  })

  it('pendientes y asignados siguen en el denominador', () => {
    expect(calcularTasaEntrega({ pendiente: 1, asignado: 1, entregado: 6 }, 2)).toBe(60)
  })

  it('sin rechazos da lo de antes', () => {
    expect(calcularTasaEntrega({ pendiente: 1, asignado: 0, entregado: 3 }, 0)).toBe(75)
  })

  it('sin pedidos da 0', () => {
    expect(calcularTasaEntrega({ pendiente: 0, asignado: 0, entregado: 0 }, 0)).toBe(0)
  })

  it('sólo rechazos da 0', () => {
    expect(calcularTasaEntrega({ pendiente: 0, asignado: 0, entregado: 0 }, 3)).toBe(0)
  })
})
