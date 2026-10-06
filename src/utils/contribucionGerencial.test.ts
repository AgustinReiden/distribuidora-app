import { describe, it, expect } from 'vitest'
import { contribucionEstimada, resumenCobranza } from './contribucionGerencial'

describe('contribucionEstimada', () => {
  it('margen neto − mermas − comisión − notas de crédito de venta', () => {
    expect(contribucionEstimada({ margen_neto: 1000, mermas: 100, notas_credito_venta: 50 }, 200)).toBe(650)
  })

  it('sin la clave de NC (respuesta cacheada pre-289) resta 0', () => {
    expect(contribucionEstimada({ margen_neto: 1000, mermas: 100 }, 200)).toBe(700)
  })

  it('el RPC puede mandar numéricos como string: se convierten', () => {
    expect(contribucionEstimada(
      { margen_neto: '1000' as unknown as number, mermas: 0, notas_credito_venta: '10200.00' as unknown as number },
      0,
    )).toBe(-9200)
  })
})

describe('resumenCobranza', () => {
  it('el % cobrado es sólo plata; el crédito aplicado va aparte', () => {
    const r = resumenCobranza({ cobrado: 900, credito_aplicado: 550, pendiente: 50 }, 1500)
    expect(r).toEqual({ cobrado: 900, creditoAplicado: 550, pendiente: 50, pctCobrado: 0.6 })
    // Las tres partes cierran con la venta.
    expect(r.cobrado + r.creditoAplicado + r.pendiente).toBe(1500)
  })

  it('sin venta no divide por cero, y sin credito_aplicado es 0', () => {
    expect(resumenCobranza({ cobrado: 0, pendiente: 0 }, 0)).toEqual({ cobrado: 0, creditoAplicado: 0, pendiente: 0, pctCobrado: 0 })
  })
})
