import { describe, expect, it } from 'vitest'
import { datosDeEntrega, necesitaElegirChofer } from './choferDeEntrega'

describe('necesitaElegirChofer (#1204)', () => {
  it('pide chofer si el pedido no tiene', () => {
    expect(necesitaElegirChofer({ transportista_id: null, tipo_factura: 'ZZ' })).toBe(true)
    expect(necesitaElegirChofer({ transportista_id: undefined, tipo_factura: 'FC' })).toBe(true)
    expect(necesitaElegirChofer({ transportista_id: '', tipo_factura: undefined })).toBe(true)
  })

  it('si ya tiene chofer, se usa ese', () => {
    expect(necesitaElegirChofer({ transportista_id: 'u-1', tipo_factura: 'ZZ' })).toBe(false)
  })

  it('el vale blanco no lleva chofer', () => {
    expect(necesitaElegirChofer({ transportista_id: null, tipo_factura: 'VB' })).toBe(false)
  })
})

describe('datosDeEntrega (#1204)', () => {
  it('sin elección no agrega nada', () => {
    expect(datosDeEntrega(null)).toEqual({})
    expect(datosDeEntrega(undefined)).toEqual({})
  })

  it('un chofer va como transportistaId', () => {
    expect(datosDeEntrega({ tipo: 'chofer', transportistaId: 'u-1' })).toEqual({ transportistaId: 'u-1' })
  })

  it('el retiro va sin chofer', () => {
    expect(datosDeEntrega({ tipo: 'retiro' })).toEqual({ retiroDeposito: true })
  })
})
