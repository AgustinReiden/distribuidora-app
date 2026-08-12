/**
 * Totales de una nota de crédito de compra.
 *
 * Vive fuera del modal por dos razones: es lógica pura y testeable, y
 * exportarla desde el componente rompe el fast refresh.
 */
import type { CondicionIva } from './calculations';

/** Línea de la factura original, con lo mínimo para liquidar el IVA de la NC. */
export interface LineaCompraNC {
  producto_id: string;
  cantidad: number;
  costo_unitario: number;
  /** Snapshots fiscales de la línea original (mig 113/177) */
  porcentaje_iva?: number | null;
  condicion_iva?: CondicionIva | null;
}

export interface TotalesNotaCredito {
  subtotal: number;
  iva: number;
  total: number;
  itemsConCantidad: Array<{
    productoId: string;
    cantidad: number;
    costoUnitario: number;
    subtotal: number;
  }>;
}

/**
 * El IVA sale de la alícuota que tenía CADA línea en la factura original, no de
 * un 21% fijo (como hasta la mig 177): contra una factura mixta, acreditar 21%
 * sobre una línea exenta inventa crédito fiscal que el proveedor nunca facturó.
 *
 * Nota: la base es `costo_unitario` (bruto, pre-bonificación), igual que antes.
 * Ese criterio es preexistente y queda sin cambios acá.
 */
export function calcularTotalesNotaCredito(
  items: LineaCompraNC[],
  cantidades: Record<string, number>,
): TotalesNotaCredito {
  let subtotal = 0;
  let iva = 0;
  const itemsConCantidad: TotalesNotaCredito['itemsConCantidad'] = [];

  for (const item of items) {
    const cant = cantidades[item.producto_id] || 0;
    if (cant <= 0) continue;
    const itemSub = cant * item.costo_unitario;
    subtotal += itemSub;
    if ((item.condicion_iva ?? 'gravado') === 'gravado') {
      iva += itemSub * ((item.porcentaje_iva ?? 21) / 100);
    }
    itemsConCantidad.push({
      productoId: item.producto_id,
      cantidad: cant,
      costoUnitario: item.costo_unitario,
      subtotal: itemSub,
    });
  }

  return { subtotal, iva, total: subtotal + iva, itemsConCantidad };
}
