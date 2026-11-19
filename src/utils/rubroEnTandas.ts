/**
 * Renombrar o eliminar un rubro grande va en tandas (1596-b9, #1596): un supermercado tiene
 * 15.000–30.000 productos, y pasarlos todos en una llamada se cortaba contra los 8 s de REST.
 * `renombrar_rubro` y `eliminar_rubro` reciben `p_lote`, pasan hasta esa cantidad de productos y
 * dicen cuántos faltan; esto repite hasta terminar, avisando el avance.
 *
 * Si una tanda falla, lo hecho queda (cada tanda es su transacción) y el rubro sigue coherente: la
 * base retoma donde quedó, y un cambio a medias aparece en Categorías con «Terminar»
 * (`rubros_a_medias`). Si el rubro tenía otro cambio a medias, la base primero lo termina
 * («retomado», `terminado` en false) y después hace lo pedido: esto sigue llamando.
 */

/** Productos por llamada: medido, una tanda de 5.000 tarda 0,5–2,3 s con la máquina cargada. */
export const TANDA_RUBRO = 5000

export interface RespuestaTandaRubro {
  /** Productos que pasó esta llamada. */
  productos: number
  /** Los que faltan. Un server de antes de las tandas no lo manda: hizo todo de una vez. */
  faltan?: number
  /** Si lo pedido quedó hecho. En false con `retomado`, se avanzó otro cambio a medias. */
  terminado?: boolean
  /** El id del rubro: el que sólo era texto lo recibe en la primera tanda. */
  id?: string | null
  /** Esta llamada avanzó un renombre que había quedado a medias en el mismo rubro. */
  retomado?: { de: string; a: string; faltan: number } | null
}

export interface AvanceRubro {
  hechos: number
  faltan: number
}

const miles = (n: number) => n.toLocaleString('es-AR')
const comoError = (e: unknown): Error => (e instanceof Error ? e : new Error(String(e)))

export async function procesarRubroEnTandas(
  llamar: (id: string | null) => Promise<RespuestaTandaRubro>,
  idInicial: string | null,
  // La operación: hoy sólo cambia el aviso de corte, que manda a «Terminar» en las dos.
  _operacion: 'renombrar' | 'eliminar',
  onAvance?: (avance: AvanceRubro) => void,
): Promise<{ hechos: number }> {
  let id = idInicial
  let hechos = 0
  let faltanAntes: number | null = null
  for (let i = 0; i < 1000; i++) {
    let r: RespuestaTandaRubro
    try {
      r = await llamar(id)
    } catch (e) {
      // Sin nada hecho, el error llega tal cual (ya viene traducido por quien llama).
      if (hechos === 0) throw comoError(e)
      const motivo = (e instanceof Error ? e.message : String(e)).replace(/\.\s*$/, '')
      throw new Error(
        `${motivo}. Ya se pasaron ${miles(hechos)} productos` +
        (faltanAntes != null ? ` y faltan ${miles(faltanAntes)}` : '') +
        ': tocá «Terminar» en el aviso del rubro a medias para terminar.',
      )
    }
    if (r.id) id = r.id
    const productos = r.productos ?? 0
    hechos += productos
    const faltan = r.faltan ?? 0
    onAvance?.({ hechos, faltan })
    // Un server de antes de las tandas no manda ni `terminado` ni `faltan`: hizo todo.
    if (r.terminado === true || (r.terminado === undefined && r.faltan === undefined)) return { hechos }
    if (!r.retomado && (productos === 0 || (faltanAntes != null && faltan >= faltanAntes))) {
      throw new Error(`La operación no avanzó (faltan ${miles(faltan)} productos). Recargá la pantalla e intentá de nuevo.`)
    }
    faltanAntes = r.retomado ? null : faltan
  }
  throw new Error('La operación no terminó. Recargá la pantalla e intentá de nuevo.')
}
