/**
 * Filtros de los modales de acciones masivas (entregas, pagos, entrega con pago).
 *
 * La regla de la fecha es la de «Armar ruta» (`filtroFechaPedidos`): por defecto manda la
 * fecha de entrega, y un pedido sin fecha de entrega programada cae a la fecha del pedido.
 * Acá sólo se arma el filtro entero; lo que se manda y lo que dice la confirmación sale de lo
 * que este filtro deja ver (#1698, como 1598-b8 en pagos).
 */
import { pedidoEnRangoDeFechas, type TipoFiltroFecha } from './filtroFechaPedidos';

export interface PedidoParaFiltroMasivo {
  fecha?: string | null;
  created_at?: string | null;
  fecha_entrega_programada?: string | null;
  forma_pago?: string | null;
}

export interface FiltroMasivo {
  tipoFecha: TipoFiltroFecha;
  desde: string;
  hasta: string;
  /** '' = todas las formas de pago. */
  formaPago: string;
}

export const TIPO_FECHA_MASIVAS_POR_DEFECTO: TipoFiltroFecha = 'entrega';

export function pedidoPasaFiltroMasivo(p: PedidoParaFiltroMasivo, f: FiltroMasivo): boolean {
  const fecha = p.fecha || p.created_at?.split('T')[0] || '';
  const enFecha = pedidoEnRangoDeFechas(
    { fecha, fecha_entrega_programada: p.fecha_entrega_programada },
    f.tipoFecha,
    f.desde,
    f.hasta,
  );
  if (!enFecha) return false;
  if (f.formaPago && p.forma_pago !== f.formaPago) return false;
  return true;
}

export function filtrarPedidosMasivos<T extends PedidoParaFiltroMasivo>(pedidos: T[], f: FiltroMasivo): T[] {
  return pedidos.filter(p => pedidoPasaFiltroMasivo(p, f));
}
