/**
 * Piezas puras y compartidas del encabezado de vista.
 *
 * `DIAS_SEMANA`, `MESES` y `formatDiaLargo` estaban copiados textualmente en
 * los cuatro headers de vista (Pedidos, Clientes, Productos, Dashboard). Acá
 * viven una sola vez, con el MISMO comportamiento: todo en mayúsculas, día sin
 * relleno de ceros y el conector " DE " entre número y mes.
 *
 * Es lógica pura y va en `src/utils/` justamente para poder testearla con una
 * fecha fija, sin montar nada.
 */

/** Índice = `Date#getDay()` (0 = domingo). */
export const DIAS_SEMANA = [
  'DOMINGO', 'LUNES', 'MARTES', 'MIÉRCOLES', 'JUEVES', 'VIERNES', 'SÁBADO',
] as const;

/** Índice = `Date#getMonth()` (0 = enero). */
export const MESES = [
  'ENERO', 'FEBRERO', 'MARZO', 'ABRIL', 'MAYO', 'JUNIO',
  'JULIO', 'AGOSTO', 'SEPTIEMBRE', 'OCTUBRE', 'NOVIEMBRE', 'DICIEMBRE',
] as const;

/**
 * Fecha larga del crumb: `MARTES 21 DE ABRIL`.
 *
 * Lee la fecha en hora LOCAL (getDay/getDate/getMonth), que es lo que ya hacían
 * los headers: el crumb habla del día de la usuaria, no del día UTC.
 */
export function formatDiaLargo(fecha: Date): string {
  return `${DIAS_SEMANA[fecha.getDay()]} ${fecha.getDate()} DE ${MESES[fecha.getMonth()]}`;
}
