/**
 * Unidades de las líneas de un pedido.
 *
 * `pedido_items.cantidad` NO está siempre en la misma unidad:
 *  - línea de venta            → unidades de venta (para estos productos, fardos)
 *  - regalo de promo Fracción  → subunidades sueltas (botellas)
 *
 * Una promo "6 + 2" sobre 196 fardos deja una línea de regalo con cantidad
 * 392: son 392 BOTELLAS (65 fardos), no 392 fardos. Leído sin contexto parece
 * un regalo 6 veces más grande de lo que es, y fue exactamente lo que hizo
 * dudar del stock de Lima Limón.
 *
 * El stock lo descuenta bien el auto-ajuste por bloques (mig 132); acá sólo se
 * resuelve cómo MOSTRAR la cantidad para que no se lea en la unidad equivocada.
 */

/** Lo mínimo que hace falta de un ítem para saber en qué unidad está. */
export interface ItemConUnidad {
  cantidad: number;
  es_bonificacion?: boolean | null;
  /** Factor congelado al crear la línea (mig 212). Manda sobre el vivo. */
  unidades_por_bloque_al_crear?: number | null;
  promocion?: {
    unidades_por_bloque?: number | null;
    regalo_mueve_stock?: boolean | null;
  } | null;
}

/**
 * Factor de fracción de esta línea. Es el puerto TS de
 * `public.factor_bonificacion(al_crear, regalo_mueve_stock, unidades_por_bloque)`
 * (mig 212 §6), con la misma cascada: congelado → vivo → 1.
 *
 * El congelado tiene que ganar. Sin él, editar el factor de una promo cambiaba
 * cómo se lee la cantidad de un regalo en pedidos YA CERRADOS: una promo que
 * pasa de 6 a 12 mostraba un regalo histórico de 392 botellas como ≈32,7 fardos
 * en vez de ≈65,3. Es el mismo bug que la 212 arregló para el reporte, y que
 * seguía abierto para la pantalla y la boleta (issues #534 y #552).
 *
 * El fallback al vivo NO es sólo el divisor: replica también el gate
 * `regalo_mueve_stock IS FALSE`. Sin ese gate, un flip de false → true en una
 * promo que todavía tenga `unidades_por_bloque` cargado multiplicaría por 6 o
 * por 12 la lectura de sus regalos viejos — el caso peor que documenta la 212.
 * Aplica a los 70 ítems anteriores a la primera medición de su promo, que
 * quedaron con el congelado en NULL a propósito.
 */
function factorDeLaLinea(item: ItemConUnidad): number {
  // `|| null` reproduce el NULLIF(unidades_por_bloque, 0) del SQL: un 0 cae al
  // neutro en vez de propagarse como divisor.
  const vivo = item.promocion?.regalo_mueve_stock === false
    ? (item.promocion?.unidades_por_bloque || null)
    : null;
  return Math.max(item.unidades_por_bloque_al_crear ?? vivo ?? 1, 1);
}

/**
 * true si la cantidad de este ítem está en subunidades sueltas (botellas) en
 * vez de en unidades de venta (fardos): pasa sólo en los regalos de promos
 * fraccionadas, donde el bloque agrupa más de una subunidad.
 */
export function esCantidadEnSubunidades(item: ItemConUnidad): boolean {
  return Boolean(item.es_bonificacion) && factorDeLaLinea(item) > 1;
}

/**
 * Etiqueta de la cantidad, lista para mostrar.
 * - Venta o regalo no fraccionado → "x24"
 * - Regalo fraccionado           → "x392 botellas" (+ equivalente en fardos)
 */
export function formatCantidadItem(item: ItemConUnidad): string {
  if (!esCantidadEnSubunidades(item)) return `x${item.cantidad}`;
  return `x${item.cantidad} botellas`;
}

/**
 * Equivalente en unidades de venta de un regalo fraccionado, para aclarar al
 * lado: "= 65,3 fardos". null cuando la cantidad ya está en fardos.
 */
export function equivalenteEnUnidades(item: ItemConUnidad): string | null {
  if (!esCantidadEnSubunidades(item)) return null;
  const fardos = item.cantidad / factorDeLaLinea(item);
  // Un decimal alcanza: 392/6 = 65,3. Sin decimales "65" sugiere exactitud que no hay.
  const txt = Number.isInteger(fardos) ? String(fardos) : fardos.toFixed(1).replace('.', ',');
  return `≈ ${txt} ${fardos === 1 ? 'fardo' : 'fardos'}`;
}
