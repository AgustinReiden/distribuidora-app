import { describe, it, expect } from 'vitest'
import { alicuotaIvaVenta } from './alicuotaIvaVenta'
import { calcularNetoVenta } from './calculations'

// Los mismos casos que el humo de la migración (_alicuota_iva_venta).
describe('alicuotaIvaVenta (#1258: la condición manda, no se inventa el 21)', () => {
  it('exento y no gravado venden al 0, traigan o no porcentaje', () => {
    expect(alicuotaIvaVenta({ condicion_iva: 'exento', porcentaje_iva: null })).toBe(0)
    expect(alicuotaIvaVenta({ condicion_iva: 'exento' })).toBe(0)
    expect(alicuotaIvaVenta({ condicion_iva: 'no_gravado', porcentaje_iva: 0 })).toBe(0)
  })

  it('gravado vende a su porcentaje', () => {
    expect(alicuotaIvaVenta({ condicion_iva: 'gravado', porcentaje_iva: 10.5 })).toBe(10.5)
    expect(alicuotaIvaVenta({ condicion_iva: 'gravado', porcentaje_iva: 21 })).toBe(21)
    expect(alicuotaIvaVenta({ condicion_iva: 'gravado', porcentaje_iva: 0 })).toBe(0)
  })

  it('gravado sin porcentaje, o sin condición, al 21 (el default de la columna)', () => {
    expect(alicuotaIvaVenta({ condicion_iva: 'gravado', porcentaje_iva: null })).toBe(21)
    expect(alicuotaIvaVenta({ porcentaje_iva: null })).toBe(21)
    expect(alicuotaIvaVenta({ porcentaje_iva: 10.5 })).toBe(10.5)
    expect(alicuotaIvaVenta(undefined)).toBe(21)
  })

  it('un exento sin porcentaje en FC no lleva IVA', () => {
    const d = calcularNetoVenta(1000, alicuotaIvaVenta({ condicion_iva: 'exento', porcentaje_iva: null }), 0, 'FC')
    expect(d.iva).toBe(0)
    expect(d.neto).toBe(1000)
  })
})
