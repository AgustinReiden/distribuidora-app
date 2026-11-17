import { describe, it, expect } from 'vitest'
import { margenSobreConCosto, sinCostoFueraDelMargen } from './margenSobreConCosto'

describe('margenSobreConCosto (1562-b6)', () => {
  it('divide por el ingreso con costo, como Rentabilidad: 300 / (1000 − 100) = 33,3 %', () => {
    expect(margenSobreConCosto(300, 1000, 100)).toBeCloseTo(1 / 3, 6)
  })

  it('sin ventas sin costo es el margen sobre la venta', () => {
    expect(margenSobreConCosto(300, 1000)).toBe(0.3)
  })

  it('un denominador 0 o negativo da null, no un porcentaje absurdo', () => {
    expect(margenSobreConCosto(0, 100, 100)).toBeNull()
    // período con notas que superan la venta: margen −951 sobre venta −541 daría 175,8 %
    expect(margenSobreConCosto(-951, -541, 180)).toBeNull()
    expect(margenSobreConCosto(10, 0)).toBeNull()
  })

  it('acepta los numéricos como string del RPC', () => {
    expect(margenSobreConCosto('300' as unknown as number, '1000' as unknown as number, '100' as unknown as number))
      .toBeCloseTo(1 / 3, 6)
  })
})

describe('sinCostoFueraDelMargen', () => {
  it('con un RPC que ya lo excluye (trae venta_bruta) devuelve lo sin costo; con uno anterior, 0', () => {
    expect(sinCostoFueraDelMargen({ venta_bruta: 1000 }, 100)).toBe(100)
    expect(sinCostoFueraDelMargen({}, 100)).toBe(0)
    expect(sinCostoFueraDelMargen({ venta_bruta: 1000 }, undefined)).toBe(0)
  })
})
