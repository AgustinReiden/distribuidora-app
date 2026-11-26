/**
 * El pedido «Refechado» (#1697, decisiones del dueño del 25/11).
 *
 * Cuando el chofer marca un pedido «no entregado», el server (`marcar_no_entregado`) le pasa
 * la entrega programada al día siguiente en ese mismo momento, salvo con el motivo «Lo
 * rechazó» (`cliente_rechaza`), y guarda la fecha original en
 * `pedidos.entrega_refechada_desde`. Una programada que ya era posterior a hoy no se adelanta.
 * La fecha del pedido (la de carga) no se toca.
 *
 * Acá vive lo que el front necesita de esa regla: la etiqueta (lista, ficha y armado de la
 * ruta) y el aviso del modal de no entrega. La regla la aplica el server; si cambia allá,
 * cambia `seRefechaConMotivo`.
 */
import { esPedidoDeBaja } from './pedidoDeBaja';
import { formatFecha } from './formatters';

/** El motivo con el que la entrega NO pasa al día siguiente (queda como estaba). */
export const MOTIVO_SIN_REFECHA = 'cliente_rechaza';

/** ¿Este motivo de no entrega pasa la entrega al día siguiente? */
export function seRefechaConMotivo(motivo: string | null | undefined): boolean {
  return Boolean(motivo) && motivo !== MOTIVO_SIN_REFECHA;
}

export interface PedidoRefechable {
  estado?: string | null;
  fecha_entrega_programada?: string | null;
  entrega_refechada_desde?: string | null;
}

export interface EtiquetaRefechado {
  texto: 'Refechado';
  /** «Entrega original: 25/11», para el title y el lector de pantalla. */
  detalle: string;
  /** La fecha original, ya formateada. */
  original: string;
}

/**
 * La etiqueta del pedido refechado, o null si no corresponde. Sólo mientras el pedido sigue
 * por entregar: entregado o dado de baja, la marca queda en la base pero ya no se muestra.
 */
export function etiquetaRefechado(pedido: PedidoRefechable | null | undefined): EtiquetaRefechado | null {
  if (!pedido?.entrega_refechada_desde) return null;
  if (pedido.estado === 'entregado' || esPedidoDeBaja(pedido.estado)) return null;
  const original = formatFecha(pedido.entrega_refechada_desde);
  return { texto: 'Refechado', detalle: `Entrega original: ${original}`, original };
}
