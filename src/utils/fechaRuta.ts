/**
 * Qué día de recorrido le corresponde ver al chofer.
 *
 * Vive acá y no dentro de `useRecorridoActivoQuery` a propósito: es una función
 * pura de fechas, y tenerla en el módulo de la query obligaba a construir el
 * cliente de Supabase sólo para importarla. En CI —donde no hay `.env`— eso
 * explota al importar, y el test ni siquiera llega a correr.
 */
import { fechaLocalISO } from './formatters';

/** Hasta esta hora local, una ruta de ayer todavía puede estar en curso. */
export const HORA_CORTE_RUTA_DE_AYER = 6;

/**
 * Devuelve la fecha de hoy y, sólo en la madrugada, la de ayer.
 *
 * La query filtraba `fecha = hoy` a secas y dejaba sin ruta a quien cruza la
 * medianoche terminando el reparto: a las 00:05 la ruta que está haciendo pasa
 * a ser "de ayer" y la pantalla le decía que el administrador todavía no armó
 * la suya, con el camión cargado.
 *
 * Pero aceptar la de ayer SIEMPRE es peor que el bug original. En producción hay
 * decenas de recorridos que quedaron `en_curso` de días pasados porque nada los
 * cierra, así que un chofer sin ruta hoy vería la de ayer —con paradas ya
 * entregadas— a las diez de la mañana. De ahí la ventana: sólo en la madrugada,
 * que es cuando "ayer" de verdad significa "el turno que todavía no terminé".
 * Pasada esa hora, no tener ruta es la respuesta correcta.
 *
 * La causa de fondo (recorridos que nunca se cierran) se ataca aparte.
 */
export function fechaDeRuta(
  hoy = fechaLocalISO(),
  horaLocal = new Date().getHours(),
): { hoy: string; ayer: string | null } {
  if (horaLocal >= HORA_CORTE_RUTA_DE_AYER) return { hoy, ayer: null };
  // Mediodía como ancla: evita que el `new Date` se corra un día al normalizar
  // a la zona local (Argentina es UTC-3).
  const d = new Date(`${hoy}T12:00:00`);
  d.setDate(d.getDate() - 1);
  return { hoy, ayer: fechaLocalISO(d) };
}
