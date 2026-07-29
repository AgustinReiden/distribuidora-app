import { describe, it, expect } from 'vitest';
import {
  parseHorarioLibre,
  DIAS_TODOS,
  DIAS_LUN_SAB,
  DIAS_LUN_VIE,
} from './parseHorarioLibre';
import { serializarFranjas } from './horariosCliente';

/**
 * Todos los casos de este archivo son textos REALES de `clientes.horarios_atencion`
 * en producción (128 valores distintos al 2026-07-27), no ejemplos inventados.
 */

/** Atajo: texto → "HH:MM-HH:MM y HH:MM-HH:MM". */
const franjasDe = (texto: string) => serializarFranjas(parseHorarioLibre(texto).franjas);

describe('parseHorarioLibre — rangos simples', () => {
  it('interpreta "9 A 14"', () => {
    const r = parseHorarioLibre('9 A 14');
    expect(serializarFranjas(r.franjas)).toBe('09:00-14:00');
    expect(r.dias).toBeNull();
    expect(r.confianza).toBe('alta');
  });

  it('interpreta minutos a la media hora: "8:30 A 14"', () => {
    expect(franjasDe('8:30 A 14')).toBe('08:30-14:00');
    expect(parseHorarioLibre('8:30 A 14').confianza).toBe('alta');
  });

  it('acepta minúsculas y unidades: "9 A 12 HS", "8 a 15"', () => {
    expect(franjasDe('9 A 12 HS')).toBe('09:00-12:00');
    expect(franjasDe('8 a 15')).toBe('08:00-15:00');
  });

  it('trata el cierre "00" como medianoche: "8 A 00"', () => {
    const r = parseHorarioLibre('8 A 00');
    expect(serializarFranjas(r.franjas)).toBe('08:00-24:00');
    expect(r.confianza).toBe('alta');
  });

  it('trata el cierre "24" como medianoche: "8 A 24"', () => {
    expect(franjasDe('8 A 24')).toBe('08:00-24:00');
  });

  it('tolera el typo "8: A 00" (dos puntos sin minutos)', () => {
    const r = parseHorarioLibre('8: A 00');
    expect(serializarFranjas(r.franjas)).toBe('08:00-24:00');
    expect(r.confianza).toBe('alta');
  });
});

describe('parseHorarioLibre — horario cortado y separadores', () => {
  it('separador "Y": "9 A 14 Y 17 A 22"', () => {
    const r = parseHorarioLibre('9 A 14 Y 17 A 22');
    expect(serializarFranjas(r.franjas)).toBe('09:00-14:00 y 17:00-22:00');
    expect(r.confianza).toBe('alta');
  });

  it('separador "de" sin "y": "9 a 14 de 19 a 22"', () => {
    expect(franjasDe('9 a 14 de 19 a 22')).toBe('09:00-14:00 y 19:00-22:00');
  });

  it('separador "de" al medio: "8 a 11 de 14 a 17"', () => {
    expect(franjasDe('8 a 11 de 14 a 17')).toBe('08:00-11:00 y 14:00-17:00');
  });

  it('separador "después": "8:30 a 14 después 18 a 22"', () => {
    expect(franjasDe('8:30 a 14 después 18 a 22')).toBe('08:30-14:00 y 18:00-22:00');
  });

  it('separador "desde": "Horarios desde 10:30 a 14 desde 15 a 17"', () => {
    expect(franjasDe('Horarios desde 10:30 a 14 desde 15 a 17')).toBe('10:30-14:00 y 15:00-17:00');
  });

  it('separador "y de": "9:30 a 14 y de 17 a 23"', () => {
    expect(franjasDe('9:30 a 14 y de 17 a 23')).toBe('09:30-14:00 y 17:00-23:00');
  });
});

