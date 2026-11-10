import { describe, it, expect } from 'vitest';
import { normalizarNumero } from './normalizarNumero';
import { parsearCantidadExcel } from './parsearCantidadExcel';

describe('normalizarNumero', () => {
  it.each([
    [null, 0],
    [undefined, 0],
    ['', 0],
    ['abc', 0],
    [1500, 1500],
    [1.5, 1.5],
  ])('%s -> %s (vacío, inválido o ya número)', (valor, esperado) => {
    expect(normalizarNumero(valor as never)).toBe(esperado);
  });

  it.each([
    ['1.500,50', 1500.5],
    ['1,500.50', 1500.5],
    ['1500,50', 1500.5],
    ['$ 1.234,00', 1234],
    ['1500', 1500],
  ])('%s -> %s (los formatos que ya leía)', (valor, esperado) => {
    expect(normalizarNumero(valor)).toBe(esperado);
  });

  // STK-8 (#1516): una celda de texto "1.500" es mil quinientos, no 1,5.
  it.each([
    ['1.500', 1500],
    ['12.345.678', 12345678],
    ['-1.500', -1500],
    ['999.999', 999999],
  ])('%s -> %s (punto de miles sin coma)', (valor, esperado) => {
    expect(normalizarNumero(valor)).toBe(esperado);
  });

  it.each([
    ['1.5', 1.5],
    ['1.50', 1.5],
    ['1.5000', 1.5],
    ['0.500', 0.5],
    ['1234.567', 1234.567],
  ])('%s -> %s (sigue siendo decimal)', (valor, esperado) => {
    expect(normalizarNumero(valor)).toBe(esperado);
  });

  it('la cantidad del import: "1.500" son 1500 unidades', () => {
    expect(parsearCantidadExcel('1.500')).toBe(1500);
  });
});
