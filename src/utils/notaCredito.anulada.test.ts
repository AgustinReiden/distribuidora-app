/**
 * B18 de la ola 2 (#1603): una nota de crédito de compra anulada (mig 523) sigue en
 * el historial, pero no cuenta para nada en la pantalla, como en la base (`NOT anulada`):
 * ni lo que le queda a la compra, ni el costo efectivo, ni el badge de la lista.
 */
import { describe, it, expect } from 'vitest'
import {
  avisosAnulacionNotaCredito,
  costoEfectivoCompra,
  esNotaVigente,
  notasVigentes,
  restanteAcreditableCompra,
  resumirNotasCreditoPorCompra,
} from './notaCredito'

describe('esNotaVigente / notasVigentes', () => {
  it('una nota sin el dato (respuesta anterior a la 523) está vigente; una anulada no', () => {
    expect(esNotaVigente({})).toBe(true)
    expect(esNotaVigente({ anulada: false })).toBe(true)
    expect(esNotaVigente({ anulada: null })).toBe(true)
    expect(esNotaVigente({ anulada: true })).toBe(false)
    expect(notasVigentes([{ id: 1, anulada: true }, { id: 2 }, { id: 3, anulada: false }]).map(n => n.id)).toEqual([2, 3])
  })
})

describe('restanteAcreditableCompra', () => {
  it('no descuenta una nota anulada: con un ajuste de 800 anulado sobre 1.000 quedan los 1.000', () => {
    expect(restanteAcreditableCompra(1000, [{ total: 800, anulada: true }])).toBe(1000)
    expect(restanteAcreditableCompra(1000, [{ total: 800, anulada: true }, { total: 300 }])).toBe(700)
  })
})

describe('costoEfectivoCompra', () => {
  it('un ajuste anulado no abarata la compra', () => {
    expect(costoEfectivoCompra(1000, [{ total: 200, tipo: 'ajuste', anulada: true }])).toBe(1000)
    expect(costoEfectivoCompra(1000, [
      { total: 200, tipo: 'ajuste', anulada: true },
      { total: 50, tipo: 'ajuste' },
    ])).toBe(950)
  })
})

describe('resumirNotasCreditoPorCompra (el badge de la lista)', () => {
  it('cuenta y suma sólo las vigentes; una compra cuyas notas están todas anuladas no aparece', () => {
    const r = resumirNotasCreditoPorCompra([
      { compra_id: 7, total: '100.50', anulada: false },
      { compra_id: 7, total: 40, anulada: true },
      { compra_id: 7, total: 9.5 },
      { compra_id: 8, total: 300, anulada: true },
    ])
    expect(r).toEqual([{ compra_id: '7', cantidad: 2, total: 110 }])
  })
})

describe('avisosAnulacionNotaCredito', () => {
  it('pasa los códigos de la base a castellano, sin repetir', () => {
    const avisos = avisosAnulacionNotaCredito([
      { producto_id: 1, motivo: 'x', warning: 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo' },
      { producto_id: 2, warning: 'costo_promedio_no_corregido: la compra es anterior a que se guardara el promedio previo' },
      { producto_id: 3, warning: 'costo_no_restaurado: sin otra compra válida de referencia' },
    ])
    expect(avisos).toHaveLength(2)
    expect(avisos[0]).toMatch(/^El costo promedio no se corrigió/)
    expect(avisos[1]).toMatch(/^El costo de reposición quedó como estaba/)
    for (const a of avisos) expect(a).not.toMatch(/costo_promedio_no_corregido|costo_no_restaurado/)
  })

  it('sin avisos (null, como manda la RPC) no dice nada', () => {
    expect(avisosAnulacionNotaCredito(null)).toEqual([])
    expect(avisosAnulacionNotaCredito(undefined)).toEqual([])
  })
})
