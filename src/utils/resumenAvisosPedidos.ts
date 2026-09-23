/**
 * La línea que resume los avisos de arriba de /pedidos (#714).
 *
 * `PanelPedidosNoEntregados` y `PanelPedidosTrabados` ocupaban varias líneas
 * cada vez que tenían datos, antes incluso del título de la vista. Ahora se
 * pliegan detrás de una sola línea ("2 avisos: 1 pedido trabado en asignado ·
 * 3 no entregados") que los despliega tal cual son.
 *
 * `total` cuenta AVISOS, no pedidos: cada panel con algo para mostrar es un
 * aviso, y el detalle de cuántos pedidos hay en cada uno va en las partes. Es
 * la lectura del ejemplo del issue, donde 1 trabado + 3 no entregados son
 * "2 avisos".
 */

export interface ConteoAvisosPedidos {
  /** Pedidos trabados en `asignado` que ve quien puede rescatarlos. */
  trabados: number
  /** Pedidos del preventista que siguen sin entregar ni cancelar. */
  noEntregados: number
}

export interface ResumenAvisosPedidos {
  /** Cuántos avisos (paneles) tienen algo para mostrar. */
  total: number
  /** Una frase por aviso, en el orden en que se leen en la línea. */
  partes: string[]
}

/** `null` cuando no hay nada que avisar: no se dibuja una cabecera vacía. */
export function resumenAvisosPedidos({
  trabados,
  noEntregados,
}: ConteoAvisosPedidos): ResumenAvisosPedidos | null {
  const partes: string[] = []

  if (trabados > 0) {
    partes.push(
      trabados === 1 ? '1 pedido trabado en asignado' : `${trabados} pedidos trabados en asignado`,
    )
  }
  if (noEntregados > 0) {
    partes.push(noEntregados === 1 ? '1 no entregado' : `${noEntregados} no entregados`)
  }

  if (partes.length === 0) return null
  return { total: partes.length, partes }
}

/** "1 aviso" / "2 avisos". */
export function etiquetaTotalAvisos(total: number): string {
  return total === 1 ? '1 aviso' : `${total} avisos`
}
