/**
 * Tests del cache local de la ruta del chofer.
 *
 * Lo que protegen es una sola regla: mostrar una ruta vieja como si fuera la de
 * hoy es PEOR que no mostrar nada. El chofer sale a repartir con ella.
 */
import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { guardarRuta, leerRuta, olvidarRuta } from './rutaOfflineCache';

const HOY = '2026-08-19';
const AYER = '2026-08-18';
const ruta = { id: '10', paradas: [{ id: '1' }], polylines: null };

describe('rutaOfflineCache', () => {
  beforeEach(() => {
    localStorage.clear();
    vi.useRealTimers();
  });
  afterEach(() => vi.useRealTimers());

  it('guarda y devuelve la ruta del día', () => {
    guardarRuta(1, 'chofer-a', HOY, ruta);
    const leido = leerRuta<typeof ruta>(1, 'chofer-a', HOY);
    expect(leido?.datos).toEqual(ruta);
    expect(typeof leido?.guardadoEn).toBe('number');
  });

  it('NO devuelve la ruta de otro día', () => {
    guardarRuta(1, 'chofer-a', AYER, ruta);
    expect(leerRuta(1, 'chofer-a', HOY)).toBeNull();
  });

  // Multi-tenant: un chofer que opera en dos sucursales no puede ver la ruta de
  // la otra por compartir clave.
  it('no cruza sucursales ni choferes', () => {
    guardarRuta(1, 'chofer-a', HOY, ruta);
    expect(leerRuta(2, 'chofer-a', HOY)).toBeNull();
    expect(leerRuta(1, 'chofer-b', HOY)).toBeNull();
  });

  it('descarta lo guardado hace más de 36 h', () => {
    guardarRuta(1, 'chofer-a', HOY, ruta);
    vi.useFakeTimers();
    vi.setSystemTime(new Date(Date.now() + 37 * 60 * 60 * 1000));
    expect(leerRuta(1, 'chofer-a', HOY)).toBeNull();
  });

  // Un JSON corrupto (quota a mitad de escritura, storage manoseado) no puede
  // tirar abajo la pantalla del chofer.
  it('sobrevive a un cache corrupto', () => {
    localStorage.setItem('ruta-activa:v1:1:chofer-a', '{esto no es json');
    expect(() => leerRuta(1, 'chofer-a', HOY)).not.toThrow();
    expect(leerRuta(1, 'chofer-a', HOY)).toBeNull();
  });

  it('descarta un payload con la forma cambiada', () => {
    localStorage.setItem('ruta-activa:v1:1:chofer-a', JSON.stringify({ otraCosa: true }));
    expect(leerRuta(1, 'chofer-a', HOY)).toBeNull();
  });

  it('olvidarRuta borra solo la del chofer indicado', () => {
    guardarRuta(1, 'chofer-a', HOY, ruta);
    guardarRuta(1, 'chofer-b', HOY, ruta);
    olvidarRuta(1, 'chofer-a');
    expect(leerRuta(1, 'chofer-a', HOY)).toBeNull();
    expect(leerRuta(1, 'chofer-b', HOY)).not.toBeNull();
  });

  // Si localStorage esta lleno, guardar no puede romper a quien YA tiene los
  // datos frescos en la mano.
  it('no lanza si localStorage rechaza la escritura', () => {
    const spy = vi.spyOn(globalThis.localStorage, 'setItem').mockImplementation(() => {
      throw new DOMException('QuotaExceededError');
    });
    expect(() => guardarRuta(1, 'chofer-a', HOY, ruta)).not.toThrow();
    spy.mockRestore();
  });

  it('sin transportista no escribe nada', () => {
    guardarRuta(1, '', HOY, ruta);
    expect(localStorage.length).toBe(0);
  });
});
