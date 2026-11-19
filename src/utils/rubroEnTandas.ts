/**
 * Renombrar o eliminar un rubro grande va en tandas (1596-b9, #1596): un supermercado tiene
 * 15.000–30.000 productos, y pasarlos todos en una llamada se cortaba contra los 8 s de REST.
 * `renombrar_rubro` y `eliminar_rubro` reciben `p_lote`, pasan hasta esa cantidad de productos y
 * dicen cuántos faltan; esto repite hasta terminar, avisando el avance.
 *
 * Si una tanda falla, lo hecho queda (cada tanda es su transacción) y el rubro sigue coherente: la
 * base retoma donde quedó con la misma operación, y rechaza otra mientras ésa está a medias. El
 * aviso dice cuánto se hizo y cómo terminar.
 */

/** Productos por llamada: medido, una tanda de 5.000 tarda 0,6–1,5 s con la máquina cargada. */
export const TANDA_RUBRO = 5000

export interface RespuestaTandaRubro {
  /** Productos que pasó esta llamada. */
  productos: number
  /** Los que faltan. Un server de antes de las tandas no lo manda: hizo todo de una vez. */
  faltan?: number
  terminado?: boolean
  /** El id del rubro: el que sólo era texto lo recibe en la primera tanda. */
  id?: string | null
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
  operacion: 'renombrar' | 'eliminar',
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
      const boton = operacion === 'renombrar' ? '«Renombrar» con el mismo nombre' : '«Eliminar»'
      throw new Error(
        `${motivo}. Ya se pasaron ${miles(hechos)} productos` +
        (faltanAntes != null ? ` y faltan ${miles(faltanAntes)}` : '') +
        `: volvé a tocar ${boton} para terminar.`,
      )
    }
    if (r.id) id = r.id
    hechos += r.productos ?? 0
    const faltan = r.faltan ?? 0
    onAvance?.({ hechos, faltan })
    if (r.terminado || faltan === 0) return { hechos }
    if (faltanAntes != null && faltan >= faltanAntes || (r.productos ?? 0) === 0) {
      throw new Error(`La operación no avanzó (faltan ${miles(faltan)} productos). Recargá la pantalla e intentá de nuevo.`)
    }
    faltanAntes = faltan
  }
  throw new Error('La operación no terminó. Recargá la pantalla e intentá de nuevo.')
}