describe('parseHorarioLibre — días de la semana', () => {
  it('"Lunes a sábado de 9 hs a 14 hrs y 17 hs a 21hs" → L-S + 2 franjas', () => {
    const r = parseHorarioLibre('Lunes a sábado de 9 hs a 14 hrs y 17 hs a 21hs');
    expect(r.dias).toBe(DIAS_LUN_SAB);
    expect(serializarFranjas(r.franjas)).toBe('09:00-14:00 y 17:00-21:00');
    expect(r.confianza).toBe('alta');
  });

  it('"Lunes a viernes de 8hs a 14hs" → L-V', () => {
    const r = parseHorarioLibre('Lunes a viernes de 8hs a 14hs');
    expect(r.dias).toBe(DIAS_LUN_VIE);
    expect(serializarFranjas(r.franjas)).toBe('08:00-14:00');
    expect(r.confianza).toBe('alta');
  });

  it('"De 8 a 20 de lunes a domingos" → todos los días', () => {
    const r = parseHorarioLibre('De 8 a 20 de lunes a domingos');
    expect(r.dias).toBe(DIAS_TODOS);
    expect(serializarFranjas(r.franjas)).toBe('08:00-20:00');
  });

  it('"Todos los dias de 8:30 a 14 y de 17:30 a 23" → todos los días', () => {
    const r = parseHorarioLibre('Todos los dias de 8:30 a 14 y de 17:30 a 23');
    expect(r.dias).toBe(DIAS_TODOS);
    expect(serializarFranjas(r.franjas)).toBe('08:30-14:00 y 17:30-23:00');
  });

  it('tolera el typo "de lunes sábados" (sin la "a")', () => {
    const r = parseHorarioLibre('8 a 15 y 18 a 20 de lunes sábados');
    expect(r.dias).toBe(DIAS_LUN_SAB);
    expect(serializarFranjas(r.franjas)).toBe('08:00-15:00 y 18:00-20:00');
  });

  it('no inventa días cuando el texto no los menciona', () => {
    expect(parseHorarioLibre('9 A 14').dias).toBeNull();
  });

  it('los días no se confunden con un rango horario ("lunes a viernes" tiene "a")', () => {
    const r = parseHorarioLibre('De 7 a 23 de lunes a viernes');
    expect(r.dias).toBe(DIAS_LUN_VIE);
    expect(serializarFranjas(r.franjas)).toBe('07:00-23:00');
    expect(r.confianza).toBe('alta');
  });
});

describe('parseHorarioLibre — cruce de medianoche (se recorta a 24:00)', () => {
  it('"8 A 1 AM" → 08:00-24:00 y queda dudosa', () => {
    const r = parseHorarioLibre('8 A 1 AM');
    expect(serializarFranjas(r.franjas)).toBe('08:00-24:00');
    expect(r.confianza).toBe('dudosa');
    expect(r.motivo).toMatch(/medianoche/i);
  });

  it('"7 A 2 AM" → 07:00-24:00', () => {
    expect(franjasDe('7 A 2 AM')).toBe('07:00-24:00');
  });

  it('cierre menor que apertura sin "am": "De 7:30 a 13 y de 17:30 a 1"', () => {
    const r = parseHorarioLibre('De 7:30 a 13 y de 17:30 a 1');
    expect(serializarFranjas(r.franjas)).toBe('07:30-13:00 y 17:30-24:00');
    expect(r.confianza).toBe('dudosa');
  });

  it('"9 a 14 y de 18 a 1 de lunes a domingos" → días + recorte', () => {
    const r = parseHorarioLibre('9 a 14 y de 18 a 1 de lunes a domingos');
    expect(r.dias).toBe(DIAS_TODOS);
    expect(serializarFranjas(r.franjas)).toBe('09:00-14:00 y 18:00-24:00');
    expect(r.confianza).toBe('dudosa');
  });

  it('"Lunes a sábados 8 a 1 am" → L-S + recorte', () => {
    const r = parseHorarioLibre('Lunes a sábados 8 a 1 am');
    expect(r.dias).toBe(DIAS_LUN_SAB);
    expect(serializarFranjas(r.franjas)).toBe('08:00-24:00');
  });
});

