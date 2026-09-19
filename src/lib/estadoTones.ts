/**
 * Mapas de estado -> tono visual.
 *
 * Un "tono" es la intencion del color (neutro / marca / exito / atencion /
 * problema), no el color en si: que clases de Tailwind le tocan a cada uno lo
 * decide el Badge (src/components/ui/badge-variants.ts). Esa separacion es la
 * que permite que haya una sola paleta de estado en toda la app en vez de las
 * seis que hay hoy repartidas por los componentes.
 *
 * Los estados no llegan tipados como union porque la union no los tiene todos:
 * `EstadoPedido` (src/types/index.ts) no nombra `asignado`, `en_camino` ni
 * `anulado`, que si existen en la base y en el codigo. Por eso la firma acepta
 * `string` y todo lo que no este mapeado cae en el default.
 */
import type { EstadoPago, EstadoPedido, RolUsuario } from '@/types';

export type Tone = 'neutral' | 'brand' | 'success' | 'warning' | 'danger';

/**
 * Tono del estado de un pedido.
 *
 * `preparado` y `en_reparto` (estan en los tipos, casi no en los datos) caen en
 * el default, que es adonde los manda hoy `getEstadoColor` tambien.
 */
export function toneDeEstadoPedido(estado: EstadoPedido | string | null | undefined): Tone {
  switch (estado) {
    case 'pendiente':
      return 'neutral';
    case 'en_preparacion':
      return 'warning';
    case 'asignado':
    case 'en_camino':
      return 'brand';
    case 'entregado':
      return 'success';
    case 'cancelado':
    case 'anulado':
      return 'danger';
    default:
      return 'neutral';
  }
}

/**
 * Tono del estado de pago.
 *
 * OJO con el default: todo lo que no sea `pagado` o `parcial` —incluidos `null`
 * y `undefined`— es `danger`, no `neutral`. Es a proposito, y es la misma senal
 * operativa que ya da `getEstadoPagoColor` (src/utils/formatters.ts): un pago
 * que no consta es plata que el cliente debe, y en el mostrador se mira igual
 * que un pendiente. Mandar el desconocido al gris lo esconde justo donde hay
 * que verlo.
 */
export function toneDeEstadoPago(estado: EstadoPago | string | null | undefined): Tone {
  switch (estado) {
    case 'pagado':
      return 'success';
    case 'parcial':
      return 'warning';
    default:
      return 'danger';
  }
}

/**
 * Tono del rol de un usuario. Solo `preventista` y `transportista` se destacan:
 * son los dos que aparecen mezclados en listas operativas (quien vendio, quien
 * entrega). El resto es informativo y va en neutro.
 */
export function toneDeRol(rol: RolUsuario | string | null | undefined): Tone {
  switch (rol) {
    case 'preventista':
      return 'brand';
    case 'transportista':
      return 'warning';
    case 'admin':
    case 'encargado':
    case 'deposito':
      return 'neutral';
    default:
      return 'neutral';
  }
}
