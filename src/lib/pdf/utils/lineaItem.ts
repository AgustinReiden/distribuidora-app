/**
 * Construcción de la línea de un ítem para los PDFs operativos (orden de
 * preparación y hoja de ruta).
 *
 * Existe porque `pedido_items.cantidad` no está siempre en la misma unidad: el
 * regalo de una promo Fracción viene en subunidades sueltas (botellas) y el
 * resto en unidades de venta. Imprimir "392x Manaos Pomelo 3L" sin aclarar la
 * unidad hace que el depósito prepare 392 unidades de venta en vez de 65 fardos
 * y 2 botellas.
 *
 * La unidad se decide con la cascada de `unidadesRegalo` (congelado → vivo con
 * el gate `regalo_mueve_stock` → 1), que es el puerto TS de
 * `public.factor_bonificacion` (mig 212). Leer el factor vivo de la promo acá
 * significaba que subir el factor de 6 a 12 reescribía la unidad de pedidos ya
 * cerrados.
 *
 * El recibo (`reciboPedido.js`) todavía arma su línea por su cuenta; converge
 * acá en FE-16.
 */
import { formatAclaracionBulto } from './formatBulto';
import {
  esCantidadEnSubunidades,
  factorDeLaLinea,
  type ItemConUnidad,
} from '../../../utils/unidadesRegalo';

export interface ItemImpresion extends ItemConUnidad {
  /** Texto manual de la promo, ej "2 Botellas Manaos Pomelo 3L". */
  descripcion_regalo?: string | null;
  producto?: {
    nombre?: string | null;
    unidades_de_venta_por_fardo?: number | null;
    etiqueta_bulto?: string | null;
  } | null;
}

interface OpcionesLinea {
  /** Sufijo "(REGALO)". Se apaga donde la lista ya está rotulada como bonificada. */
  marcarRegalo?: boolean;
}

/**
 * `descripcion_regalo` sin su conteo inicial: "2 Botellas Manaos 3L" describe
 * UN bloque de la promo, y la cantidad de la línea es la del pedido entero. Si
 * el número se deja puesto sale "392x 2 Botellas…" y se carga el doble (o el
 * séxtuple). Una descripción sin número inicial se devuelve tal cual.
 */
export function nombreSinConteo(desc: string | null | undefined): string {
  const limpio = (desc || '').trim();
  if (!limpio) return '';
  const m = /^\d+\s+(.+)$/.exec(limpio);
  return m ? m[1] : limpio;
}

/** Nombre a imprimir: para un regalo manda la descripción de la promo. */
export function nombreDeLaLinea(item: ItemImpresion): string {
  const producto = item.producto?.nombre?.trim() || 'Producto';
  if (!item.es_bonificacion) return producto;
  return nombreSinConteo(item.descripcion_regalo) || producto;
}

/**
 * Parte una cantidad en subunidades a unidades de venta completas + el resto.
 * 392 botellas con factor 6 → 65 fardos y 2 sueltas.
 */
export function desgloseSubunidades(
  cantidad: number,
  factor: number,
): { fardos: number; sueltas: number } {
  const total = Number(cantidad) || 0;
  const f = Math.max(Number(factor) || 1, 1);
  return { fardos: Math.floor(total / f), sueltas: total % f };
}

/** "= 65 FARDOS + 2" / "= 65 FARDOS". Vacío si no llega a un fardo. */
function equivalenciaEnFardos(cantidad: number, factor: number): string {
  const { fardos, sueltas } = desgloseSubunidades(cantidad, factor);
  if (fardos <= 0) return '';
  const etiqueta = fardos === 1 ? 'FARDO' : 'FARDOS';
  return sueltas > 0 ? ` = ${fardos} ${etiqueta} + ${sueltas}` : ` = ${fardos} ${etiqueta}`;
}

/**
 * Línea de un ítem, con la unidad explícita:
 *  - venta / regalo de unidad entera → "12x Manaos Pomelo 3L (2 FARDOS)"
 *  - regalo en subunidades           → "392x Botellas Manaos Pomelo 3L
 *                                        (SUELTAS, NO FARDO = 65 FARDOS + 2)"
 */
export function lineaItemImpresion(item: ItemImpresion, opciones: OpcionesLinea = {}): string {
  const { marcarRegalo = true } = opciones;
  const cantidad = Number(item.cantidad) || 0;
  const nombre = nombreDeLaLinea(item);
  const sufijoRegalo = marcarRegalo && item.es_bonificacion ? ' (REGALO)' : '';

  if (esCantidadEnSubunidades(item)) {
    const equivalencia = equivalenciaEnFardos(cantidad, factorDeLaLinea(item));
    return `${cantidad}x ${nombre} (SUELTAS, NO FARDO${equivalencia})${sufijoRegalo}`;
  }

  // Acá la cantidad ya está en unidades de venta, así que la aclaración de
  // bulto del producto aplica igual que en una línea de venta.
  const aclaracion = formatAclaracionBulto(
    cantidad,
    item.producto?.unidades_de_venta_por_fardo,
    item.producto?.etiqueta_bulto,
  );
  return aclaracion
    ? `${cantidad}x ${nombre} ${aclaracion}${sufijoRegalo}`
    : `${cantidad}x ${nombre}${sufijoRegalo}`;
}
