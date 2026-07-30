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
