import { describe, expect, it } from 'vitest'
import {
  FORMAS_PAGO,
  FORMAS_PAGO_SELECCIONABLES,
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
