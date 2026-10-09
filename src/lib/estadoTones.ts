/**
 * Mapas de estado -> tono visual.
 *
 * Un "tono" es la intencion del color (neutro / marca / exito / atencion /
 * problema), no el color en si: que clases de Tailwind le tocan a cada uno lo
 * decide el Badge (src/components/ui/badge-variants.ts). Esa separacion es la
 * que permite que haya una sola paleta de estado en toda la app en vez de las
 * seis que hay hoy repartidas por los componentes.
 *
 * La firma acepta `string` ademas de `EstadoPedido`: el estado llega de la base
 * (y de filtros de UI) sin garantia de pertenecer a la union, y todo lo que no
 * este mapeado cae en el default.
 */
import type { EstadoPago, EstadoPedido, RolUsuario } from '@/types';

export type Tone = 'neutral' | 'brand' | 'success' | 'warning' | 'danger';

/**
 * Tono del estado de un pedido.
 *
 * Los seis estados que admite `pedidos_estado_check` (mig 297) estan mapeados.
 * Cualquier otro valor cae en el default (neutral), que es adonde mandaba lo
 * desconocido `getEstadoColor`, el mapa ad hoc de formatters.ts que éste
 * reemplazó (se borró en WP-43, #768).
 */
export function toneDeEstadoPedido(estado: EstadoPedido | string | null | undefined): Tone {
  switch (estado) {
    case 'pendiente':
      return 'neutral';
    case 'en_preparacion':
      return 'warning';
    case 'asignado':
      return 'brand';
    case 'entregado':
      return 'success';
    case 'cancelado':
    case 'anulado':
      // 'anulado' va con 'cancelado': en la base los dos significan "no es una
      // venta". `getEstadoColor` (formatters.ts, ya borrado) no lo mapeaba y
      // caia al gris.
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
 * operativa que daba `getEstadoPagoColor` (src/utils/formatters.ts, borrado en
 * WP-43): un pago que no consta es plata que el cliente debe, y en el mostrador
 * se mira igual que un pendiente. Mandar el desconocido al gris lo esconde justo
 * donde hay que verlo.
 *
 * `parcial` va en `warning` (ámbar); `getEstadoPagoColor` lo pintaba amarillo.
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

/**
 * Tono del estado de una compra. No hay un tipo `EstadoCompra` compartido en
 * `src/types/index.ts` (vive local en cada componente de Compras), asi que la
 * firma acepta `string` como el resto de este archivo.
 */
export function toneDeEstadoCompra(estado: string | null | undefined): Tone {
  switch (estado) {
    case 'pendiente':
      return 'warning';
    case 'recibida':
      return 'success';
    case 'parcial':
      return 'brand';
    case 'cancelada':
      return 'danger';
    default:
      return 'neutral';
  }
}

/**
 * Labels de estado de compra, mismos textos que usaban los `ESTADOS_COMPRA`
 * locales de `VistaCompras` y `ModalDetalleCompra` antes de consolidarse aca.
 */
export const ETIQUETA_ESTADO_COMPRA: Record<string, string> = {
  pendiente: 'Pendiente',
  recibida: 'Recibida',
  parcial: 'Parcial',
  cancelada: 'Cancelada',
};
