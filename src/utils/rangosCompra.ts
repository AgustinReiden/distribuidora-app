/**
 * Los rangos del alta de una compra (#1471, STK-F-4).
 *
 * Espejo de lo que rechaza `registrar_compra_completa` desde la migración de la
 * tarjeta 4 de #1477: la base valida igual aunque el cliente esté viejo; esto es
 * para decirlo al lado de lo que lo causó, antes de salir a la red. La edición
 * tiene su propio validador (`validarEdicionCompra`), con los mismos rangos de
 * línea y sin la fecha, que no se edita.
 */
import { redondearSQL } from './calculations';

export interface LineaRangosCompra {
  cantidad: number;
  costoUnitario: number;
  bonificacion?: number | null;
}

/** El motivo por el que una línea está fuera de rango, o `null` si está bien. */
export function motivoLineaFueraDeRango(linea: LineaRangosCompra): string | null {
  if (!Number.isFinite(linea.cantidad)) return 'la cantidad no es un número';
  if (!Number.isInteger(linea.cantidad)) return 'la cantidad tiene que ser entera';
  if (linea.cantidad <= 0) return 'la cantidad tiene que ser mayor a 0';
  if (!Number.isFinite(linea.costoUnitario)) return 'el costo no es un número';
  if (linea.costoUnitario < 0) return 'el costo no puede ser negativo';
  const bonificacion = linea.bonificacion ?? 0;
  if (!Number.isFinite(bonificacion)) return 'la bonificación no es un número';
  if (bonificacion < 0 || bonificacion > 100) return 'la bonificación es un porcentaje, de 0 a 100';
  return motivoCostoCero(linea.costoUnitario, bonificacion);
}

/**
 * CMP-5 (#1557): el regalo legal es la bonificación del 100 %. Un costo 0 (o
 * que al centavo da 0) sin ella es casi siempre un olvido —el modal precarga 0
 * si el producto no tiene costo— y bajaba el promedio sin aviso. Espejo de
 * `_compra_renglones_fuera_de_rango`, que lo rechaza igual.
 */
export function motivoCostoCero(costoUnitario: number, bonificacion?: number | null): string | null {
  if (redondearSQL(costoUnitario || 0, 2) === 0 && (bonificacion ?? 0) < 100) {
    return 'el costo es 0: si viene sin cargo, cargalo con bonificación del 100 %';
  }
  return null;
}

/** `YYYY-MM-DD` → `DD/MM/YYYY`. */
const aTexto = (ymd: string): string => ymd.split('-').reverse().join('/');

/**
 * El mismo día un año antes, como `fecha - INTERVAL '1 year'` de Postgres: el
 * 29 de febrero cae en el 28.
 */
export function unAnioAntes(hoy: string): string {
  const [y, m, d] = hoy.split('-').map(Number);
  const ultimoDelMes = new Date(Date.UTC(y - 1, m, 0)).getUTCDate();
  const dia = Math.min(d, ultimoDelMes);
  return `${String(y - 1).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(dia).padStart(2, '0')}`;
}

/**
 * La fecha de la compra va entre un año atrás y hoy, en el día argentino
 * (decisión del dueño, 05/11). Una fecha con el año mal tipeado quedaba como la
 * compra más nueva del producto y las compras reales de después ya no le movían
 * el costo de reposición.
 *
 * @param fecha - `YYYY-MM-DD`, como la da el input de fecha.
 * @param hoy - el día argentino, `fechaLocalISO()`.
 */
export function validarFechaCompra(fecha: string, hoy: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) return 'La fecha de la compra no es válida.';
  if (fecha > hoy) return `La fecha de la compra (${aTexto(fecha)}) es posterior a hoy. Revisá el año.`;
  if (fecha < unAnioAntes(hoy)) return `La fecha de la compra (${aTexto(fecha)}) tiene más de un año. Revisá el año.`;
  return null;
}
