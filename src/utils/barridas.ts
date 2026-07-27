/**
 * Clasificación de paradas en "barridas" para el ruteo del día.
 *
 * Problema que resuelve: el 33% de las cancelaciones de los últimos 90 días
 * fueron por "CERRADO". La ruta se armaba buscando el recorrido más corto, sin
 * mirar a qué hora cierra cada local, así que el local que atiende hasta las 14
 * podía quedar en la parada 35 y se perdía la entrega.
 *
 * El reparto se ordena en tres bloques consecutivos y el orden ENTRE bloques es
 * duro: ninguna parada de la barrida 2 se entrega antes que una de la 1.
 * Dentro de cada bloque se optimiza normalmente, respetando además la ventana
 * horaria real de cada cliente.
 *
 *   Barrida 1 — cierran temprano (al mediodía). Son los que más rechazan.
 *   Barrida 2 — sin horario cargado. Se hacen mientras la mayoría está abierta.
 *   Barrida 3 — corrido / abren tarde / cierran tarde. Toleran la visita final.
 *
 * Nota sobre el criterio: agrupar por "cortado vs corrido" NO alcanza. El caso
 * más problemático de los datos reales es `09:00-14:00`: una sola franja, que
 * cierra al mediodía y no reabre. No es "cortado", pero es exactamente el que
 * hay que visitar primero. Por eso el criterio es la HORA DE CIERRE, no la
 * cantidad de franjas.
 */

import type { FranjaHoraria } from './horariosCliente';
import { horaAMinutos, parsearFranjas } from './horariosCliente';

export type Barrida = 1 | 2 | 3;

/**
 * Cierre hasta el cual se considera que el local "cierra al mediodía".
 * Cubre los patrones dominantes en producción: 09:00-14:00, 08:30-14:00,
 * 07:30-14:30, 09:00-13:30.
 */
export const UMBRAL_CIERRE_TEMPRANO = '14:30';

/** Apertura desde la cual se considera que el local "abre tarde". */
export const UMBRAL_APERTURA_TARDIA = '11:00';

export const ETIQUETA_BARRIDA: Record<Barrida, string> = {
  1: 'Cierran al mediodía',
  2: 'Sin horario cargado',
  3: 'Corrido o abren tarde',
};

export interface ClasificacionBarrida {
  barrida: Barrida;
  /** Franjas del cliente, para mandar como ventanas horarias al optimizador. */
  ventanas: FranjaHoraria[];
}

/**
 * Determina en qué barrida entra un cliente según su horario canónico.
 *
 * @param horario valor de `clientes.horarios_atencion` en formato "HH:MM-HH:MM y …".
 *                El texto libre no parseable cae en la barrida 2, igual que el vacío.
 */
export function clasificarBarrida(horario?: string | null): ClasificacionBarrida {
  const franjas = parsearFranjas(horario);

  // Sin horario utilizable: no se puede saber cuándo conviene ir.
  if (franjas.length === 0) {
    return { barrida: 2, ventanas: [] };
  }

  const cierre = horaAMinutos(franjas[0].cierre);

  // Cierra al mediodía → primero, sí o sí.
  if (Number.isFinite(cierre) && cierre <= horaAMinutos(UMBRAL_CIERRE_TEMPRANO)) {
    return { barrida: 1, ventanas: franjas };
  }

  // El resto tolera la visita tardía: atiende de corrido, cierra tarde o abre
  // tarde (apertura >= UMBRAL_APERTURA_TARDIA). Los tres casos van al final y
  // se ordenan entre sí por su ventana horaria dentro de la barrida.
  return { barrida: 3, ventanas: franjas };
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
