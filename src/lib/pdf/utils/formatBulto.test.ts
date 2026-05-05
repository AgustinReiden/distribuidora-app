import { describe, it, expect } from 'vitest';
import { formatAclaracionBulto } from './formatBulto';

describe('formatAclaracionBulto', () => {
  it('returns null when unidadesPorFardo is missing', () => {
    expect(formatAclaracionBulto(2, undefined, 'FARDO')).toBeNull();
    expect(formatAclaracionBulto(2, null, 'FARDO')).toBeNull();
    expect(formatAclaracionBulto(2, 0, 'FARDO')).toBeNull();
  });

  it('returns null when cantidad is 0 or invalid', () => {
    expect(formatAclaracionBulto(0, 2, 'FARDO')).toBeNull();
    expect(formatAclaracionBulto(NaN, 2, 'FARDO')).toBeNull();
  });

  it('returns "(MEDIO FARDO)" when cantidad/upf === 0.5', () => {
    expect(formatAclaracionBulto(1, 2, 'FARDO')).toBe('(MEDIO FARDO)');
    expect(formatAclaracionBulto(2, 4, 'FARDO')).toBe('(MEDIO FARDO)');
  });

  it('returns "(1 FARDO)" when cantidad/upf === 1', () => {
    expect(formatAclaracionBulto(2, 2, 'FARDO')).toBe('(1 FARDO)');
    expect(formatAclaracionBulto(5, 5, 'FARDO')).toBe('(1 FARDO)');
  });

  it('returns "(1 FARDO Y MEDIO)" when cantidad/upf === 1.5', () => {
    expect(formatAclaracionBulto(3, 2, 'FARDO')).toBe('(1 FARDO Y MEDIO)');
  });

  it('returns "(N FARDOS)" plural for integer multiples >= 2', () => {
    expect(formatAclaracionBulto(4, 2, 'FARDO')).toBe('(2 FARDOS)');
    expect(formatAclaracionBulto(6, 2, 'FARDO')).toBe('(3 FARDOS)');
    expect(formatAclaracionBulto(20, 2, 'FARDO')).toBe('(10 FARDOS)');
  });

  it('returns null for ambiguous fractions (not 0.5 / integer / 1.5)', () => {
    expect(formatAclaracionBulto(1, 3, 'FARDO')).toBeNull();   // 0.33
    expect(formatAclaracionBulto(2, 3, 'FARDO')).toBeNull();   // 0.66
    expect(formatAclaracionBulto(5, 2, 'FARDO')).toBe('(2 FARDOS Y MEDIO)'); // 2.5 → soportar
  });

  it('uses custom etiqueta when provided', () => {
    expect(formatAclaracionBulto(2, 2, 'CAJA')).toBe('(1 CAJA)');
    expect(formatAclaracionBulto(4, 2, 'CAJA')).toBe('(2 CAJAS)');
    expect(formatAclaracionBulto(1, 2, 'CAJA')).toBe('(MEDIA CAJA)');
  });

  it('falls back to FARDO when etiqueta is empty/null', () => {
    expect(formatAclaracionBulto(2, 2, undefined)).toBe('(1 FARDO)');
    expect(formatAclaracionBulto(2, 2, '')).toBe('(1 FARDO)');
  });
});
