/**
 * Impuestos internos por encuadre (mig 277).
 *
 * La ficha de un producto no guarda una tasa: guarda un ENCUADRE (General,
 * Reducida, Exento...). La tasa es del encuadre, NOMINAL y con vigencia, y la
 * que se aplica sobre el neto es la efectiva: el impuesto se liquida "por
 * dentro", así que un 8% nominal es 8/92 = 8,6957% sobre el neto.
 *
 * Este módulo es el espejo de `ii_tasa_efectiva` y del trigger
 * `derivar_ii_producto` de la mig 277: la base escribe
 * `productos.impuestos_internos` con `round(efectiva, 4)`, y la ficha tiene
 * que mostrar y costear con el MISMO número antes de guardar —si no, un
 * producto nuevo nace con `costo_real` y costo promedio calculados con otra
 * tasa que la que la base le pone un instante después—.
 */
import { redondearSQL } from './calculations'

export interface EncuadreII {
  id: string
  nombre: string
  criterio: string | null
  activo: boolean
}

export interface AlicuotaII {
  id: string
  encuadre_id: string
  /** Fracción: 0.08 es el 8%. */
  tasa_nominal: number
  /** 'YYYY-MM-DD' */
  vigente_desde: string
  /** 'YYYY-MM-DD' o null = abierta */
  vigente_hasta: string | null
}

/** La alícuota del encuadre vigente a esa fecha, o null si no hay ninguna. */
export function alicuotaVigente(
  encuadreId: string | number | null | undefined,
  fecha: string,
  alicuotas: AlicuotaII[],
): AlicuotaII | null {
  if (encuadreId === null || encuadreId === undefined || encuadreId === '') return null
  const id = String(encuadreId)
  // Las fechas son 'YYYY-MM-DD': comparar como texto es comparar como fecha.
  const candidatas = alicuotas
    .filter(a => String(a.encuadre_id) === id
      && a.vigente_desde <= fecha
      && (a.vigente_hasta === null || a.vigente_hasta >= fecha))
    .sort((a, b) => (a.vigente_desde < b.vigente_desde ? 1 : -1))
  return candidatas[0] ?? null
}

/** Efectiva en % a partir de una nominal en fracción, SIN redondear. */
export function efectivaDesdeNominal(tasaNominal: number): number {
  return (100 * tasaNominal) / (1 - tasaNominal)
}

/**
 * El valor que la base le va a poner a `productos.impuestos_internos`: la
 * efectiva vigente a esa fecha, en %, redondeada a 4 decimales como
 * `round(numeric, 4)`. 0 si el encuadre no tiene tasa vigente.
 *
 * Devuelve null si el producto NO tiene encuadre: en ese caso la base
 * conserva el valor heredado, y quien llama decide qué mostrar.
 */
export function tasaEfectivaEncuadre(
  encuadreId: string | number | null | undefined,
  fecha: string,
  alicuotas: AlicuotaII[],
): number | null {
  if (encuadreId === null || encuadreId === undefined || encuadreId === '') return null
  const alicuota = alicuotaVigente(encuadreId, fecha, alicuotas)
  if (!alicuota) return 0
  return redondearSQL(efectivaDesdeNominal(Number(alicuota.tasa_nominal)), 4)
}

/** "8%" para una nominal de 0.08; sin ceros de más. */
export function formatearNominal(tasaNominal: number): string {
  return `${String(redondearSQL(tasaNominal * 100, 4)).replace('.', ',')}%`
}
