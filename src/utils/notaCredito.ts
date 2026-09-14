/**
 * Totales de una nota de crédito de compra.
 *
 * Vive fuera del modal por dos razones: es lógica pura y testeable, y
 * exportarla desde el componente rompe el fast refresh.
 */
import type { CondicionIva } from './calculations';

/** Línea de la factura original, con lo mínimo para liquidar el IVA de la NC. */
export interface LineaCompraNC {
  /**
   * `compra_items.id`. Es la clave de la línea, y NO `producto_id`: la misma
   * factura puede traer el mismo producto en dos renglones (el import de Excel y
   * el escaneo los apilaban), y con el producto como clave las dos filas leían la
   * misma cantidad — la nota acreditaba el doble, con su IVA al doble, y guardaba
   * dos items.
   */
  id: string;
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
  /**
   * Una entrada por LÍNEA acreditada, no por producto: dos renglones del mismo
   * producto acreditados en la misma nota son dos items, cada uno con su costo.
   * La RPC no recibe el `compra_items.id` —`nota_credito_items` habla de
   * producto y cantidad— pero el desglose tiene que salir de las líneas o el
   * costo de una de las dos se pierde.
   */
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
 *
 * @param cantidades - `compra_items.id` → unidades a acreditar de ESA línea.
 */
export function calcularTotalesNotaCredito(
  items: LineaCompraNC[],
  cantidades: Record<string, number>,
): TotalesNotaCredito {
  let subtotal = 0;
  let iva = 0;
  const itemsConCantidad: TotalesNotaCredito['itemsConCantidad'] = [];

  for (const item of items) {
    const cant = cantidades[item.id] || 0;
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