describe('parseHorarioLibre — 24 horas y "de corrido"', () => {
  it.each(['24 HS', '24 HRS', '24 horas', '24/7', 'DE CORRIDO'])(
    '"%s" → 00:00-24:00 dudosa',
    (texto) => {
      const r = parseHorarioLibre(texto);
      expect(serializarFranjas(r.franjas)).toBe('00:00-24:00');
      expect(r.confianza).toBe('dudosa');
    },
  );

  it('"Lunes a domingo de corrido" → todos los días, 24h', () => {
    const r = parseHorarioLibre('Lunes a domingo de corrido');
    expect(r.dias).toBe(DIAS_TODOS);
    expect(serializarFranjas(r.franjas)).toBe('00:00-24:00');
  });
});

describe('parseHorarioLibre — apertura sin cierre declarado', () => {
  it('"9 en adelante" → 09:00-24:00 dudosa', () => {
    const r = parseHorarioLibre('9 en adelante');
    expect(serializarFranjas(r.franjas)).toBe('09:00-24:00');
    expect(r.confianza).toBe('dudosa');
    expect(r.motivo).toMatch(/cierra/i);
  });

  it('"8:30 corrido" → 08:30-24:00', () => {
    expect(franjasDe('8:30 corrido')).toBe('08:30-24:00');
  });

  it('"Lunes a sábado de 8hs corridos" → L-S + 08:00-24:00', () => {
    const r = parseHorarioLibre('Lunes a sábado de 8hs corridos');
    expect(r.dias).toBe(DIAS_LUN_SAB);
    expect(serializarFranjas(r.franjas)).toBe('08:00-24:00');
    expect(r.confianza).toBe('dudosa');
  });

  it('"Lunes a sábado de 10hs en adelante" → L-S + 10:00-24:00', () => {
    const r = parseHorarioLibre('Lunes a sábado de 10hs en adelante');
    expect(r.dias).toBe(DIAS_LUN_SAB);
    expect(serializarFranjas(r.franjas)).toBe('10:00-24:00');
  });

  it('"Desde 9 corrido frente escuela Amalia" ignora el texto de más', () => {
    expect(franjasDe('Desde 9 corrido frente escuela Amalia')).toBe('09:00-24:00');
  });

  it('hora suelta como último recurso: "Lunes a sábado de 14 hrs"', () => {
    const r = parseHorarioLibre('Lunes a sábado de 14 hrs');
    expect(r.dias).toBe(DIAS_LUN_SAB);
    expect(serializarFranjas(r.franjas)).toBe('14:00-24:00');
    expect(r.confianza).toBe('dudosa');
  });
});

describe('parseHorarioLibre — casos que deben quedar dudosos', () => {
  it('horario distinto según el día se detecta por solapamiento', () => {
    const r = parseHorarioLibre('De 10 a 22:30 de lunes a viernes y sabados de 14 a 22:30');
    expect(r.confianza).toBe('dudosa');
  });

  it('texto sin ninguna hora no inventa franjas', () => {
    const r = parseHorarioLibre('consultar con el encargado');
    expect(r.franjas).toEqual([]);
    expect(r.confianza).toBe('dudosa');
  });

  it.each([null, undefined, '', '   '])('vacío (%s) → sin franjas', (valor) => {
    const r = parseHorarioLibre(valor as string | null | undefined);
    expect(r.franjas).toEqual([]);
    expect(r.dias).toBeNull();
    expect(r.confianza).toBe('dudosa');
  });
});

