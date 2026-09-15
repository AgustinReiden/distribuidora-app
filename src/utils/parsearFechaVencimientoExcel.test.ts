import { describe, it, expect } from 'vitest';
import { parsearFechaVencimientoExcel } from './parsearFechaVencimientoExcel';

describe('parsearFechaVencimientoExcel', () => {
  it.each([
    [null, null],
    [undefined, null],
    ['', null],
    ['abc', null],
    ['32/13/2026', null],
  ])('%s -> null', (valor, esperado) => {
    expect(parsearFechaVencimientoExcel(valor as never)).toBe(esperado);
  });

  it('ISO -> recortado', () => {
    expect(parsearFechaVencimientoExcel('2026-10-01')).toBe('2026-10-01');
  });

  it('ISO con hora y Z -> recortado, sin corrimiento de día', () => {
    expect(parsearFechaVencimientoExcel('2026-10-01T00:00:00.000Z')).toBe('2026-10-01');
  });

  it('dd/mm/aaaa -> ISO', () => {
    expect(parsearFechaVencimientoExcel('01/10/2026')).toBe('2026-10-01');
  });

  it('dd-mm-aaaa -> ISO', () => {
    expect(parsearFechaVencimientoExcel('01-10-2026')).toBe('2026-10-01');
  });
});
