import { describe, it, expect } from 'vitest'
import { leyendaDiferenciaCanje, sentidoDiferenciaCanje } from './diferenciaCanje'

describe('la diferencia de un canje (#1370)', () => {
  it('positiva: el cliente se llevó más; se cobra con un pedido, no va a la cuenta', () => {
    expect(sentidoDiferenciaCanje(8000)).toBe('a_cobrar')
    expect(leyendaDiferenciaCanje(8000)).toMatch(/no fue a su cuenta.*se hace un pedido/)
  })

  it('negativa: a favor del cliente; no queda saldo a favor, se devuelve aparte', () => {
    expect(sentidoDiferenciaCanje(-2500.5)).toBe('a_favor_cliente')
    expect(leyendaDiferenciaCanje(-2500.5)).toMatch(/no quedó saldo a favor.*se hace aparte/)
  })

  it('cero, nula o de menos de un centavo: sin diferencia', () => {
    for (const d of [0, null, undefined, 0.004, -0.004]) {
      expect(sentidoDiferenciaCanje(d)).toBe('sin_diferencia')
    }
    expect(leyendaDiferenciaCanje(0)).toBe('Sin diferencia de precio.')
  })

  it('llega como texto si PostgREST devuelve el numeric así', () => {
    expect(sentidoDiferenciaCanje('-10' as unknown as number)).toBe('a_favor_cliente')
  })
})
