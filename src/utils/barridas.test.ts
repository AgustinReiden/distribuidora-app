import { describe, it, expect } from 'vitest';
import { clasificarBarrida, abreEnDia, UMBRAL_CIERRE_TEMPRANO } from './barridas';
import { serializarFranjas } from './horariosCliente';

describe('clasificarBarrida — barrida 1 (cierran al mediodía)', () => {
  it('una sola franja que cierra al mediodía y no reabre: "09:00-14:00"', () => {
    // El caso más problemático de los datos reales: no es "cortado", pero es
    // el que más rechaza si se lo deja para el final.
    expect(clasificarBarrida('09:00-14:00').barrida).toBe(1);
  });

  it('horario cortado: "08:00-14:00 y 17:00-23:00"', () => {
    expect(clasificarBarrida('08:00-14:00 y 17:00-23:00').barrida).toBe(1);
  });

  it.each([
    '08:30-14:00',
    '07:30-14:30',
    '09:00-13:30',
    '09:30-13:00',
    '08:30-12:00',
  ])('cierra temprano: "%s" → barrida 1', (horario) => {
    expect(clasificarBarrida(horario).barrida).toBe(1);
  });

  it('el umbral es inclusivo: cerrar exactamente a las 14:30 es barrida 1', () => {
    expect(clasificarBarrida(`08:00-${UMBRAL_CIERRE_TEMPRANO}`).barrida).toBe(1);
  });

  it('un minuto después del umbral ya no es barrida 1', () => {
    expect(clasificarBarrida('08:00-15:00').barrida).toBe(3);
  });

  it('devuelve TODAS las franjas como ventanas, no solo la primera', () => {
    const r = clasificarBarrida('08:00-14:00 y 17:00-23:00');
    expect(serializarFranjas(r.ventanas)).toBe('08:00-14:00 y 17:00-23:00');
  });
});

describe('clasificarBarrida — barrida 2 (sin horario)', () => {
  it.each([null, undefined, '', '   '])('vacío (%s) → barrida 2 sin ventanas', (v) => {
    const r = clasificarBarrida(v as string | null | undefined);
    expect(r.barrida).toBe(2);
    expect(r.ventanas).toEqual([]);
  });

  it('texto libre no convertido cae en barrida 2, no rompe', () => {
    const r = clasificarBarrida('Lunes a sábado de 9 a 14');
    expect(r.barrida).toBe(2);
    expect(r.ventanas).toEqual([]);
  });
});

describe('clasificarBarrida — barrida 3 (corrido / abren tarde)', () => {
  it.each([
    '00:00-24:00',
    '07:00-23:30',
    '08:00-17:00',
    '09:00-20:00',
    '10:00-24:00',
    '11:00-23:30',
  ])('atiende hasta tarde: "%s" → barrida 3', (horario) => {
    expect(clasificarBarrida(horario).barrida).toBe(3);
  });

  it('abre tarde: "14:00-24:00" → barrida 3', () => {
    expect(clasificarBarrida('14:00-24:00').barrida).toBe(3);
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
    // Con new Date('2026-08-02') en UTC-3 daría sábado y no domingo.
    expect(abreEnDia('0000001', DOMINGO)).toBe(true);
    expect(abreEnDia('0000010', DOMINGO)).toBe(false);
  });
});
