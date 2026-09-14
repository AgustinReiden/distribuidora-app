import { describe, it, expect } from 'vitest'
import { calcularNuevosPrecios, redondearAMultiploDe10 } from './precios'

describe('redondearAMultiploDe10', () => {
  it('redondea al múltiplo de 10 más cercano', () => {
    expect(redondearAMultiploDe10(104)).toBe(100)
    expect(redondearAMultiploDe10(105)).toBe(110)
    expect(redondearAMultiploDe10(106)).toBe(110)
  })
})

describe('calcularNuevosPrecios', () => {
  it('aplica un aumento y redondea a múltiplo de 10', () => {
    const nuevos = calcularNuevosPrecios(
      { precio_sin_iva: 100, precio: 121, impuestos_internos: 4.1667 },
      10
    )
    expect(nuevos.precio_neto).toBe(110)
    expect(nuevos.precio_final).toBe(130)
  })

  it('aplica una rebaja', () => {
    const nuevos = calcularNuevosPrecios({ precio_sin_iva: 100, precio: 121 }, -10)
    expect(nuevos.precio_neto).toBe(90)
    expect(nuevos.precio_final).toBe(110)
  })

  it('devuelve null cuando el valor base es null o 0, para que el RPC preserve el valor previo', () => {
    const nuevos = calcularNuevosPrecios({ precio_sin_iva: null, precio: 0 }, 10)
    expect(nuevos.precio_neto).toBeNull()
    expect(nuevos.precio_final).toBeNull()
  })

  it('no deja un precio negativo tras una rebaja fuerte, lo lleva a 0', () => {
    const nuevos = calcularNuevosPrecios({ precio_sin_iva: 100, precio: 100 }, -150)
    expect(nuevos.precio_neto).toBe(0)
    expect(nuevos.precio_final).toBe(0)
  })

  it('nunca toca impuestos_internos: siempre devuelve null para que el RPC lo preserve', () => {
    // impuestos_internos es un % sobre el neto (no un precio): escalarlo con el
    // factor de aumento y redondearlo a múltiplo de 10 lo destruye (ver precios.ts).
    const conImpuesto = calcularNuevosPrecios(
      { precio_sin_iva: 100, precio: 121, impuestos_internos: 8.6956 },
      10
    )
    expect(conImpuesto.imp_internos).toBeNull()

    const sinImpuesto = calcularNuevosPrecios({ precio_sin_iva: 100, precio: 121 }, 10)
    expect(sinImpuesto.imp_internos).toBeNull()
  })
})
