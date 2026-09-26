import { describe, it, expect } from 'vitest';
import {
  absorberVecinos,
  barridasEfectivas,
  clasificarBarrida,
  abreEnDia,
  encajeEnHorario,
  finJornadaSugerida,
  intercalarSinCoordenadas,
  UMBRAL_CIERRE_TEMPRANO,
  type Barrida,
} from './barridas';
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

/**
 * El caso que motivó esto: una ruta real de 28 paradas donde la última era una
 * despensa de 09:00-14:00 — no porque quedara lejos, sino porque el cliente no
 * tiene coordenadas cargadas y todas esas paradas se anexaban al final.
 */
describe('intercalarSinCoordenadas', () => {
  const ruteadas = (...bs: Barrida[]) =>
    bs.map((barrida, i) => ({ pedido_id: `opt${i + 1}`, barrida }));

  it('la parada sin coordenadas va al final de SU barrida, no de la ruta', () => {
    const salida = intercalarSinCoordenadas(
      ruteadas(1, 3, 3, 5, 5),
      [{ pedido_id: 'sin1', barrida: 3 }],
    );
    expect(salida.map(p => p.pedido_id)).toEqual(['opt1', 'opt2', 'opt3', 'sin1', 'opt4', 'opt5']);
    expect(salida.map(p => p.orden)).toEqual([1, 2, 3, 4, 5, 6]);
  });

  it('conserva la barrida de la parada insertada (para la hoja de ruta)', () => {
    const salida = intercalarSinCoordenadas(ruteadas(1, 5), [{ pedido_id: 'sin1', barrida: 3 }]);
    expect(salida.find(p => p.pedido_id === 'sin1')?.barrida).toBe(3);
  });

  it('una barrida sin ninguna parada ruteada igual se ubica en su lugar', () => {
    // Nadie geocodificado cierra al mediodía, pero la que no tiene coordenadas sí:
    // tiene que entrar ANTES del bloque de los que cierran tarde.
    const salida = intercalarSinCoordenadas(ruteadas(1, 5, 5), [{ pedido_id: 'sin1', barrida: 3 }]);
    expect(salida.map(p => p.pedido_id)).toEqual(['opt1', 'sin1', 'opt2', 'opt3']);
  });

  it('respeta el orden entre barridas al insertar varias', () => {
    const salida = intercalarSinCoordenadas(
      ruteadas(1, 5),
      [{ pedido_id: 'sinB', barrida: 4 }, { pedido_id: 'sinA', barrida: 2 }],
    );
    expect(salida.map(p => p.pedido_id)).toEqual(['opt1', 'sinA', 'sinB', 'opt2']);
  });

  it('las de la última barrida quedan al final (no hay bloque posterior)', () => {
    const salida = intercalarSinCoordenadas(ruteadas(1, 3), [{ pedido_id: 'sin1', barrida: 5 }]);
    expect(salida.map(p => p.pedido_id)).toEqual(['opt1', 'opt2', 'sin1']);
  });

  it('varias en la misma barrida mantienen su orden relativo', () => {
    const salida = intercalarSinCoordenadas(
      ruteadas(3, 5),
      [{ pedido_id: 'sinA', barrida: 3 }, { pedido_id: 'sinB', barrida: 3 }],
    );
    expect(salida.map(p => p.pedido_id)).toEqual(['opt1', 'sinA', 'sinB', 'opt2']);
  });

  it('sin barridas (fallback sin ventanas) se mantiene el comportamiento previo', () => {
    const salida = intercalarSinCoordenadas(
      [{ pedido_id: 'opt1' }, { pedido_id: 'opt2' }],
      [{ pedido_id: 'sin1', barrida: 1 }],
    );
    expect(salida.map(p => p.pedido_id)).toEqual(['opt1', 'opt2', 'sin1']);
  });

  it('sin paradas para insertar devuelve el orden del optimizador tal cual', () => {
    const salida = intercalarSinCoordenadas(ruteadas(1, 3, 5), []);
    expect(salida.map(p => p.pedido_id)).toEqual(['opt1', 'opt2', 'opt3']);
  });

  it('ruta entera sin coordenadas: igual se ordena por barrida', () => {
    // Taco Pozo: ninguno de los 13 clientes de la ruta tiene lat/lng cargada.
    const salida = intercalarSinCoordenadas([], [
      { pedido_id: 'sinC', barrida: 5 },
      { pedido_id: 'sinA', barrida: 1 },
      { pedido_id: 'sinB', barrida: 3 },
    ]);
    expect(salida.map(p => p.pedido_id)).toEqual(['sinA', 'sinB', 'sinC']);
  });
});

