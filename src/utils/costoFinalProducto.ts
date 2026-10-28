/**
 * El costo FINAL de un producto en la ficha.
 *
 * La compra deja en `productos.costo_real` el costo unitario que calcula su motor
 * (migs 193/194): neto bonificado + impuesto interno + los cargos que se
 * prorratean al costo (flete, pallets, bonificaciones), con el II ajustado al
 * declarado en la factura. Es el "Costo unit. neto" de la pantalla de la compra.
 *
 * La ficha no tiene los cargos: sólo `costo_sin_iva` y la tasa de II. Hasta acá
 * recalculaba el costo de reposición como neto + II y, al guardar, lo grababa
 * encima, así que guardar la ficha por cualquier motivo (un subrubro, un precio)
 * le borraba el flete. Ahora el costo final de la ficha es neto + II + el
 * ADICIONAL de la compra: lo que el costo guardado tiene por encima de neto + II.
 * Sin tocar el costo, la ficha muestra exactamente lo guardado; si el admin
 * corrige el neto (una lista nueva del proveedor), el flete por unidad se queda.
 */
import { calcularCostoReal, redondear } from './calculations';

/** Las columnas de `productos` que mira la ficha para el costo final. */
export interface CostosFichaProducto {
  costo_sin_iva?: number | string | null;
  impuestos_internos?: number | string | null;
  costo_real?: number | string | null;
}

const positivo = (v: unknown): number | null => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
};

/**
 * Lo que la última compra le sumó al costo por encima de neto + II: el flete y
 * los demás cargos prorrateados, y el ajuste del II declarado. Puede ser
 * negativo (una bonificación prorrateada). 0 si falta el neto o el costo
 * guardado: sin los dos no hay diferencia que medir.
 */
export function adicionalDeCompra(
  producto: CostosFichaProducto | null | undefined,
  tipoCompra: 'ZZ' | 'FC',
): number {
  const neto = positivo(producto?.costo_sin_iva);
  const real = positivo(producto?.costo_real);
  if (neto === null || real === null) return 0;
  return redondear(real - calcularCostoReal(neto, producto?.impuestos_internos ?? 0, tipoCompra), 4);
}

/** Un costo de la ficha más el adicional de la compra. Sin costo base, 0: el flete solo no es un costo. */
export function conAdicionalDeCompra(costoBase: number, adicional: number): number {
  return costoBase > 0 ? redondear(costoBase + adicional, 4) : 0;
}

const numero = (v: unknown): number => {
  const n = parseFloat(String(v));
  return Number.isFinite(n) ? n : 0;
};

/**
 * ¿Se tocó en la ficha lo que define el costo (el neto o la tasa de II)? Si no,
 * la ficha no reescribe `costo_real`: el que dejó la compra es el bueno.
 */
export function costoEditadoEnFicha(
  original: CostosFichaProducto,
  form: Pick<CostosFichaProducto, 'costo_sin_iva' | 'impuestos_internos'>,
): boolean {
  return numero(form.costo_sin_iva) !== numero(original.costo_sin_iva)
    || numero(form.impuestos_internos) !== numero(original.impuestos_internos);
}
