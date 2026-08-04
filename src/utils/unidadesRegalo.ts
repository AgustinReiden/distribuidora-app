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
  promocion?: { unidades_por_bloque?: number | null } | null;
}

/**
 * true si la cantidad de este ítem está en subunidades sueltas (botellas) en
 * vez de en unidades de venta (fardos): pasa sólo en los regalos de promos
 * fraccionadas, donde el bloque agrupa más de una subunidad.
 */
export function esCantidadEnSubunidades(item: ItemConUnidad): boolean {
  return Boolean(item.es_bonificacion) && (item.promocion?.unidades_por_bloque ?? 0) > 1;
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
  const porBloque = item.promocion?.unidades_por_bloque ?? 1;
  const fardos = item.cantidad / porBloque;
  // Un decimal alcanza: 392/6 = 65,3. Sin decimales "65" sugiere exactitud que no hay.
  const txt = Number.isInteger(fardos) ? String(fardos) : fardos.toFixed(1).replace('.', ',');
  return `≈ ${txt} ${fardos === 1 ? 'fardo' : 'fardos'}`;
}
