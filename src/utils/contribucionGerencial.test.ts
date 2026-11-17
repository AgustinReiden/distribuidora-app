import { describe, it, expect } from 'vitest'
import { contribucionEstimada, notasCreditoAparte, resumenCobranza } from './contribucionGerencial'

describe('contribucionEstimada', () => {
  it('RPC anterior a REP-D (sin venta_bruta): margen neto − mermas − comisión − notas de crédito', () => {
    expect(contribucionEstimada({ margen_neto: 1000, mermas: 100, notas_credito_venta: 50 }, 200)).toBe(650)
  })

  it('REP-D (#1545): con venta_bruta el margen ya es neto de notas y no se restan dos veces', () => {
    // venta 1000 = bruta 1050 − 50 de notas; el margen del RPC ya la trae neta.
    expect(contribucionEstimada({ margen_neto: 950, mermas: 100, notas_credito_venta: 50, venta_bruta: 1050 }, 200))
      .toBe(650)
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

describe('notasCreditoAparte', () => {
  it('todas con un RPC anterior a REP-D, ninguna con uno que ya las restó, 0 sin la clave', () => {
    expect(notasCreditoAparte({ notas_credito_venta: 50 })).toBe(50)
    expect(notasCreditoAparte({ notas_credito_venta: 50, venta_bruta: 1050 })).toBe(0)
    expect(notasCreditoAparte({ notas_credito_venta: 50, venta_bruta: 0 })).toBe(0)
    expect(notasCreditoAparte({})).toBe(0)
  })
})

describe('resumenCobranza', () => {
  it('el % cobrado es sólo plata; el crédito aplicado va aparte', () => {
    const r = resumenCobranza({ cobrado: 900, credito_aplicado: 550, pendiente: 50 })
    expect(r).toEqual({ cobrado: 900, creditoAplicado: 550, pendiente: 50, pctCobrado: 0.6 })
    // Las tres partes cierran con la venta.
    expect(r.cobrado + r.creditoAplicado + r.pendiente).toBe(1500)
  })

  it('un período con cargo de envío cobrado entero da exactamente 100 %', () => {
    // venta de productos 12000 + envío 500: lo cobrado (12500) supera la venta.
    const r = resumenCobranza({ cobrado: 12500, pendiente: 0, credito_aplicado: 0 })
    expect(r.pctCobrado).toBe(1)
  })

  it('sin venta no divide por cero, y sin credito_aplicado es 0', () => {
    expect(resumenCobranza({ cobrado: 0, pendiente: 0 })).toEqual({ cobrado: 0, creditoAplicado: 0, pendiente: 0, pctCobrado: 0 })
  })
})
