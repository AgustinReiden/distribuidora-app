import { describe, it, expect } from 'vitest'
import { parsePrecio } from './calculations'
import { normalizarNumero } from './normalizarNumero'
import { parseMonto } from './personal'

describe('parsePrecio', () => {
  it('redondea a 2 decimales', () => {
    // Con coma: «10.456» sin coma es diez mil cuatrocientos cincuenta y seis (#1560).
    expect(parsePrecio('10,456')).toBe(10.46)
    expect(parsePrecio('10,454')).toBe(10.45)
    expect(parsePrecio('1234.567')).toBe(1234.57)
  })

  it('devuelve 0 para strings inválidos', () => {
    expect(parsePrecio('abc')).toBe(0)
    expect(parsePrecio('')).toBe(0)
    expect(parsePrecio(null as unknown as string)).toBe(0)
    expect(parsePrecio(undefined as unknown as string)).toBe(0)
  })

  it('maneja valores numéricos directos', () => {
    expect(parsePrecio(99.999)).toBe(100)
    expect(parsePrecio(0.005)).toBe(0.01)
  })

  it('trunca floating point drift', () => {
    expect(parsePrecio(0.1 + 0.2)).toBe(0.3)
  })

  it('acepta comas como separador decimal (es-AR)', () => {
    expect(parsePrecio('10,5')).toBe(10.5)
    expect(parsePrecio('1.234,56')).toBe(1234.56)
    // Caso del bug de edición de precio en mobile: el teclado es-AR tipea coma
    // ("0,1" para un regalo). Con type="text"+inputMode="decimal" el valor llega
    // a parsePrecio y se convierte (antes el type="number" lo descartaba).
    expect(parsePrecio('0,1')).toBe(0.1)
  })

  it('trimea whitespace en strings', () => {
    expect(parsePrecio('  10,50  ')).toBe(10.5)
    expect(parsePrecio('\t99.99\n')).toBe(99.99)
  })

  it('maneja números negativos', () => {
    expect(parsePrecio('-10.50')).toBe(-10.5)
    expect(parsePrecio('-0,01')).toBe(-0.01)
    expect(parsePrecio(-99.999)).toBe(-100)
  })

  it('devuelve 0 para Infinity y NaN', () => {
    expect(parsePrecio(Infinity)).toBe(0)
    expect(parsePrecio(-Infinity)).toBe(0)
    expect(parsePrecio(NaN)).toBe(0)
  })

  // #1560: la app muestra «$ 150.000,00», y el que tipea escribe así.
  it.each([
    ['1.500', 1500],
    ['150.000', 150000],
    ['1.500,50', 1500.5],
    ['1,5', 1.5],
    ['0,5', 0.5],
    ['12.50', 12.5],
    ['1.234.567', 1234567],
    ['1.234.567,89', 1234567.89],
    ['$ 150.000', 150000],
    ['$150.000,00', 150000],
    ['280 000', 280000],
    ['1,500.50', 1500.5],
    ['0.500', 0.5],
    ['1.5', 1.5],
    ['1.5000', 1.5],
    ['150000', 150000],
    ['1.500,', 1500],
  ])('lee %j como %d (punto de miles, coma decimal)', (texto, esperado) => {
    expect(parsePrecio(texto)).toBe(esperado)
  })

  it('un number no pasa por el string: 1.125 no se lee como 1125', () => {
    expect(parsePrecio(1.125)).toBe(1.13)
    expect(parsePrecio(150.5)).toBe(150.5)
  })
})

// #1560: había tres lectores con tres convenciones, y la misma cadena valía $150 en un cobro y
// $150.000 en un gasto. Ahora parsePrecio lee con normalizarNumero, y parseMonto, que es
// estricto, o rechaza la cadena (null) o la lee igual. Ninguna cadena vale dos números.
describe('los tres lectores de plata tipeada dan lo mismo', () => {
  const CADENAS = [
    '1.500', '150.000', '1.500,50', '1,5', '0,5', '12.50', '1.234.567', '1.234,56',
    '280.000', '280.000,50', '280 000', '$ 280.000', '$280.000', '  3000  ', '0', '150000',
    '10,5', '280.000,', '0,', '1.5', '1.50', '1.5000', '0.500', '1234.567', '999.999',
    '12.345.678', '1,500.50', '1500,50', '$ 1.234,00', '280,000', '1,234.56', '280.000.',
    '12abc', 'abc', '', '1.2345', '280.00.0', '10.456', '0.5', '99.99', '1.000.000,01',
  ]

  it.each(CADENAS)('%j', texto => {
    const precio = parsePrecio(texto)
    expect(precio).toBe(Math.round(normalizarNumero(texto) * 100) / 100)
    const monto = parseMonto(texto)
    if (monto !== null) expect(monto).toBe(precio)
  })
})
