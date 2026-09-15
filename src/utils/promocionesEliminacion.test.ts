import { describe, it, expect } from 'vitest'
import { tienePromocionUso } from './promocionesEliminacion'

describe('tienePromocionUso', () => {
  it('sin pedidos ni ajustes: no tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 0, ajustes: 0 })).toBe(false)
  })

  it('con pedidos facturados: tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 3, ajustes: 0 })).toBe(true)
  })

  it('con ajustes de stock aunque no tenga pedidos: tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 0, ajustes: 1 })).toBe(true)
  })

  it('con pedidos y ajustes: tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 2, ajustes: 5 })).toBe(true)
  })
})
