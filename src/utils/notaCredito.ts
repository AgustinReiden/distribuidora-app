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

// ---------------------------------------------------------------------------
// Impuesto interno de la nota (mig 280, #867)
// ---------------------------------------------------------------------------

/** Lo mínimo de la compra para repartir su II entre lo devuelto. */
export interface CompraParaIINC {
  /** `compras.impuestos_internos`: lo que la factura liquidó de II. */
  impuestos_internos?: number | string | null;
  items: Array<{
    producto_id: string | number;
    cantidad: number | string;
    /** `compra_items.subtotal`: neto bonificado de la línea. */
    subtotal?: number | string | null;
    /** `compra_items.impuestos_internos`: TASA efectiva de la línea, en %. */
    impuestos_internos?: number | string | null;
  }>;
}

const num = (x: unknown): number => {
  const v = Number(x);
  return Number.isFinite(v) ? v : 0;
};

const redondear = (x: number): number => Math.round(x * 100) / 100;

/**
 * II que acredita una devolución. Espejo de `ii_nota_credito_compra` (mig 280):
 * lo que se guarda lo calcula la base; esto es sólo la vista previa del modal.
 *
 * No multiplica la tasa por su cuenta: reparte la CABECERA de la compra en
 * proporción al II teórico (neto × tasa) de lo devuelto. Así se respeta el
 * factor del motor (cabecera ÷ Σ teórico, por el II declarado o el redondeo de
 * cada renglón), y devolver todo devuelve la cabecera exacta. Si ninguna línea
 * tiene tasa pero la cabecera tiene II (compras viejas), reparte por neto.
 *
 * @param devueltoPorProducto - `producto_id` → unidades devueltas.
 */
export function calcularIINotaCredito(
  compra: CompraParaIINC,
  devueltoPorProducto: Record<string, number>,
): number {
  const cabecera = num(compra.impuestos_internos);
  if (cabecera <= 0) return 0;

  const porProducto = new Map<string, { comprado: number; teorico: number; neto: number }>();
  for (const it of compra.items) {
    const clave = String(it.producto_id);
    const acc = porProducto.get(clave) ?? { comprado: 0, teorico: 0, neto: 0 };
    const neto = num(it.subtotal);
    acc.comprado += num(it.cantidad);
    acc.teorico += neto * num(it.impuestos_internos) / 100;
    acc.neto += neto;
    porProducto.set(clave, acc);
  }

  let totTeorico = 0;
  let totNeto = 0;
  for (const p of porProducto.values()) {
    totTeorico += p.teorico;
    totNeto += p.neto;
  }

  let propTeorico = 0;
  let propNeto = 0;
  for (const [clave, cant] of Object.entries(devueltoPorProducto)) {
    const p = porProducto.get(clave);
    if (!p || p.comprado <= 0 || !(cant > 0)) continue;
    const fraccion = Math.min(cant, p.comprado) / p.comprado;
    propTeorico += fraccion * p.teorico;
    propNeto += fraccion * p.neto;
  }

  if (totTeorico > 0) return redondear(cabecera * propTeorico / totTeorico);
  if (totNeto > 0) return redondear(cabecera * propNeto / totNeto);
  return 0;
}

/** Una nota de crédito tal como la lista la compra en modo 'ver'. */
export interface NotaCreditoParaCosto {
  total: number | string;
  /** 'ajuste' = sin mercadería. Ausente en respuestas anteriores a la mig 280. */
  tipo?: 'devolucion' | 'ajuste' | null;
}

/**
 * Costo efectivo de la compra después de los ajustes sin mercadería: el total de
 * la factura menos el total de cada nota de tipo 'ajuste'. Las devoluciones no
 * entran: lo devuelto deja de ser de esta compra, no abarata lo que quedó.
 */
export function costoEfectivoCompra(totalCompra: number | string, notas: NotaCreditoParaCosto[]): number {
  const ajustes = notas
    .filter(n => n.tipo === 'ajuste')
    .reduce((acc, n) => acc + num(n.total), 0);
  return redondear(num(totalCompra) - ajustes);
}

/** Importes de un ajuste sin mercadería, como los carga el modal. */
export interface AjusteNotaCreditoInput {
  tipoFactura: 'FC' | 'ZZ';
  /** FC: neto del ajuste. */
  neto: number;
  /** FC: IVA del ajuste. */
  iva: number;
  /** FC: II que acredita. */
  impuestosInternos: number;
  /** ZZ: el total que acredita el proveedor. */
  totalZZ: number;
}

/**
 * Subtotal / IVA / II / total de un ajuste. En ZZ lo pagado ya es el costo final
 * y no hay crédito fiscal: el ajuste es un total, y se guarda con subtotal =
 * total e IVA e II en 0.
 */
export function totalesAjusteNotaCredito(a: AjusteNotaCreditoInput): {
  subtotal: number; iva: number; impuestosInternos: number; total: number;
} {
  if (a.tipoFactura === 'ZZ') {
    const total = redondear(num(a.totalZZ));
    return { subtotal: total, iva: 0, impuestosInternos: 0, total };
  }
  const subtotal = redondear(num(a.neto));
  const iva = redondear(num(a.iva));
  const impuestosInternos = redondear(num(a.impuestosInternos));
  return { subtotal, iva, impuestosInternos, total: redondear(subtotal + iva + impuestosInternos) };
}
