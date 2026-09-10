/**
 * El contexto compartido entre /reportes y /reportes-gerenciales vive en la
 * query string.
 *
 * Antes cada pantalla tenía su período y su sucursal en `useState`: saltar de
 * una a la otra reseteaba todo, y no había forma de mandarle a alguien "mirá
 * esto". Con los params, "Ver detalle" en el gerencial cae en la pestaña de
 * /reportes con el MISMO período, el link es compartible, el reload lo conserva
 * y el back de Android funciona (es una PWA).
 *
 * Qué NO se comparte, y por qué: el id del preset. Las dos pantallas ofrecen
 * juegos distintos (Reportes: año + últimos 3 meses; Gerenciales: este mes, mes
 * pasado, trimestre, año y 10 meses más). Un id común obligaría a un vocabulario
 * único que ninguna de las dos usa hoy. En vez de eso se comparten SÓLO las
 * fechas, que son el dato, y cada pantalla marca su preset si alguno coincide
 * con el rango recibido; si no coincide ninguno, muestra "Personalizado".
 */

export const PARAM_DESDE = 'desde'
export const PARAM_HASTA = 'hasta'
export const PARAM_SUC = 'suc'
export const PARAM_TAB = 'tab'

/** `suc=red` es el consolidado. Se escribe explícito para distinguirlo de "no vino nada". */
export const SUC_RED = 'red'

export interface RangoUrl {
  desde: string | null
  hasta: string | null
}

const RE_FECHA = /^\d{4}-\d{2}-\d{2}$/

/** 'YYYY-MM-DD' que además existe en el calendario ('2026-02-31' no vale). */
export function esFechaValida(valor: string | null): valor is string {
  if (!valor || !RE_FECHA.test(valor)) return false
  const d = new Date(`${valor}T00:00:00`)
  if (Number.isNaN(d.getTime())) return false
  // El constructor normaliza (31/02 -> 03/03), así que hay que comparar de vuelta.
  const vuelta = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  return vuelta === valor
}

/**
 * El rango de la URL, o `{null, null}` si no vino o vino mal.
 *
 * Un rango a medias o invertido se descarta ENTERO: media fecha aplicada haría
 * que la pantalla muestre un período que el usuario no pidió y que no se
 * corresponde con lo que dice el selector.
 */
export function leerRango(sp: URLSearchParams): RangoUrl {
  const desde = sp.get(PARAM_DESDE)
  const hasta = sp.get(PARAM_HASTA)
  if (!esFechaValida(desde) || !esFechaValida(hasta)) return { desde: null, hasta: null }
  if (desde > hasta) return { desde: null, hasta: null }
  return { desde, hasta }
}

/**
 * La sucursal de la URL.
 *
 * `undefined` = no vino el param (que cada pantalla resuelva con su default);
 * `null` = red consolidada, pedida explícitamente.
 */
export function leerSucursal(sp: URLSearchParams): number | null | undefined {
  const raw = sp.get(PARAM_SUC)
  if (raw === null || raw === '') return undefined
  if (raw === SUC_RED) return null
  const n = Number(raw)
  return Number.isInteger(n) && n > 0 ? n : undefined
}

/** Escribe (o borra) el rango sobre una copia de los params. */
export function escribirRango(sp: URLSearchParams, desde: string | null, hasta: string | null): URLSearchParams {
  const next = new URLSearchParams(sp)
  if (esFechaValida(desde) && esFechaValida(hasta) && desde <= hasta) {
    next.set(PARAM_DESDE, desde)
    next.set(PARAM_HASTA, hasta)
  } else {
    next.delete(PARAM_DESDE)
    next.delete(PARAM_HASTA)
  }
  return next
}

/** Escribe la sucursal. `null` = red. */
export function escribirSucursal(sp: URLSearchParams, id: number | null): URLSearchParams {
  const next = new URLSearchParams(sp)
  next.set(PARAM_SUC, id === null ? SUC_RED : String(id))
  return next
}

export interface DestinoReporte {
  tab: string
  desde?: string | null
  hasta?: string | null
  sucursalId?: number | null
}

/**
 * El `to` de un link "Ver detalle" del gerencial hacia /reportes.
 *
 * Omitir `desde`/`hasta` es deliberado en algunos destinos: `Cuentas por Cobrar`
 * no tiene argumentos de fecha (el aging es siempre al día de hoy), así que
 * mandarle un período que va a ignorar sería mentir con la URL.
 */
export function linkAReportes({ tab, desde, hasta, sucursalId }: DestinoReporte): string {
  const sp = new URLSearchParams()
  sp.set(PARAM_TAB, tab)
  if (esFechaValida(desde ?? null) && esFechaValida(hasta ?? null) && (desde as string) <= (hasta as string)) {
    sp.set(PARAM_DESDE, desde as string)
    sp.set(PARAM_HASTA, hasta as string)
  }
  if (sucursalId !== undefined) sp.set(PARAM_SUC, sucursalId === null ? SUC_RED : String(sucursalId))
  return `/reportes?${sp.toString()}`
}
