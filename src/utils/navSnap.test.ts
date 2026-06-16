import { describe, it, expect } from 'vitest';
import { construirSnapper, snapEnRuta, distanciaEnRutaDe } from './navSnap';
import type { LatLngTuple } from './polyline';

// Ruta horizontal (lat constante) yendo al este: ~993 m por segmento a esa latitud.
const ruta: LatLngTuple[] = [
  [-26.80, -65.20],
  [-26.80, -65.19],
  [-26.80, -65.18],
];

describe('navSnap', () => {
  it('construirSnapper acumula distancias crecientes', () => {
    const s = construirSnapper(ruta);
    expect(s.cumdist[0]).toBe(0);
    expect(s.cumdist[1]).toBeGreaterThan(900);
    expect(s.cumdist[1]).toBeLessThan(1100);
    expect(s.cumdist[2]).toBeGreaterThan(s.cumdist[1]);
  });

  it('proyecta al segmento correcto con perpendicular y distancia en ruta', () => {
    const s = construirSnapper(ruta);
    // ~11 m al norte del medio del primer segmento.
    const snap = snapEnRuta(s, { lat: -26.8001, lng: -65.195 });
    expect(snap.segmentIndex).toBe(0);
    expect(snap.perpendicularM).toBeGreaterThan(5);
    expect(snap.perpendicularM).toBeLessThan(20);
    expect(snap.distanciaEnRuta).toBeGreaterThan(s.cumdist[1] * 0.4);
    expect(snap.distanciaEnRuta).toBeLessThan(s.cumdist[1] * 0.6);
  });

  it('detecta desvío grande (perpendicular alto)', () => {
    const s = construirSnapper(ruta);
    const snap = snapEnRuta(s, { lat: -26.799, lng: -65.195 }); // ~110 m al norte
    expect(snap.perpendicularM).toBeGreaterThan(80);
  });

  it('distanciaEnRutaDe mapea un vértice a su distancia acumulada', () => {
    const s = construirSnapper(ruta);
    const d = distanciaEnRutaDe(s, { lat: -26.80, lng: -65.19 });
    expect(Math.abs(d - s.cumdist[1])).toBeLessThan(20);
  });

  it('respeta el hint para ubicar el segundo segmento', () => {
    const s = construirSnapper(ruta);
    const snap = snapEnRuta(s, { lat: -26.80, lng: -65.185 }, 1);
    expect(snap.segmentIndex).toBe(1);
  });
});
