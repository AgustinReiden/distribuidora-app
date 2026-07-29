import { describe, it, expect } from 'vitest';
import { clasificarBarrida, abreEnDia, UMBRAL_CIERRE_TEMPRANO } from './barridas';
import { serializarFranjas } from './horariosCliente';

/**
 * El orden de los grupos sale de cómo se aprovecha el día de reparto, no de una
 * clasificación teórica de horarios. Los casos vienen de una ruta real de 43
 * paradas donde el camión salía 08:00 y la primera parada abría 09:00.
 */

describe('clasificarBarrida — grupo 1: abren temprano Y cierran al mediodía', () => {
  it.each([
    ['07:00-11:00'],
    ['07:30-12:30'],
    ['08:00-11:00'],
    ['08:00-14:00'],
    ['08:30-14:00'],
  ])('"%s" → grupo 1 (se hace apenas sale el camión)', (horario) => {
    expect(clasificarBarrida(horario).barrida).toBe(1);
  });

  it('el horario cortado que abre temprano también entra', () => {
    expect(clasificarBarrida('08:00-14:00 y 17:00-23:00').barrida).toBe(1);
  });

  it('exige las DOS condiciones: abrir temprano no alcanza si cierra tarde', () => {
    // Este es el caso que hacía perder la mañana: abre 07:00 pero como cierra
    // 24:00 se lo puede visitar en cualquier momento, no urge.
    expect(clasificarBarrida('07:00-24:00').barrida).toBe(5);
    expect(clasificarBarrida('08:00-17:00').barrida).toBe(5);
    expect(clasificarBarrida('00:00-24:00').barrida).toBe(5);
  });

  it('exige las DOS condiciones: cerrar temprano no alcanza si abre 09:00', () => {
    // Abrir 09:00 y cerrar 14:00 es del mediodía, pero no sirve para la primera
    // hora: a las 08:15 está cerrado.
    expect(clasificarBarrida('09:00-14:00').barrida).toBe(3);
  });

  it('el umbral de apertura es estricto: 09:00 en punto NO es madrugador', () => {
    // Mismo cierre (13:30), sólo cambia la apertura: 08:30 entra al grupo 1 y
    // 09:00 cae al 3 (13:30 pasa las 13, así que tampoco es del 2).
    expect(clasificarBarrida('08:30-13:30').barrida).toBe(1);
    expect(clasificarBarrida('09:00-13:30').barrida).toBe(3);
  });
});

describe('clasificarBarrida — grupos 2 y 3: por hora de cierre', () => {
  it.each([
    ['09:00-13:00'],
    ['09:30-13:00'],
    ['10:00-12:30'],
  ])('"%s" cierra hasta las 13 → grupo 2', (horario) => {
    expect(clasificarBarrida(horario).barrida).toBe(2);
  });

  it.each([
    ['09:00-14:00'],
    ['09:00-14:30'],
    ['10:00-14:00'],
  ])('"%s" cierra hasta las 14:30 → grupo 3', (horario) => {
    expect(clasificarBarrida(horario).barrida).toBe(3);
  });

  it('el corte de las 14:30 es inclusivo', () => {
    expect(clasificarBarrida(`09:00-${UMBRAL_CIERRE_TEMPRANO}`).barrida).toBe(3);
  });

  it('un minuto después del corte ya es del último grupo', () => {
    expect(clasificarBarrida('09:00-15:00').barrida).toBe(5);
  });
});

describe('clasificarBarrida — grupo 4: sin horario', () => {
  it.each([null, undefined, '', '   '])('vacío (%s) → grupo 4 sin ventanas', (v) => {
    const r = clasificarBarrida(v as string | null | undefined);
    expect(r.barrida).toBe(4);
    expect(r.ventanas).toEqual([]);
  });

  it('texto libre no convertido cae en el grupo 4, no rompe', () => {
    const r = clasificarBarrida('Lunes a sábado de 9 a 14');
    expect(r.barrida).toBe(4);
    expect(r.ventanas).toEqual([]);
  });
});

describe('clasificarBarrida — grupo 5: corrido o abren tarde', () => {
  it.each([
    ['00:00-24:00'],
    ['07:00-23:30'],
    ['08:00-17:00'],
    ['09:00-20:00'],
    ['10:00-24:00'],
    ['11:00-23:30'],
    ['14:00-24:00'],
  ])('"%s" → grupo 5', (horario) => {
    expect(clasificarBarrida(horario).barrida).toBe(5);
  });
});

describe('clasificarBarrida — ventanas', () => {
  it('devuelve TODAS las franjas, no solo la primera', () => {
    const r = clasificarBarrida('08:00-14:00 y 17:00-23:00');
    expect(serializarFranjas(r.ventanas)).toBe('08:00-14:00 y 17:00-23:00');
  });
});

describe('clasificarBarrida — orden relativo de la ruta real', () => {
  it('los madrugadores van antes que los de las 9 y que los corridos', () => {
    const g = (h: string) => clasificarBarrida(h).barrida;
    // Caso exacto del reclamo: el de 09:00 arrancaba la ruta y el de 07:00
    // quedaba segundo. Ahora el de 07:00 pertenece a un grupo anterior.
    expect(g('07:00-11:00')).toBeLessThan(g('09:00-14:00'));
    expect(g('07:30-12:30')).toBeLessThan(g('09:00-14:00'));
    expect(g('09:00-13:00')).toBeLessThan(g('09:00-14:00'));
    expect(g('09:00-14:00')).toBeLessThan(g('08:00-17:00'));
  });
});

describe('abreEnDia', () => {
  // 2026-07-27 es lunes; 2026-08-01 sábado; 2026-08-02 domingo.
  const LUNES = '2026-07-27';
  const SABADO = '2026-08-01';
  const DOMINGO = '2026-08-02';

  it('lunes a viernes NO abre el sábado', () => {
    expect(abreEnDia('1111100', SABADO)).toBe(false);
  });

  it('lunes a viernes sí abre el lunes', () => {
    expect(abreEnDia('1111100', LUNES)).toBe(true);
  });

  it('lunes a sábado abre el sábado pero no el domingo', () => {
    expect(abreEnDia('1111110', SABADO)).toBe(true);
    expect(abreEnDia('1111110', DOMINGO)).toBe(false);
  });

  it('todos los días abre siempre', () => {
    expect(abreEnDia('1111111', DOMINGO)).toBe(true);
  });

  it('sin dato asume que abre (no saltear por falta de carga)', () => {
    expect(abreEnDia(null, SABADO)).toBe(true);
    expect(abreEnDia(undefined, SABADO)).toBe(true);
    expect(abreEnDia('', SABADO)).toBe(true);
  });

  it('bitmask mal formado se ignora en vez de romper el ruteo', () => {
    expect(abreEnDia('11111', SABADO)).toBe(true);
    expect(abreEnDia('abcdefg', SABADO)).toBe(true);
  });

  it('fecha inválida se ignora', () => {
    expect(abreEnDia('1111100', 'no-es-fecha')).toBe(true);
  });

  it('no se corre un día por zona horaria (fecha parseada como local)', () => {
    expect(abreEnDia('0000001', DOMINGO)).toBe(true);
    expect(abreEnDia('0000010', DOMINGO)).toBe(false);
  });
});
