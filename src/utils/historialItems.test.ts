import { describe, it, expect } from 'vitest'
import { parsearLineasHistorial, compararItemsHistorial } from './historialItems'

const comparar = (a: string, n: string) => {
  const ant = parsearLineasHistorial(a)
  const nue = parsearLineasHistorial(n)
  if (!ant || !nue) throw new Error('no parseó')
  return compararItemsHistorial(ant, nue)
}

describe('parsearLineasHistorial', () => {
  it('normaliza una línea actual (mig 313)', () => {
    const r = parsearLineasHistorial(
      '[{"producto_id": 314, "cantidad": 2, "precio_unitario": 0, "es_bonificacion": true, "descripcion_regalo": "2 Botellas [Sustituido por: X]"}]'
    )
    expect(r).toEqual([
      { productoId: '314', cantidad: 2, precioUnitario: 0, esBonificacion: true, descripcionRegalo: '2 Botellas [Sustituido por: X]' },
    ])
  })

  it('tolera filas viejas: sin es_bonificacion (=> false) y con claves extra', () => {
    const r = parsearLineasHistorial(
      '[{"cantidad": 6, "producto_id": 226, "iva_unitario": 0, "neto_unitario": 15041.3, "porcentaje_iva": 21, "precio_unitario": 18200, "impuestos_internos_unitario": 0, "_reparto": [1]}]'
    )
    expect(r).toEqual([
      { productoId: '226', cantidad: 6, precioUnitario: 18200, esBonificacion: false, descripcionRegalo: null },
    ])
  })

  it('acepta el precio como número o como decimal y el id como texto', () => {
    const r = parsearLineasHistorial('[{"producto_id": "86", "cantidad": 1, "precio_unitario": 8500.00}]')
    expect(r?.[0].productoId).toBe('86')
    expect(r?.[0].precioUnitario).toBe(8500)
  })

  it('sin precio => null (no cero)', () => {
    const r = parsearLineasHistorial('[{"producto_id": 1, "cantidad": 1}]')
    expect(r?.[0].precioUnitario).toBeNull()
  })

  it('un array vacío es un array parseable', () => {
    expect(parsearLineasHistorial('[]')).toEqual([])
  })

  it('devuelve null si no es un array JSON', () => {
    expect(parsearLineasHistorial('cualquier texto')).toBeNull()
    expect(parsearLineasHistorial('')).toBeNull()
    expect(parsearLineasHistorial('{"producto_id": 1}')).toBeNull()
    expect(parsearLineasHistorial('[1, 2]')).toBeNull()
    expect(parsearLineasHistorial('[{"cantidad": 1}]')).toBeNull()
    expect(parsearLineasHistorial('[{"producto_id": 1, "cantidad": "mucho"}]')).toBeNull()
  })
})

