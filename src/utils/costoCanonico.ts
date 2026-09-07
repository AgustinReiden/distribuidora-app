/**
 * Costo unitario CANÓNICO — la cascada del reporte gerencial, en JS.
 *
 * Espejo exacto del `COALESCE` que usan `reporte_gerencial` (mig 130) y
 * `reporte_valuacion_inventario` (mig 131):
 *
 *   COALESCE(snapshot, costo_promedio, costo_real,
 *            costo_sin_iva * (1 + impuestos_internos/100))
 *
 * Por qué ese orden:
 * - `snapshot` (`pedido_items.costo_unitario_al_crear`, `mermas_stock.costo_unitario`)
 *   es el costo congelado en el momento del hecho. Es lo único que hace que el
 *   margen de un mes cerrado no se mueva cuando cambia el costo de hoy.
 * - `costo_promedio` es el promedio ponderado (mig 127/128): base de VALUACIÓN
 *   y de CMV. Es lo que corresponde cuando no hay snapshot.
 * - `costo_real` es el costo de REPOSICIÓN (mig 111): base de pricing, no de
 *   CMV. Va después del promedio, no antes.
 * - La fórmula es el último recurso, con semántica FC (neto + impuestos
 *   internos). En ZZ lo pagado ya incluye IVA e impuestos internos y quedó
 *   guardado tal cual en `costo_real` (mig 111), así que un producto ZZ nunca
 *   llega hasta acá: sumarle los internos encima sería contarlos dos veces.
 *
 * `costo_con_iva` NO entra en la cascada: es el costo FINANCIERO (lo
 * desembolsado, IVA adentro) y el propio COMMENT de la columna dice "NO usar
 * para margen real". Usarlo de fallback infla el costo y hunde el margen.
 *
 * Si cambiás esta cascada, cambiá también las migraciones 130 y 131.
 */
import { redondear } from './calculations';

/** Las columnas de `productos` que participan de la cascada. */
export interface ProductoCosto {
  costo_promedio?: number | null;
  costo_real?: number | null;
  costo_sin_iva?: number | null;
  impuestos_internos?: number | null;
}

/**
 * Como en SQL, sólo NULL/ausente pasa al siguiente término: un costo de 0 es un
 * valor y corta la cascada, igual que `COALESCE`.
 */
function presente(valor: unknown): number | null {
  if (valor === null || valor === undefined || valor === '') return null;
  const n = Number(valor);
  return Number.isFinite(n) ? n : null;
}

/**
 * Costo unitario canónico del hecho.
 *
 * @param costoSnapshot - Costo congelado al registrar el hecho:
 *   `pedido_items.costo_unitario_al_crear` en una venta,
 *   `mermas_stock.costo_unitario` en una merma. `null` en filas viejas.
 * @param producto - Fila de `productos` (o el embed) con las columnas de costo.
 * @returns El costo unitario, o 0 si el producto no tiene ningún costo cargado
 *   (en SQL la cascada daría NULL y la fila no sumaría; acá 0 es lo mismo para
 *   un `SUM`, y evita propagar NaN a los totales).
 */
export function costoCanonicoUnitario(
  costoSnapshot: number | null | undefined,
  producto: ProductoCosto | null | undefined
): number {
  const snapshot = presente(costoSnapshot);
  if (snapshot !== null) return snapshot;

  const promedio = presente(producto?.costo_promedio);
  if (promedio !== null) return promedio;

  const real = presente(producto?.costo_real);
  if (real !== null) return real;

  const sinIva = presente(producto?.costo_sin_iva);
  if (sinIva === null) return 0;
  // 4 decimales como calcularCostoReal y como costo_real_unitario (mig 111):
  // en SQL la fórmula es aritmética `numeric` exacta, en JS 100*(1+10/100) da
  // 110.00000000000001 y ese ruido se propaga a los totales.
  return redondear(sinIva * (1 + (presente(producto?.impuestos_internos) ?? 0) / 100), 4);
}
