/**
 * Clasificación de paradas en "barridas" para el ruteo del día.
 *
 * Problema que resuelve: el 33% de las cancelaciones de los últimos 90 días
 * fueron por "CERRADO". La ruta se armaba buscando el recorrido más corto, sin
 * mirar a qué hora cierra cada local, así que el local que atiende hasta las 14
 * podía quedar en la parada 35 y se perdía la entrega.
 *
 * El reparto se ordena en bloques consecutivos y el orden ENTRE bloques es
 * duro: ninguna parada de un bloque se entrega antes que una del anterior.
 * Dentro de cada bloque se optimiza normalmente, respetando además la ventana
 * horaria real de cada cliente.
 *
 *   1 — abren temprano Y cierran al mediodía. Lo primero al salir del depósito.
 *   2 — cierran hasta las 13.
 *   3 — cierran hasta las 14:30.
 *   4 — sin horario cargado.
 *   5 — corrido / abren tarde. Toleran la visita al final del día.
 *
 * Nota sobre el criterio: agrupar por "cortado vs corrido" NO alcanza. El caso
 * más problemático de los datos reales es `09:00-14:00`: una sola franja, que
 * cierra al mediodía y no reabre. No es "cortado", pero es exactamente el que
 * hay que visitar temprano. Por eso el criterio son las HORAS, no la cantidad
 * de franjas.
 *
 * El grupo 1 salió de una observación de la operación: entre que sale el camión
 * y las 9 hay MUY pocos locales abiertos (6 de 43 en una ruta real). Esos son
 * los únicos visitables en esa franja, así que desaprovecharla cuesta caro.
 */

import type { FranjaHoraria } from './horariosCliente';
import { horaAMinutos, parsearFranjas } from './horariosCliente';

export type Barrida = 1 | 2 | 3 | 4 | 5;

/**
 * Apertura hasta la cual el local cuenta como "madrugador".
 *
 * Entre que sale el camión y esta hora hay pocos locales abiertos, así que los
 * que SÍ lo están son los únicos visitables en esa franja: hay que aprovecharla.
 */
export const UMBRAL_APERTURA_TEMPRANA = '09:00';

/** Primer corte de cierre: los que levantan más temprano. */
export const UMBRAL_CIERRE_MUY_TEMPRANO = '13:00';

/**
 * Cierre hasta el cual se considera que el local "cierra al mediodía".
 * Cubre los patrones dominantes en producción: 09:00-14:00, 08:30-14:00,
 * 07:30-14:30, 09:00-13:30.
 */
export const UMBRAL_CIERRE_TEMPRANO = '14:30';

/** Orden en que se recorren los bloques. Espeja ORDEN_BARRIDAS del optimizador. */
export const ORDEN_BARRIDAS: Barrida[] = [1, 2, 3, 4, 5];

export const ETIQUETA_BARRIDA: Record<Barrida, string> = {
  1: 'Abren temprano y cierran al mediodía',
  2: 'Cierran hasta las 13',
  3: 'Cierran hasta las 14:30',
  4: 'Sin horario cargado',
  5: 'Corrido o abren tarde',
};

export interface ClasificacionBarrida {
  barrida: Barrida;
  /** Franjas del cliente, para mandar como ventanas horarias al optimizador. */
  ventanas: FranjaHoraria[];
}

/**
 * Determina en qué barrida entra un cliente según su horario canónico.
 *
 * OJO con el grupo 1: exige las DOS condiciones. Un local que abre 07:00 pero
 * cierra 24:00 abre temprano, pero no urge —se lo puede visitar a cualquier
 * hora—, así que va al 5. Meterlo en el 1 gastaría la mañana, que es el recurso
 * escaso, en un cliente que no la necesita. En una ruta real eso pasaba de 6 a
 * 14 paradas en el primer bloque, y el camión llegaba a las 11 a los del mediodía.
 *
 * @param horario valor de `clientes.horarios_atencion` en formato "HH:MM-HH:MM y …".
 *                El texto libre no parseable cae en la barrida 4, igual que el vacío.
 */
