import { describe, it, expect } from 'vitest';
import { parsearCantidadExcel } from './parsearCantidadExcel';

describe('parsearCantidadExcel', () => {
  it.each([
    [null, null],
    [undefined, null],
    ['', null],
    ['abc', null],
    [0, null],
    ['0', null],
    [-5, null],
    ['-5', null],
  ])('%s -> null (celda vacia o invalida)', (valor, esperado) => {
    expect(parsearCantidadExcel(valor as never)).toBe(esperado);
  });

  it.each([
    [10, 10],
    ['10', 10],
    [10.6, 11],
    ['1.500,50', 1501],
  ])('%s -> %i', (valor, esperado) => {
    expect(parsearCantidadExcel(valor as never)).toBe(esperado);
  });
});
