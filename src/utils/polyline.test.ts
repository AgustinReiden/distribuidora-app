import { describe, it, expect } from 'vitest';
import { decodePolyline, decodePolylines } from './polyline';

describe('decodePolyline', () => {
  // Ejemplo canónico de la documentación de Google:
  // "_p~iF~ps|U_ulLnnqC_mqNvxq`@" → 3 puntos conocidos.
  it('decodifica el ejemplo canónico de Google', () => {
    const pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(pts).toHaveLength(3);
    expect(pts[0][0]).toBeCloseTo(38.5, 5);
    expect(pts[0][1]).toBeCloseTo(-120.2, 5);
    expect(pts[1][0]).toBeCloseTo(40.7, 5);
    expect(pts[1][1]).toBeCloseTo(-120.95, 5);
    expect(pts[2][0]).toBeCloseTo(43.252, 5);
    expect(pts[2][1]).toBeCloseTo(-126.453, 5);
  });

  it('string vacío → array vacío', () => {
    expect(decodePolyline('')).toEqual([]);
  });
});

describe('decodePolylines', () => {
  it('concatena varios tramos en orden', () => {
    const tramo = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
    const result = decodePolylines([tramo, tramo]);
    expect(result).toHaveLength(6);
  });

  it('null/undefined/vacío → array vacío', () => {
    expect(decodePolylines(null)).toEqual([]);
    expect(decodePolylines(undefined)).toEqual([]);
    expect(decodePolylines([])).toEqual([]);
  });
});
