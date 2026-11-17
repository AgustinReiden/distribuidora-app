import { describe, it, expect } from 'vitest'
import { mensajeCobroMasivo, avisoNoCobrados } from './avisoCobroMasivo'

describe('aviso del cobro masivo (1559-b12)', () => {
  it('cuenta lo cobrado, no lo enviado', () => {
    expect(mensajeCobroMasivo(1)).toBe('1 pedido marcado como pagado')
    expect(mensajeCobroMasivo(3)).toBe('3 pedidos marcados como pagados')
  })

  it('sin nada cobrado lo dice', () => {
    expect(mensajeCobroMasivo(0)).toMatch(/No se cobró ningún pedido/)
  })

  it('avisa cuántos se saltearon', () => {
    expect(avisoNoCobrados(2, 1)).toBe(
      '1 pedido no se cobró: ya estaban cobrados, dados de baja o son vales blancos. Revisá la lista.',
    )
    expect(avisoNoCobrados(5, 2)).toMatch(/^3 pedidos no se cobraron: /)
  })

  it('si se cobraron todos no avisa', () => {
    expect(avisoNoCobrados(2, 2)).toBeNull()
    expect(avisoNoCobrados(0, 0)).toBeNull()
  })
})
