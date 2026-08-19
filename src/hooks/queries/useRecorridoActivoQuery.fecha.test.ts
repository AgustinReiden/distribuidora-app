/**
 * `fechaDeRuta` — qué día de ruta le toca ver al chofer.
 *
 * El bug que cubre: la query filtraba `fecha = hoy` a secas, así que a las
 * 00:05 la ruta que el chofer está haciendo pasaba a ser "de ayer" y la
 * pantalla le decía que el administrador todavía no armó la suya. Con el camión
 * cargado y media ruta sin entregar.
 */
import { describe, it, expect } from 'vitest';
import { fechaDeRuta } from './useRecorridoActivoQuery';

describe('fechaDeRuta', () => {
  describe('en la madrugada acepta la ruta de ayer', () => {
    it('devuelve hoy y el día anterior', () => {
      expect(fechaDeRuta('2026-08-19', 0)).toEqual({ hoy: '2026-08-19', ayer: '2026-08-18' });
      expect(fechaDeRuta('2026-08-19', 5).ayer).toBe('2026-08-18');
    });

    it('cruza el principio de mes', () => {
      expect(fechaDeRuta('2026-08-01', 1).ayer).toBe('2026-07-31');
    });

    it('cruza el principio de año', () => {
      expect(fechaDeRuta('2026-01-01', 1).ayer).toBe('2025-12-31');
    });

    // Argentina es UTC-3: anclar a mediodía evita que el `new Date` se corra un
    // día al normalizar a la zona local.
    it('no se corre un día por zona horaria', () => {
      expect(fechaDeRuta('2026-03-01', 1).ayer).toBe('2026-02-28');
      expect(fechaDeRuta('2024-03-01', 1).ayer).toBe('2024-02-29');
    });
  });

  /**
   * Pasada la madrugada, "no tenés ruta" es la respuesta correcta. Hay decenas
   * de recorridos que quedaron `en_curso` de días pasados porque nada los
   * cierra: sin este corte, un chofer sin ruta hoy veria la de ayer —con
   * paradas ya entregadas— a las diez de la mañana.
   */
  describe('durante el día NO ofrece la de ayer', () => {
    it.each([6, 10, 15, 23])('a las %i hs devuelve ayer = null', hora => {
      expect(fechaDeRuta('2026-08-19', hora)).toEqual({ hoy: '2026-08-19', ayer: null });
    });
  });
});