export function clasificarBarrida(horario?: string | null): ClasificacionBarrida {
  const franjas = parsearFranjas(horario);

  // Sin horario utilizable: no se puede saber cuándo conviene ir.
  if (franjas.length === 0) {
    return { barrida: 4, ventanas: [] };
  }

  const apertura = horaAMinutos(franjas[0].apertura);
  const cierre = horaAMinutos(franjas[0].cierre);
  const cierraAlMediodia =
    Number.isFinite(cierre) && cierre <= horaAMinutos(UMBRAL_CIERRE_TEMPRANO);

  // 1. Madrugador Y de cierre temprano: lo único que se puede hacer al salir.
  if (
    cierraAlMediodia &&
    Number.isFinite(apertura) &&
    apertura < horaAMinutos(UMBRAL_APERTURA_TEMPRANA)
  ) {
    return { barrida: 1, ventanas: franjas };
  }

  // 2. Los que levantan más temprano.
  if (Number.isFinite(cierre) && cierre <= horaAMinutos(UMBRAL_CIERRE_MUY_TEMPRANO)) {
    return { barrida: 2, ventanas: franjas };
  }

  // 3. El resto de los que cierran al mediodía.
  if (cierraAlMediodia) {
    return { barrida: 3, ventanas: franjas };
  }

  // 5. Corrido, cierra tarde o abre tarde: tolera la visita al final del día.
  return { barrida: 5, ventanas: franjas };
}

/** Parada ya ruteada por el optimizador (trae la barrida que le tocó). */
export interface ParadaRuteada {
  pedido_id: string;
  barrida?: Barrida | null;
}

/** Parada que el optimizador no ordenó (cliente sin coordenadas). */
export interface ParadaSinCoordenadas {
  pedido_id: string;
  barrida: Barrida;
}

/** La parada de entrada, ya ubicada. Conserva lo demás que traiga (hora estimada, etc.). */
export type ParadaFinal<T> = T & { orden: number; barrida: Barrida | null };

/**
 * Intercala las paradas SIN COORDENADAS en el bloque horario que les toca.
 *
 * Los clientes sin latitud/longitud no entran al optimizador (Google necesita el
 * punto), así que antes se anexaban todos al final de la ruta. El resultado era
 * el peor posible: una despensa de 09:00-14:00 quedaba de última parada, después
 * de todos los kioscos que cierran a medianoche, y llegaba cerrada. Con ~1 de
 * cada 5 clientes sin geocodificar, no es un caso de borde.
 *
 * No se puede saber DÓNDE va la parada (no hay coordenadas), pero sí CUÁNDO: la
 * barrida se calcula del horario del cliente igual que para el resto. Así que se
 * la ubica al final de su propio bloque — el chofer la resuelve por dirección
 * dentro de la tanda correcta, en vez de a las 5 de la tarde.
 *
 * El orden que devolvió el optimizador se respeta tal cual: esto solo inserta.
 *
 * @param optimizadas orden devuelto por el optimizador, ya ordenado por barrida.
 * @param sinCoordenadas paradas a insertar, con su barrida ya clasificada.
 */
export function intercalarSinCoordenadas<R extends ParadaRuteada, S extends ParadaSinCoordenadas>(
  optimizadas: R[],
  sinCoordenadas: S[],
): Array<ParadaFinal<R | S>> {
  const numerar = (items: Array<R | S>): Array<ParadaFinal<R | S>> =>
    items.map((p, i) => ({ ...p, orden: i + 1, barrida: p.barrida ?? null }));

  // Entre sí siempre van ordenadas por bloque, aunque no haya dónde intercalarlas:
  // en Taco Pozo hay rutas enteras sin un solo cliente geocodificado.
  const porBloque = sinCoordenadas
    .map((p, i) => ({ p, i }))
    .sort((a, b) => a.p.barrida - b.p.barrida || a.i - b.i)
    .map(({ p }) => p);

  // Sin clasificación por barrida en las ruteadas no hay bloque donde insertar
  // (p.ej. el fallback sin ventanas horarias): quedan al final, como antes.
  if (porBloque.length === 0 || !optimizadas.some(o => o.barrida != null)) {
    return numerar([...optimizadas, ...porBloque]);
  }

  const pendientes = new Map<Barrida, S[]>();
  for (const p of porBloque) {
    const lista = pendientes.get(p.barrida);
    if (lista) lista.push(p);
    else pendientes.set(p.barrida, [p]);
  }

  const salida: Array<R | S> = [];
  /** Vuelca las pendientes de las barridas ya cerradas (las < `limite`). */
  const volcarAnteriores = (limite: Barrida | null): void => {
    for (const b of ORDEN_BARRIDAS) {
      if (limite != null && b >= limite) break;
      const lista = pendientes.get(b);
      if (lista) {
        salida.push(...lista);
        pendientes.delete(b);
      }
    }
  };

  let barridaActual: Barrida | null = null;
  for (const parada of optimizadas) {
    const b = parada.barrida ?? null;
    if (b != null && b !== barridaActual) {
      volcarAnteriores(b);
      barridaActual = b;
    }
    salida.push(parada);
  }
  // Lo que quede: la barrida en curso y las posteriores sin ninguna parada ruteada.
  volcarAnteriores(null);

  return numerar(salida);
}

