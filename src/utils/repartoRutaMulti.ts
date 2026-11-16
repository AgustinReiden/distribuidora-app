/**
 * «Dividir ruta»: qué hacer con los pedidos que el optimizador no puso en ninguna ruta.
 *
 * Hay DOS motivos distintos y se tratan distinto (#1549, FRT-05):
 *
 *  - Sin coordenadas: Google no los puede ubicar, pero son entregables. Es una decisión
 *    anterior que todo pedido seleccionado termine en la ruta de alguien, así que se
 *    reparten (por zona preferida o, si no, a turnos) sin mirar el máximo de paradas: el
 *    optimizador nunca los vio, así que no pudo contarlos contra el tope.
 *  - `skipped`: el optimizador SÍ los vio y los dejó afuera (el tope de paradas de los
 *    choferes, o una ventana que no cierra). Repartirlos igual pasaba por encima del máximo
 *    de cada chofer. Ahora sólo entran hasta completar el cupo que le queda a cada uno, y lo
 *    que no entra queda sin asignar.
 *
 * El cupo de un chofer es `max_paradas` menos lo que ya lleva (las que ruteó el optimizador
 * más los sin coordenadas que se le repartieron). Sin `max_paradas` no hay tope.
 *
 * Es una función pura: no toca el estado ni la red.
 */

export interface RepartidorReparto {
  transportista_id: string
  /** Tope de paradas. null / undefined / 0 = sin tope. */
  max_paradas?: number | null
  /** Zonas (zona_id) que prefiere. Es una preferencia: no fuerza nada. */
  zonas_preferidas?: number[] | null
}

export interface PedidoSinRuta {
  id: string
  /** zona_id del cliente, si tiene. */
  zonaId: number | null
}

export type MotivoSinRuta = 'sin_coordenadas' | 'optimizador'

export interface AsignacionSinRuta {
  pedidoId: string
  transportistaId: string
  motivo: MotivoSinRuta
}

export interface ResultadoRepartoSinRuta {
  /** A quién se le repartió cada pedido, en el orden en que se repartieron. */
  asignados: AsignacionSinRuta[]
  /** Pedidos que el optimizador dejó afuera y a los que no les quedó cupo en ningún chofer. */
  sinAsignar: string[]
}

export interface EntradaRepartoSinRuta {
  repartidores: RepartidorReparto[]
  /** Cuántas paradas le puso el optimizador a cada chofer (por `transportista_id`). */
  ruteadasPorChofer: ReadonlyMap<string, number>
  /** Los pedidos seleccionados que no volvieron en ninguna ruta, en el orden de la selección. */
  pedidosSinRuta: PedidoSinRuta[]
  /** Ids que el optimizador devolvió como `skipped`. El resto de `pedidosSinRuta` es «sin coordenadas». */
  skipped: Iterable<string>
}

/** Cupo que le queda a un chofer. `Infinity` si no tiene tope. */
function cupoDe(r: RepartidorReparto, carga: number): number {
  const tope = r.max_paradas != null && r.max_paradas > 0 ? Math.floor(r.max_paradas) : null
  return tope == null ? Infinity : Math.max(tope - carga, 0)
}

function choferPreferido(repartidores: RepartidorReparto[], zonaId: number | null): string | undefined {
  if (zonaId == null) return undefined
  return repartidores.find(r => Array.isArray(r.zonas_preferidas) && r.zonas_preferidas.includes(zonaId))
    ?.transportista_id
}

export function repartirPedidosSinRuta(entrada: EntradaRepartoSinRuta): ResultadoRepartoSinRuta {
  const { repartidores, ruteadasPorChofer, pedidosSinRuta } = entrada
  const skipped = new Set(Array.from(entrada.skipped, String))
  const asignados: AsignacionSinRuta[] = []
  const sinAsignar: string[] = []
  if (repartidores.length === 0) {
    return { asignados, sinAsignar: pedidosSinRuta.filter(p => skipped.has(String(p.id))).map(p => String(p.id)) }
  }

  const carga = new Map<string, number>()
  for (const r of repartidores) carga.set(r.transportista_id, ruteadasPorChofer.get(r.transportista_id) ?? 0)

  // 1) Sin coordenadas: todos se reparten, sin mirar el tope (como siempre). Primero, para que
  //    los skipped se midan contra el cupo que de verdad queda.
  let turno = 0
  for (const p of pedidosSinRuta) {
    if (skipped.has(String(p.id))) continue
    let destino = choferPreferido(repartidores, p.zonaId)
    if (!destino) {
      destino = repartidores[turno % repartidores.length].transportista_id
      turno++
    }
    carga.set(destino, (carga.get(destino) ?? 0) + 1)
    asignados.push({ pedidoId: String(p.id), transportistaId: destino, motivo: 'sin_coordenadas' })
  }

  // 2) Lo que el optimizador dejó afuera: sólo donde hay cupo. La zona preferida manda si ese
  //    chofer todavía tiene lugar; si no, el que lleva menos paradas (a igualdad, el primero).
  for (const p of pedidosSinRuta) {
    if (!skipped.has(String(p.id))) continue
    const conCupo = repartidores.filter(r => cupoDe(r, carga.get(r.transportista_id) ?? 0) > 0)
    if (conCupo.length === 0) { sinAsignar.push(String(p.id)); continue }
    const preferido = choferPreferido(conCupo, p.zonaId)
    const destino = preferido
      ?? conCupo.reduce((mejor, r) =>
        (carga.get(r.transportista_id) ?? 0) < (carga.get(mejor.transportista_id) ?? 0) ? r : mejor,
      ).transportista_id
    carga.set(destino, (carga.get(destino) ?? 0) + 1)
    asignados.push({ pedidoId: String(p.id), transportistaId: destino, motivo: 'optimizador' })
  }

  return { asignados, sinAsignar }
}
