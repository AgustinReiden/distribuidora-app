/**
 * El tipo de documento de un cliente sale de su valor (B17, #1561 1561-b11): espejo
 * del trigger `clientes_tipo_documento_del_valor()`.
 */
import { describe, it, expect } from 'vitest'
import { tipoDocumentoDelValor, documentoParaGuardar } from './documentoCliente'
import { dniToStorageFormat } from './formatters'

describe('tipoDocumentoDelValor', () => {
  it.each([
    ['00-30123456-0', 'DNI'],
    ['00-01234567-0', 'DNI'],
    ['20-12345678-6', 'CUIT'],
    ['30-71234567-1', 'CUIT'],
    // Un DNI rellenado a 11 y partido como CUIT no es el formato de un DNI: el CHECK de la base lo rechaza.
    ['00-03012345-6', 'CUIT'],
    ['00-00000000-0', 'CUIT'],
    ['', 'CUIT'],
    [null, 'CUIT'],
    [undefined, 'CUIT'],
  ] as const)('%s → %s', (valor, tipo) => {
    expect(tipoDocumentoDelValor(valor)).toBe(tipo)
  })

  it('lo que arma dniToStorageFormat siempre es DNI', () => {
    expect(tipoDocumentoDelValor(dniToStorageFormat('30123456'))).toBe('DNI')
    expect(tipoDocumentoDelValor(dniToStorageFormat('1234567'))).toBe('DNI')
  })
})

describe('documentoParaGuardar', () => {
  it('un DNI va con tipo DNI', () => {
    expect(documentoParaGuardar('00-30123456-0')).toEqual({ cuit: '00-30123456-0', tipo_documento: 'DNI' })
  })

  it('un CUIT va con tipo CUIT', () => {
    expect(documentoParaGuardar('20-12345678-6')).toEqual({ cuit: '20-12345678-6', tipo_documento: 'CUIT' })
  })

  it('vacío o el relleno quedan sin documento', () => {
    expect(documentoParaGuardar('')).toEqual({ cuit: null, tipo_documento: 'CUIT' })
    expect(documentoParaGuardar(null)).toEqual({ cuit: null, tipo_documento: 'CUIT' })
    expect(documentoParaGuardar('00-00000000-0')).toEqual({ cuit: null, tipo_documento: 'CUIT' })
  })
})

describe('dniToStorageFormat', () => {
  it('un DNI vacío no se rellena con ceros: queda vacío', () => {
    expect(dniToStorageFormat('')).toBe('')
  })

  it('arma 00-XXXXXXXX-0 con el DNI rellenado a 8', () => {
    expect(dniToStorageFormat('30123456')).toBe('00-30123456-0')
    expect(dniToStorageFormat('1234567')).toBe('00-01234567-0')
  })
})