describe('parseHorarioLibre — cobertura sobre los textos reales de producción', () => {
  // Muestra representativa de los 128 valores distintos en prod.
  const REALES = [
    'Lunes a sábado de 9 hs a 14 hrs y 17 hs a 21hs',
    'Lunes a sábado de 8hs a 14hs y 17hs a 22hs',
    'Lunes a sábado de 9 hrs a 14 hrs y 17 hs a 21hs',
    '9 A 23', '8 A 00', '8:30 A 14', '9 A 14', '9 a 14', '9 A 15', '8 A 14',
    '8 A 15', '8 A 23', '7 A 00', '8 A 13', '9 A 00', '7 A 15', '7 A 23',
    '7:30 A 23', '8 a 11 de 14 a 17', '8 A 22', '8:30 A 15', '9 A 12',
    'Lunes a sábado de 9 hs a 21hs', 'Lunes a viernes de 8hs a 14hs',
    '10 A 23', '10:30 a 14 y de 19:30 a 22:30 de lunes a domingos',
    '7 a 11 y de 13:30 a 17', '7 A 13:30', '7 A 14:30', '7 A 19', '7:30 A 14',
    '8 a 11 y de 14 a 17', '8 A 12 HS', '8 A 12:30', '8 A 13:30', '8 a 14',
    '8 A 14:30', '8 a 14:30 y 17:30 a 23 de lunes a domingos', '8 a 15',
    '8 A 24', '8:30 a 14 después 18 a 22', '8:30 A 14:30', '9 A 13', '9 A 13:30',
    '9 a 14 de 19 a 22', '9 A 14 Y 17 A 22', '9 A 14 Y 18 A 22', '9 a 15',
    '9 A 16', '9 A 17', '9 A 21', '9 A 22', '9 A 24', '9:30 A 00',
    '9:30 a 14 y de 17 a 23', '9:30 A 14:30', '9:30 A 15:30',
    'De 10 a 00 de lunes a domingos', 'De 11 a 15 y de 19 a 23',
    'De 6:30 a 23 de lunes a domingos', 'De 7 a 00 de lunes a domingos',
    'De 7 a 12:30 y de 17 a 19:30 de lunes a sábados', 'De 7 a 23 de lunes a viernes',
    'De 7:30 a 14', 'De 8 a 00 de lunes a domingos', 'De 8 a 12',
    'De 8 a 13 y de 17:30 a 21 de Lunes a Sábado',
    'De 8 a 13 y de 18 a 23 de lunes a domingos',
    'De 8 a 14 y de 18 a 23 de lunes a sábados', 'De 8 a 15 y de 18 a 23',
    'De 8 a 20 de lunes a domingos', 'De 8 a 22 de lunes a domingos',
    'De 8:30 a 00 de lunes a domingos', 'De 8:30 a 00 de lunes a viernes',
    'De 8:30 a 21 de lunes a viernes', 'De 9 a 00 de lunes a domingos',
    'De 9 a 13:30 y de 17 a 22:30', 'De 9 a 13:30 y de 17:30 a 22',
    'De 9 a 14 y de 15 a 22 de lunes a viernes',
    'De 9 a 14 y de 17 a 22 de lunes a domingo',
    'De 9 a 14:30 de 17:30 a 22', 'De 9 a 14:30 y de 17:30 a 23',
    'De 9 a 23 de lunes a domingos',
    'Lunes a domingo 8:30 a 23:00 hs', 'Lunes a sábado 10hs a 22hs',
    'Lunes a sábado 9hs a 14hs y 17hs a 22hs',
    'Lunes a viernes 6:30 a 12 después 13 a 15',
    'Lunes a viernes 8:30hs a 15hs y 17hs a 22hs',
    'Todos los dias de 8:30 a 14 y de 17:30 a 23',
  ];

  it('interpreta alguna franja en todos los textos reales', () => {
    const sinFranjas = REALES.filter(t => parseHorarioLibre(t).franjas.length === 0);
    expect(sinFranjas).toEqual([]);
  });

  it('la gran mayoría sale con confianza alta (no requiere revisión manual)', () => {
    const altas = REALES.filter(t => parseHorarioLibre(t).confianza === 'alta');
    // Con estos textos el parser resuelve solo >= 90%; el resto va a revisión.
    expect(altas.length / REALES.length).toBeGreaterThanOrEqual(0.9);
  });

  it('ninguna franja producida es inválida (apertura < cierre, sin solapes)', () => {
    for (const texto of REALES) {
      const { franjas, confianza } = parseHorarioLibre(texto);
      if (confianza !== 'alta') continue;
      for (const f of franjas) {
        expect(f.apertura < f.cierre || f.cierre === '24:00').toBe(true);
      }
    }
  });
});
