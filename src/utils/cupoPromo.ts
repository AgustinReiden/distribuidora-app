/**
 * El cupo de una promo con límite de usos (#1283, #1300).
 *
 * Decisión del dueño (29/10): un uso es el CORTE de la promo, en su unidad, no
 * la cantidad de la línea. Por eso sustituir el regalo no mueve el cupo. El
 * conteo lo da la RPC `promos_cupo`, con la misma cuenta que el trigger
 * `validar_limite_usos_promo` (`_promo_usos`): acá no se recalcula.
 *
 * `usos_pendientes` NO es este conteo: en una promo con fracción es el resto de
 * la barra.
 */

/** Lo que tiene que decir toda pantalla que muestre el cupo. El rechazo del server dice lo mismo. */
export const LEYENDA_CUPO = 'El cupo cuenta el corte de la promo, en su unidad: sustituir el regalo no lo cambia.'

export interface CupoPromo {
  promocionId: string
  limite: number
  usos: number
  /** Lo que le queda a este pedido. Es el "quedan" del rechazo: al editar, su propio regalo no le resta. */
  quedan: number
}

export interface RegaloParaCupo {
  promocionId?: string | null
  promoNombre?: string | null
  /** El corte: la cantidad como la da la promo, no la de una línea sustituida. */
  cantidad: number
}

export interface AvisoCupo {
  promocionId: string
  promoNombre: string
  limite: number
  quedan: number
  lleva: number
  alcanza: boolean
}

/** Una promo que llegó a su límite: el trigger la apaga. */
export function cupoLleno(cupo: CupoPromo): boolean {
  return cupo.usos >= cupo.limite
}

/**
 * Un aviso por cada promo con límite de la que el pedido lleva regalo. Las
 * partes de un reparto son de la misma promo y se suman.
 */
export function avisosDeCupo(
  cupos: ReadonlyMap<string, CupoPromo> | undefined,
  regalos: readonly RegaloParaCupo[],
): AvisoCupo[] {
  if (!cupos || cupos.size === 0) return []
  const porPromo = new Map<string, AvisoCupo>()
  for (const regalo of regalos) {
    if (regalo.promocionId == null) continue
    const promocionId = String(regalo.promocionId)
    const cupo = cupos.get(promocionId)
    if (!cupo) continue
    const aviso = porPromo.get(promocionId) ?? {
      promocionId,
      promoNombre: regalo.promoNombre ?? `#${promocionId}`,
      limite: cupo.limite,
      quedan: cupo.quedan,
      lleva: 0,
      alcanza: true,
    }
    aviso.lleva += regalo.cantidad
    aviso.alcanza = aviso.lleva <= aviso.quedan
    porPromo.set(promocionId, aviso)
  }
  return [...porPromo.values()]
}

/**
 * Las promos de las que el pedido ya tiene regalo. La política rige el alta y no
 * hacia atrás (mig 362): al editar o cambiar el cliente, estas siguen resolviendo
 * aunque se hayan apagado, también por llegar a su límite (#1300).
 */
export function promosConRegalo(
  items: readonly { es_bonificacion?: boolean | null; promocion_id?: string | number | null }[] | undefined,
): string[] {
  const ids = new Set<string>()
  for (const item of items ?? []) {
    if (item.es_bonificacion && item.promocion_id != null) ids.add(String(item.promocion_id))
  }
  return [...ids].sort()
}
