/**
 * Qué fecha gobierna el filtro del pool en "Armar ruta".
 *
 * El modal filtra los disponibles por fecha de pedido o por fecha de entrega, y
 * cada fila muestra las dos. Una usuaria filtró por "hoy martes" y le
 * aparecieron 7 pedidos que en la lista decían "Pedido: lunes": el filtro
 * estaba en modo entrega -el default- y esos pedidos se entregaban hoy, así que
 * correspondía que aparecieran. Sin ver cuál de las dos fechas manda, el
 * resultado se lee como un bug.
 *
 * Esta función es la única fuente de esa regla: la usan tanto el filtro como el
 * resaltado de la fila, así que no pueden decir cosas distintas.
 */

export type TipoFiltroFecha = 'pedido' | 'entrega';

export interface PedidoConFechas {
  fecha?: string | null;
  fecha_entrega_programada?: string | null;
}

export interface FechaQueFiltra {
  /** Columna realmente usada, ya resuelto el fallback. null = el pedido no tiene ninguna. */
  columna: TipoFiltroFecha | null;
  /** Valor YYYY-MM-DD contra el que se compara. null = sin fecha conocida. */
  valor: string | null;
}

/**
 * En modo 'entrega' la fecha de entrega programada puede faltar, y ahí el
 * filtro cae a la fecha de pedido. Devolver la columna que se terminó usando
 * -y no la que se pidió- es lo que permite resaltar la verdadera.
 */
export function fechaQueFiltra(
  pedido: PedidoConFechas,
  tipo: TipoFiltroFecha,
): FechaQueFiltra {
  if (tipo === 'entrega') {
    if (pedido.fecha_entrega_programada) {
      return { columna: 'entrega', valor: pedido.fecha_entrega_programada };
    }
    return pedido.fecha
      ? { columna: 'pedido', valor: pedido.fecha }
      : { columna: null, valor: null };
  }

  return pedido.fecha
    ? { columna: 'pedido', valor: pedido.fecha }
    : { columna: null, valor: null };
}

/**
 * ¿Entra el pedido en el rango? Sin fecha conocida entra: es preferible
 * mostrarlo de más y que lo descarte una persona, a esconderlo.
 * `desde`/`hasta` vacíos no acotan ese extremo.
 */
export function pedidoEnRangoDeFechas(
  pedido: PedidoConFechas,
  tipo: TipoFiltroFecha,
  desde: string,
  hasta: string,
): boolean {
  const { valor } = fechaQueFiltra(pedido, tipo);
  if (!valor) return true;
  if (desde && valor < desde) return false;
  if (hasta && valor > hasta) return false;
  return true;
}