describe('encajeEnHorario', () => {
  it('dentro de la franja está OK', () => {
    expect(encajeEnHorario('10:15', '09:00-14:00')).toBe('ok');
    expect(encajeEnHorario('09:00', '09:00-14:00')).toBe('ok');
    expect(encajeEnHorario('14:00', '09:00-14:00')).toBe('ok');
  });

  it('después de que cerró es tarde: la entrega se pierde', () => {
    expect(encajeEnHorario('15:40', '09:00-14:00')).toBe('tarde');
  });

  it('antes de que abra es temprano: se puede esperar, pero conviene avisar', () => {
    expect(encajeEnHorario('07:45', '08:30-14:30')).toBe('temprano');
  });

  it('el horario cortado vale por cualquiera de sus franjas', () => {
    expect(encajeEnHorario('12:00', '09:00-13:00 y 18:00-22:00')).toBe('ok');
    expect(encajeEnHorario('19:00', '09:00-13:00 y 18:00-22:00')).toBe('ok');
    // En el hueco del mediodía todavía puede esperar a la franja de la tarde.
    expect(encajeEnHorario('15:00', '09:00-13:00 y 18:00-22:00')).toBe('temprano');
    expect(encajeEnHorario('23:00', '09:00-13:00 y 18:00-22:00')).toBe('tarde');
  });

  it('acepta el minuto exacto del optimizador, no solo :00 y :30', () => {
    expect(encajeEnHorario('08:12', '08:00-14:00')).toBe('ok');
    expect(encajeEnHorario('14:07', '08:00-14:00')).toBe('tarde');
  });

  it('sin horario utilizable o sin estimación no opina', () => {
    expect(encajeEnHorario('10:00', null)).toBe('desconocido');
    expect(encajeEnHorario('10:00', 'de 9 a 14')).toBe('desconocido');
    expect(encajeEnHorario(null, '09:00-14:00')).toBe('desconocido');
    expect(encajeEnHorario('no-es-hora', '09:00-14:00')).toBe('desconocido');
  });
});

describe('finJornadaSugerida', () => {
  it('sugiere la jornada tipica desde la hora de salida', () => {
    expect(finJornadaSugerida('08:00')).toBe('18:00');
    expect(finJornadaSugerida('07:30')).toBe('17:30');
    expect(finJornadaSugerida('06:15')).toBe('16:15');
  });

  it('no se pasa de las 23:30 aunque salga tarde', () => {
    expect(finJornadaSugerida('15:00')).toBe('23:30');
    expect(finJornadaSugerida('22:00')).toBe('23:30');
  });

  it('hora vacia o mal formada cae en un default usable', () => {
    expect(finJornadaSugerida('')).toBe('18:00');
    expect(finJornadaSugerida('no-es-hora')).toBe('18:00');
  });
});

/**
 * Casos de una hoja de ruta real (Marcos, 26/09): Pablo y Los Redonditos están
 * a 57 m sobre J. M. Paz y salían en las paradas 2 y 6, porque uno cae en la
 * barrida 1 y el otro en la 5 y el orden entre bloques es duro.
 */
describe('absorberVecinos — el vecino de un bloque anterior se adelanta', () => {
  const PABLO = { id: '948', cliente: { latitud: '-26.8291368', longitud: '-65.2410498', h: '08:00-13:00' } };
  const REDONDITOS = { id: '36', cliente: { latitud: '-26.8289321', longitud: '-65.2405223', h: '08:30-24:00' } };
  const horario = (p: { cliente: { h: string } }) => p.cliente.h;

  it('Los Redonditos (corrido, barrida 5) va en la 1 con Pablo', () => {
    expect(clasificarBarrida(REDONDITOS.cliente.h).barrida).toBe(5);
    const ef = barridasEfectivas([PABLO, REDONDITOS], horario);
    expect(ef.get('948')).toBe(1);
    expect(ef.get('36')).toBe(1);
  });

  it('el que abre a la tarde NO se adelanta aunque esté pegado: no está abierto', () => {
    const TARDE = { id: '9', cliente: { ...REDONDITOS.cliente, h: '17:00-21:00' } };
    expect(barridasEfectivas([PABLO, TARDE], horario).get('9')).toBe(5);
  });

  it('a más de 100 m no es vecino', () => {
    // ~200 m al oeste sobre la misma calle.
    const LEJOS = { id: '9', cliente: { ...REDONDITOS.cliente, longitud: '-65.2430498' } };
    expect(barridasEfectivas([PABLO, LEJOS], horario).get('9')).toBe(5);
  });

  it('nunca atrasa: el de la barrida 1 sigue en la 1', () => {
    expect(barridasEfectivas([REDONDITOS, PABLO], horario).get('948')).toBe(1);
  });

  it('elige el bloque más temprano entre sus vecinos', () => {
    const TRES = { id: '3', cliente: { latitud: '-26.8290', longitud: '-65.2407', h: '09:00-14:00' } };
    const ef = barridasEfectivas([TRES, REDONDITOS, PABLO], horario);
    expect(clasificarBarrida(TRES.cliente.h).barrida).toBe(3);
    expect(ef.get('3')).toBe(1);
    expect(ef.get('36')).toBe(1);
  });

  it('no encadena: el vecino del adelantado no se arrastra al primer bloque', () => {
    // Redonditos está a 57 m de Pablo; ESTE está a ~80 m de Redonditos pero a
    // ~130 m de Pablo. Se ancla en barridas propias, así que queda en la 5.
    const ESTE = { id: '7', cliente: { latitud: '-26.8289321', longitud: '-65.2397223', h: '08:00-22:00' } };
    const ef = barridasEfectivas([PABLO, REDONDITOS, ESTE], horario);
    expect(ef.get('36')).toBe(1);
    expect(ef.get('7')).toBe(5);
  });

  it('sin horario (barrida 4) o sin coordenadas no se mueve', () => {
    const SIN_H = { id: '1', cliente: { ...REDONDITOS.cliente, h: '' } };
    const SIN_COORD = { id: '2', cliente: { latitud: null, longitud: null, h: '08:30-24:00' } };
    const ef = barridasEfectivas([PABLO, SIN_H, SIN_COORD], horario);
    expect(ef.get('1')).toBe(4);
    expect(ef.get('2')).toBe(5);
  });

  it('absorberVecinos devuelve una entrada por parada aunque no mueva nada', () => {
    const ef = absorberVecinos([{ pedido_id: 'x', barrida: 2, ventanas: [] }]);
    expect([...ef.entries()]).toEqual([['x', 2]]);
  });
});
