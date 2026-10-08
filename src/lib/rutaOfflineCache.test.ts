/**
 * Tests del cache local de la ruta del chofer.
 *
 * Lo que protegen es una sola regla: mostrar una ruta vieja como si fuera la de
 * hoy es PEOR que no mostrar nada. El chofer sale a repartir con ella.
 */
import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { guardarRuta, leerRuta, olvidarRuta, olvidarTodasLasRutas, migrarRutasDeEsquemaViejo } from './rutaOfflineCache';

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

  // El bug real: se guarda con `fecha: ayer` (la ruta que cruzó la medianoche)
  // y se leía siempre con `hoy` a secas. `fechaDeRuta()` en la madrugada acepta
  // las dos, así que `leerRuta` tiene que poder recibirlas juntas.
  it('con una lista de fechas aceptadas, devuelve la ruta guardada con cualquiera de ellas', () => {
    guardarRuta(1, 'chofer-a', AYER, ruta);
    expect(leerRuta(1, 'chofer-a', [HOY, AYER])?.datos).toEqual(ruta);
  });

  it('con una lista de fechas aceptadas, sigue rechazando una fecha que no está en la lista', () => {
    guardarRuta(1, 'chofer-a', '2026-08-17', ruta);
    expect(leerRuta(1, 'chofer-a', [HOY, AYER])).toBeNull();
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
    localStorage.setItem('ruta-activa:v2:1:chofer-a', '{esto no es json');
    expect(() => leerRuta(1, 'chofer-a', HOY)).not.toThrow();
    expect(leerRuta(1, 'chofer-a', HOY)).toBeNull();
  });

  it('descarta un payload con la forma cambiada', () => {
    localStorage.setItem('ruta-activa:v2:1:chofer-a', JSON.stringify({ otraCosa: true }));
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

  // Logout en un dispositivo compartido: puede quedar la ruta de un chofer
  // anterior que ya cerró sesión sin pasar por acá.
  it('olvidarTodasLasRutas borra las de cualquier sucursal o chofer', () => {
    guardarRuta(1, 'chofer-a', HOY, ruta);
    guardarRuta(2, 'chofer-b', HOY, ruta);
    localStorage.setItem('otra-cosa', 'no tocar');

    olvidarTodasLasRutas();

    expect(leerRuta(1, 'chofer-a', HOY)).toBeNull();
    expect(leerRuta(2, 'chofer-b', HOY)).toBeNull();
    expect(localStorage.getItem('otra-cosa')).toBe('no tocar');
  });

  // #1003: la v1 guardaba el costo de cada ítem. Subir el esquema solo no
  // alcanza: el service worker es 'prompt' y el bundle viejo sigue escribiendo
  // v1 hasta que se activa el nuevo, así que descartar la v1 dejaría sin ruta
  // offline a un chofer que reabre la PWA sin señal. Se MIGRA a v2, sin costo.
  describe('migrarRutasDeEsquemaViejo', () => {
    // Reciente (hace 1 h) para que `leerRuta` no la descarte por vieja.
    const GUARDADO_EN = Date.now() - 60 * 60 * 1000;
    const rutaConCosto = {
      id: '10',
      polylines: null,
      paradas: [
        { id: '1', items: [{ id: 'a', cantidad: 2, costo_unitario_al_crear: 60 }, { id: 'b', cantidad: 1, costo_unitario_al_crear: null }] },
        { id: '2', items: [{ id: 'c', cantidad: 5, costo_unitario_al_crear: 7.5 }] },
      ],
    };
    const v1 = (datos: unknown, fecha = HOY) => JSON.stringify({ datos, guardadoEn: GUARDADO_EN, fecha });

    it('migra la v1 a v2 sin costo en los ítems, con el mismo guardadoEn y fecha, y borra la v1', () => {
      localStorage.setItem('ruta-activa:v1:1:chofer-a', v1(rutaConCosto));

      migrarRutasDeEsquemaViejo();

      expect(localStorage.getItem('ruta-activa:v1:1:chofer-a')).toBeNull();
      const leido = leerRuta<typeof rutaConCosto>(1, 'chofer-a', HOY);
      expect(leido?.guardadoEn).toBe(GUARDADO_EN);
      expect(leido?.fecha).toBe(HOY);
      expect(leido?.datos.id).toBe('10');
      const items = leido!.datos.paradas.flatMap(p => p.items);
      expect(items.map(i => i.id)).toEqual(['a', 'b', 'c']);
      expect(items.map(i => i.cantidad)).toEqual([2, 1, 5]);
      for (const item of items) expect(item).not.toHaveProperty('costo_unitario_al_crear');
      expect(localStorage.getItem('ruta-activa:v2:1:chofer-a')).not.toContain('costo_unitario_al_crear');
    });

    it('es defensiva con una v1 de forma rara: migra lo que es payload válido sin tirar', () => {
      localStorage.setItem('ruta-activa:v1:1:chofer-a', v1({ id: '10', paradas: [null, { items: 'no-es-array' }, { items: [null, 3, { id: 'x', costo_unitario_al_crear: 1 }] }] }));
      localStorage.setItem('ruta-activa:v1:1:chofer-b', v1({ id: '11' }));

      expect(() => migrarRutasDeEsquemaViejo()).not.toThrow();

      const a = leerRuta<{ paradas: Array<{ items?: unknown } | null> }>(1, 'chofer-a', HOY);
      expect(a?.datos.paradas[2]?.items).toEqual([null, 3, { id: 'x' }]);
      expect(leerRuta(1, 'chofer-b', HOY)?.datos).toEqual({ id: '11' });
    });

    it('una v1 corrupta se borra, no lanza y no crea v2', () => {
      localStorage.setItem('ruta-activa:v1:1:chofer-a', '{esto no es json');
      localStorage.setItem('ruta-activa:v1:1:chofer-b', JSON.stringify({ otraCosa: true }));

      expect(() => migrarRutasDeEsquemaViejo()).not.toThrow();

      expect(localStorage.getItem('ruta-activa:v1:1:chofer-a')).toBeNull();
      expect(localStorage.getItem('ruta-activa:v1:1:chofer-b')).toBeNull();
      expect(localStorage.getItem('ruta-activa:v2:1:chofer-a')).toBeNull();
      expect(localStorage.getItem('ruta-activa:v2:1:chofer-b')).toBeNull();
    });

    it('si ya hay una v2 en esa clave, la v2 manda y no se pisa', () => {
      guardarRuta(1, 'chofer-a', HOY, ruta);
      const v2Antes = localStorage.getItem('ruta-activa:v2:1:chofer-a');
      localStorage.setItem('ruta-activa:v1:1:chofer-a', v1(rutaConCosto));

      migrarRutasDeEsquemaViejo();

      expect(localStorage.getItem('ruta-activa:v2:1:chofer-a')).toBe(v2Antes);
      expect(localStorage.getItem('ruta-activa:v1:1:chofer-a')).toBeNull();
    });

    it('borra cualquier otra versión ajena (ni v1 ni la actual) sin migrarla', () => {
      localStorage.setItem('ruta-activa:v0:1:chofer-a', v1(rutaConCosto));
      localStorage.setItem('ruta-activa:v3:1:chofer-a', v1(rutaConCosto));

      migrarRutasDeEsquemaViejo();

      expect(localStorage.getItem('ruta-activa:v0:1:chofer-a')).toBeNull();
      expect(localStorage.getItem('ruta-activa:v3:1:chofer-a')).toBeNull();
      expect(localStorage.getItem('ruta-activa:v2:1:chofer-a')).toBeNull();
    });

    it('conserva las v2 que ya estaban y no toca claves ajenas', () => {
      guardarRuta(1, 'chofer-c', HOY, ruta);
      localStorage.setItem('otra-cosa', 'no tocar');
      localStorage.setItem('ruta-activa-parecida', 'no tocar');

      migrarRutasDeEsquemaViejo();

      expect(leerRuta(1, 'chofer-c', HOY)?.datos).toEqual(ruta);
      expect(localStorage.getItem('otra-cosa')).toBe('no tocar');
      expect(localStorage.getItem('ruta-activa-parecida')).toBe('no tocar');
    });

    it('no lanza si localStorage tira', () => {
      localStorage.setItem('ruta-activa:v1:1:chofer-a', v1(rutaConCosto));
      const spy = vi.spyOn(Storage.prototype, 'key').mockImplementation(() => {
        throw new DOMException('SecurityError');
      });
      expect(() => migrarRutasDeEsquemaViejo()).not.toThrow();
      spy.mockRestore();
    });

    it('no lanza si localStorage rechaza escribir la v2', () => {
      localStorage.setItem('ruta-activa:v1:1:chofer-a', v1(rutaConCosto));
      const spy = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
        throw new DOMException('QuotaExceededError');
      });
      expect(() => migrarRutasDeEsquemaViejo()).not.toThrow();
      spy.mockRestore();
      expect(localStorage.getItem('ruta-activa:v1:1:chofer-a')).toBeNull();
    });
  });
});