/** Duración típica del reparto. Solo sugiere el default del modal: la hora de
 *  fin la elige el admin al armar la ruta, igual que la de salida. */
export const JORNADA_HORAS = 10;

/**
 * Fin de jornada sugerido a partir de la hora de salida (tope 23:30).
 *
 * Es un default, no una regla: un sábado no dura lo mismo que un martes, así
 * que el modal deja cambiarlo. Lo que el optimizador hace con ese horario es
 * descartar las franjas del cliente que arrancan después (la ventana de la
 * noche de un local cortado no es una entrega que se vaya a hacer).
 */
export function finJornadaSugerida(horaInicio: string): string {
  const m = /^(\d{1,2}):(\d{2})$/.exec(horaInicio);
  if (!m) return '18:00';
  const tope = 23 * 60 + 30;
  const fin = Math.min(Number(m[1]) * 60 + Number(m[2]) + JORNADA_HORAS * 60, tope);
  return `${String(Math.floor(fin / 60)).padStart(2, '0')}:${String(fin % 60).padStart(2, '0')}`;
}

/** Cómo cae la hora planificada contra el horario del cliente. */
export type EncajeHorario = 'ok' | 'temprano' | 'tarde' | 'desconocido';

/**
 * Contrasta la hora que planificó el optimizador contra el horario del cliente.
 *
 * Es el control que faltaba: hasta ahora la ruta se armaba y recién en la calle
 * se veía que una parada caía con el local cerrado. Con esto el aviso llega
 * cuando todavía se puede reordenar.
 *
 * @param horaEstimada "HH:MM" de llegada según el plan.
 * @param horario horario del cliente ("HH:MM-HH:MM y …"). Sin franjas → 'desconocido'.
 */
export function encajeEnHorario(
  horaEstimada: string | null | undefined,
  horario: string | null | undefined,
): EncajeHorario {
  const franjas = parsearFranjas(horario);
  if (!horaEstimada || franjas.length === 0) return 'desconocido';

  // `horaAMinutos` solo admite :00 y :30 (las franjas se cargan en esa grilla);
  // la hora estimada viene del optimizador con el minuto exacto.
  const m = /^(\d{1,2}):(\d{2})$/.exec(horaEstimada);
  if (!m) return 'desconocido';
  const llegada = Number(m[1]) * 60 + Number(m[2]);

  let antesDeAlguna = false;
  for (const f of franjas) {
    const apertura = horaAMinutos(f.apertura);
    const cierre = horaAMinutos(f.cierre);
    if (llegada >= apertura && llegada <= cierre) return 'ok';
    if (llegada < apertura) antesDeAlguna = true;
  }
  // Antes de alguna franja todavía se puede esperar; después de todas, ya cerró.
  return antesDeAlguna ? 'temprano' : 'tarde';
}

/**
 * ¿El cliente abre el día de la ruta?
 *
 * @param dias bitmask "0101010" de `clientes.dias_atencion`, orden Lunes→Domingo.
 *             `null`/vacío/mal formado = se asume que abre (comportamiento previo:
 *             ante la duda se visita, es preferible a saltearlo por un dato faltante).
 * @param fecha "YYYY-MM-DD" de la entrega.
 */
export function abreEnDia(dias: string | null | undefined, fecha: string): boolean {
  if (!dias || !/^[01]{7}$/.test(dias)) return true;

  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(fecha);
  if (!m) return true;

  // Fecha local (no UTC) para que no se corra un día por zona horaria.
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  if (Number.isNaN(d.getTime())) return true;

  // getDay(): 0=domingo..6=sábado. El bitmask es 0=lunes..6=domingo.
  const indice = (d.getDay() + 6) % 7;
  return dias[indice] === '1';
}
