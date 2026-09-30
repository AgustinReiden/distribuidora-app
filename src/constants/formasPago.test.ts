import { describe, expect, it } from 'vitest'
import {
  FORMAS_PAGO,
  FORMAS_PAGO_NO_DINERARIAS,
  FORMAS_PAGO_SELECCIONABLES,
  esFormaPagoNoDineraria,
  formaPagoLabel,
  formaPagoMeta,
} from './formasPago'

describe('formas de pago seleccionables', () => {
  it('excluye cuenta_corriente y otros del set seleccionable', () => {
    const values = FORMAS_PAGO_SELECCIONABLES.map((m) => m.value)
    expect(values).not.toContain('cuenta_corriente')
    expect(values).not.toContain('otros')
  })

  it('incluye las formas de pago reales', () => {
    const values = FORMAS_PAGO_SELECCIONABLES.map((m) => m.value)
    expect(values).toEqual(
      expect.arrayContaining(['efectivo', 'transferencia', 'cheque', 'tarjeta', 'vale_blanco']),
    )
  })

  it('toda forma seleccionable tiene seleccionable=true', () => {
    expect(FORMAS_PAGO_SELECCIONABLES.every((m) => m.seleccionable)).toBe(true)
  })
})

describe('adelanto_sueldo (#832)', () => {
  it('tiene etiqueta y no es seleccionable en los selectores generales', () => {
    expect(formaPagoLabel('adelanto_sueldo')).toBe('Adelanto de sueldo')
    expect(formaPagoMeta('adelanto_sueldo').seleccionable).toBe(false)
    expect(FORMAS_PAGO_SELECCIONABLES.map((m) => m.value)).not.toContain('adelanto_sueldo')
  })

  it('está marcada como no dineraria y no cae en "otros"', () => {
    expect(FORMAS_PAGO_NO_DINERARIAS).toContain('adelanto_sueldo')
    expect(formaPagoMeta('adelanto_sueldo').value).toBe('adelanto_sueldo')
  })

  it('vale_blanco no es no-dineraria (sigue en rendiciones)', () => {
    expect(FORMAS_PAGO_NO_DINERARIAS).not.toContain('vale_blanco')
  })
})

describe('nota_credito (#833)', () => {
  it('tiene etiqueta, no es seleccionable y es no dineraria', () => {
    expect(formaPagoLabel('nota_credito')).toBe('Nota de crédito')
    expect(formaPagoMeta('nota_credito').seleccionable).toBe(false)
    expect(FORMAS_PAGO_SELECCIONABLES.map((m) => m.value)).not.toContain('nota_credito')
  })

  it('las no dinerarias son exactamente las que excluyen las RPCs de rendiciones (migs 273/276)', () => {
    expect([...FORMAS_PAGO_NO_DINERARIAS].sort()).toEqual(['adelanto_sueldo', 'nota_credito'])
    expect(esFormaPagoNoDineraria('nota_credito')).toBe(true)
    expect(esFormaPagoNoDineraria('adelanto_sueldo')).toBe(true)
    expect(esFormaPagoNoDineraria('efectivo')).toBe(false)
    expect(esFormaPagoNoDineraria(null)).toBe(false)
  })
})

describe('cuenta_corriente se conserva para etiquetas/reportes históricos', () => {
  it('sigue teniendo etiqueta legible aunque no sea seleccionable', () => {
    expect(formaPagoLabel('cuenta_corriente')).toBe('Cuenta corriente')
    expect(formaPagoMeta('cuenta_corriente').seleccionable).toBe(false)
  })

  it('cuenta_corriente sigue presente en el catálogo completo FORMAS_PAGO', () => {
    const values = FORMAS_PAGO.map((m) => m.value)
    expect(values).toContain('cuenta_corriente')
  })
})