describe('compararItemsHistorial', () => {
  const A = '[{"producto_id": 86, "cantidad": 1, "precio_unitario": 8500.00, "es_bonificacion": false}]'

  it('sin cambios => una fila igual', () => {
    const filas = comparar(A, A)
    expect(filas).toHaveLength(1)
    expect(filas[0].estado).toBe('igual')
    expect(filas[0].cambios).toEqual([])
  })

  it('cantidad cambiada', () => {
    const filas = comparar(A, A.replace('"cantidad": 1', '"cantidad": 3'))
    expect(filas[0].estado).toBe('cambiado')
    expect(filas[0].cambios).toEqual([{ campo: 'cantidad', antes: 1, despues: 3 }])
  })

  it('precio 8500.00 vs 8500 NO es cambio', () => {
    const filas = comparar(A, '[{"producto_id": 86, "cantidad": 1, "precio_unitario": 8500, "es_bonificacion": false}]')
    expect(filas[0].estado).toBe('igual')
  })

  it('precio realmente distinto', () => {
    const filas = comparar(A, A.replace('8500.00', '9000.00'))
    expect(filas[0].cambios).toEqual([{ campo: 'precio', antes: 8500, despues: 9000 }])
  })

  it('producto agregado y producto quitado', () => {
    const filas = comparar(
      A,
      '[{"producto_id": 90, "cantidad": 2, "precio_unitario": 100, "es_bonificacion": false}]'
    )
    expect(filas.map(f => [f.estado, f.productoId])).toEqual([
      ['agregado', '90'],
      ['quitado', '86'],
    ])
  })

  it('regalo con descripción cambiada', () => {
    const filas = comparar(
      '[{"producto_id": 314, "cantidad": 2, "precio_unitario": 0, "es_bonificacion": true, "descripcion_regalo": "2 Botellas Limón"}]',
      '[{"producto_id": 314, "cantidad": 2, "precio_unitario": 0, "es_bonificacion": true, "descripcion_regalo": "2 Botellas Limón [Sustituido por: NARANJA]"}]'
    )
    expect(filas[0].estado).toBe('cambiado')
    expect(filas[0].esBonificacion).toBe(true)
    expect(filas[0].cambios).toEqual([
      { campo: 'descripcion', antes: '2 Botellas Limón', despues: '2 Botellas Limón [Sustituido por: NARANJA]' },
    ])
  })

  it('fila vieja: cantidad 2 => 6, precio sin cambio, sin es_bonificacion del lado nuevo', () => {
    const filas = comparar(
      '[{"cantidad": 2, "producto_id": 226, "es_bonificacion": false, "precio_unitario": 18200.00}]',
      '[{"cantidad": 6, "producto_id": 226, "iva_unitario": 0, "neto_unitario": 15041.3, "porcentaje_iva": 21, "precio_unitario": 18200, "impuestos_internos_unitario": 0}]'
    )
    expect(filas).toHaveLength(1)
    expect(filas[0].estado).toBe('cambiado')
    expect(filas[0].cambios).toEqual([{ campo: 'cantidad', antes: 2, despues: 6 }])
  })

  it('el mismo producto como venta y como regalo son claves distintas', () => {
    const filas = comparar(
      '[{"producto_id": 5, "cantidad": 1, "precio_unitario": 10, "es_bonificacion": false}]',
      '[{"producto_id": 5, "cantidad": 1, "precio_unitario": 10, "es_bonificacion": false}, {"producto_id": 5, "cantidad": 1, "precio_unitario": 0, "es_bonificacion": true}]'
    )
    expect(filas.map(f => [f.estado, f.esBonificacion])).toEqual([
      ['igual', false],
      ['agregado', true],
    ])
  })

  it('misma clave repetida: empareja en orden y lo sobrante es agregado/quitado', () => {
    const l = (c: number) => `{"producto_id": 7, "cantidad": ${c}, "precio_unitario": 10, "es_bonificacion": false}`
    const filas = comparar(`[${l(1)}, ${l(2)}]`, `[${l(1)}, ${l(5)}, ${l(9)}]`)
    expect(filas.map(f => f.estado)).toEqual(['igual', 'cambiado', 'agregado'])
    expect(filas[1].cambios).toEqual([{ campo: 'cantidad', antes: 2, despues: 5 }])

    const inversa = comparar(`[${l(1)}, ${l(2)}, ${l(3)}]`, `[${l(1)}]`)
    expect(inversa.map(f => f.estado)).toEqual(['igual', 'quitado', 'quitado'])
  })

  it('orden: ventas primero y regalos después, siguiendo el lado nuevo; lo quitado al final de su grupo', () => {
    const v = (id: number) => `{"producto_id": ${id}, "cantidad": 1, "precio_unitario": 10, "es_bonificacion": false}`
    const r = (id: number) => `{"producto_id": ${id}, "cantidad": 1, "precio_unitario": 0, "es_bonificacion": true}`
    const filas = comparar(`[${v(1)}, ${r(8)}, ${v(2)}]`, `[${r(9)}, ${v(3)}, ${v(1)}]`)
    expect(filas.map(f => [f.estado, f.productoId, f.esBonificacion])).toEqual([
      ['agregado', '3', false],
      ['igual', '1', false],
      ['quitado', '2', false],
      ['agregado', '9', true],
      ['quitado', '8', true],
    ])
  })
})
