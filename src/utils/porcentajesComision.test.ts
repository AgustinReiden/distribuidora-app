import { describe, it, expect } from 'vitest'
import { textoPorcentajeComision, type PorcentajeComision } from './porcentajesComision'

const base: PorcentajeComision = {
  pct: 3, regla_id: null, origen: 'por_defecto', rol: 'preventista', cargado_por: 'Ana',
  cargado_el: '2026-11-01', pedidos: 1, base: 300000, comision: 9000,
}

describe('textoPorcentajeComision', () => {
  it('el % por defecto de preventista, con quién y cuándo', () => {
    expect(textoPorcentajeComision(base)).toBe('3 % por defecto de preventista · lo cargó Ana el 01/11/2026 · 1 pedido')
  })

  it('el del resto, con decimales y varios pedidos', () => {
    expect(textoPorcentajeComision({ ...base, pct: 0.5, rol: 'resto', pedidos: 4 }))
      .toBe('0,5 % por defecto del resto (admin, encargado) · lo cargó Ana el 01/11/2026 · 4 pedidos')
  })

  it('una regla cargada por el sistema', () => {
    expect(textoPorcentajeComision({ ...base, origen: 'regla', regla_id: 7, rol: null, cargado_por: null, cargado_el: null }))
      .toBe('3 % de una regla · lo cargó el sistema · 1 pedido')
  })
})
