import { describe, it, expect } from 'vitest';
import {
  generarOpcionesHora,
  horaAMinutos,
  parsearFranjas,
  serializarFranjas,
  validarFranjas,
  convertirHorarioInicial,
} from './horariosCliente';

describe('generarOpcionesHora', () => {
  it('genera 48 opciones de 00:00 a 23:30 en pasos de 30 min', () => {
    const ops = generarOpcionesHora();
    expect(ops).toHaveLength(48);
    expect(ops[0]).toBe('00:00');
    expect(ops[1]).toBe('00:30');
    expect(ops[ops.length - 1]).toBe('23:30');
  });

  it('agrega "24:00" al final cuando se pide la medianoche', () => {
    const ops = generarOpcionesHora(true);
    expect(ops).toHaveLength(49);
    expect(ops[ops.length - 1]).toBe('24:00');
  });
});

describe('horaAMinutos', () => {
  it('convierte horas válidas a minutos', () => {
    expect(horaAMinutos('00:00')).toBe(0);
    expect(horaAMinutos('08:30')).toBe(510);
    expect(horaAMinutos('23:30')).toBe(1410);
  });

  it('trata "24:00" como medianoche (1440)', () => {
    expect(horaAMinutos('24:00')).toBe(1440);
  });

  it('devuelve NaN para formatos inválidos', () => {
    expect(horaAMinutos('24:30')).toBeNaN();
    expect(horaAMinutos('25:00')).toBeNaN();
    expect(horaAMinutos('08:15')).toBeNaN();
    expect(horaAMinutos('8:00')).toBeNaN();
    expect(horaAMinutos('')).toBeNaN();
  });
});

describe('parsearFranjas / serializarFranjas', () => {
  it('hace ida y vuelta de un horario cortado', () => {
    const valor = '08:00-12:00 y 16:00-20:00';
    const franjas = parsearFranjas(valor);
    expect(franjas).toEqual([
      { apertura: '08:00', cierre: '12:00' },
      { apertura: '16:00', cierre: '20:00' },
    ]);
    expect(serializarFranjas(franjas)).toBe(valor);
  });

  it('parsea una franja con cierre a medianoche', () => {
    expect(parsearFranjas('20:00-24:00')).toEqual([{ apertura: '20:00', cierre: '24:00' }]);
  });

  it('devuelve [] para etiquetas viejas, null y vacío', () => {
    expect(parsearFranjas('Mañana (08 a 13)')).toEqual([]);
    expect(parsearFranjas(null)).toEqual([]);
    expect(parsearFranjas(undefined)).toEqual([]);
    expect(parsearFranjas('')).toEqual([]);
  });

  it('descarta filas incompletas al serializar', () => {
    expect(
      serializarFranjas([
        { apertura: '08:00', cierre: '12:00' },
        { apertura: '16:00', cierre: '' },
        { apertura: '', cierre: '20:00' },
      ]),
    ).toBe('08:00-12:00');
  });
});

describe('validarFranjas', () => {
  it('acepta una franja simple válida', () => {
    expect(validarFranjas([{ apertura: '08:00', cierre: '20:00' }]).valido).toBe(true);
  });

  it('acepta un horario cortado sin solape', () => {
    const r = validarFranjas([
      { apertura: '08:00', cierre: '12:00' },
      { apertura: '16:00', cierre: '20:00' },
    ]);
    expect(r.valido).toBe(true);
  });

  it('acepta franjas adyacentes (el borde no es solape)', () => {
    const r = validarFranjas([
      { apertura: '08:00', cierre: '12:00' },
      { apertura: '12:00', cierre: '16:00' },
    ]);
    expect(r.valido).toBe(true);
    expect(r.errorSolapamiento).toBeNull();
  });

  it('acepta la franja nocturna 20:00-24:00', () => {
    expect(validarFranjas([{ apertura: '20:00', cierre: '24:00' }]).valido).toBe(true);
  });

  it('rechaza franjas que se solapan', () => {
    const r = validarFranjas([
      { apertura: '08:00', cierre: '12:00' },
      { apertura: '11:00', cierre: '14:00' },
    ]);
    expect(r.valido).toBe(false);
    expect(r.errorSolapamiento).not.toBeNull();
  });

  it('detecta el solape sin importar el orden de las filas', () => {
    const r = validarFranjas([
      { apertura: '16:00', cierre: '20:00' },
      { apertura: '08:00', cierre: '18:00' },
    ]);
    expect(r.valido).toBe(false);
    expect(r.errorSolapamiento).not.toBeNull();
  });

  it('rechaza apertura >= cierre y lo marca en la fila', () => {
    const r = validarFranjas([{ apertura: '14:00', cierre: '10:00' }]);
    expect(r.valido).toBe(false);
    expect(r.erroresPorFila[0]).toBeTruthy();
  });

  it('ignora filas incompletas', () => {
    const r = validarFranjas([
      { apertura: '08:00', cierre: '12:00' },
      { apertura: '16:00', cierre: '' },
    ]);
    expect(r.valido).toBe(true);
  });
});

describe('convertirHorarioInicial', () => {
  it('convierte una etiqueta vieja simple a rango', () => {
    const r = convertirHorarioInicial('Mañana (08 a 13)');
    expect(r.franjas).toEqual([{ apertura: '08:00', cierre: '13:00' }]);
    expect(r.huboLegacy).toBe(true);
    expect(r.sinReconocer).toEqual([]);
  });

  it('convierte un horario cortado legacy a dos franjas', () => {
    const r = convertirHorarioInicial('Mañana (08 a 13) y Tarde (16 a 20)');
    expect(r.franjas).toEqual([
      { apertura: '08:00', cierre: '13:00' },
      { apertura: '16:00', cierre: '20:00' },
    ]);
    expect(r.huboLegacy).toBe(true);
  });

  it('mapea "Noche (20 a 00)" a cierre 24:00', () => {
    const r = convertirHorarioInicial('Noche (20 a 00)');
    expect(r.franjas).toEqual([{ apertura: '20:00', cierre: '24:00' }]);
  });

  it('reconoce el formato nuevo sin marcar legacy', () => {
    const r = convertirHorarioInicial('08:00-12:00 y 16:00-20:00');
    expect(r.franjas).toEqual([
      { apertura: '08:00', cierre: '12:00' },
      { apertura: '16:00', cierre: '20:00' },
    ]);
    expect(r.huboLegacy).toBe(false);
    expect(r.sinReconocer).toEqual([]);
  });

  it('reporta el texto libre desconocido en sinReconocer', () => {
    const r = convertirHorarioInicial('Lun a Vie cualquier hora');
    expect(r.franjas).toEqual([]);
    expect(r.sinReconocer).toEqual(['Lun a Vie cualquier hora']);
  });

  it('devuelve vacío para null/undefined/""', () => {
    expect(convertirHorarioInicial(null)).toEqual({ franjas: [], huboLegacy: false, sinReconocer: [] });
    expect(convertirHorarioInicial(undefined)).toEqual({ franjas: [], huboLegacy: false, sinReconocer: [] });
    expect(convertirHorarioInicial('')).toEqual({ franjas: [], huboLegacy: false, sinReconocer: [] });
  });
});
