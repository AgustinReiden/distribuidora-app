/**
 * El código de un producto es único por sucursal (1561-b1, decisión D31 del dueño en #1561).
 *
 * Se compara sin mirar mayúsculas ni los espacios de los bordes: «abc-1», «ABC-1» y
 * « ABC-1 » son el mismo código. Es la regla de los rubros (`upper(btrim(nombre))`) y la
 * del índice único del server (`productos_codigo_unico_por_sucursal`, sobre
 * `upper(btrim(codigo))`), que también deja afuera los vacíos: un producto sin código no
 * choca con nadie. El código se guarda como se tipeó, sin los espacios de los bordes.
 *
 * Espejo exacto en lo que importa: `btrim` saca sólo espacios (no tabuladores), igual que
 * acá. Para letras fuera del ASCII, `upper` del server sigue la collation de la base; la
 * que decide es la base, y este espejo sólo adelanta el aviso.
 */

/** La clave con la que se compara: sin los espacios de los bordes y en mayúsculas. '' si no hay código. */
export function claveCodigoProducto(codigo: string | null | undefined): string {
  return (codigo ?? '').replace(/^ +| +$/g, '').toUpperCase()
}

/** ¿Es el mismo código? Un código vacío no es igual a nada. */
export function mismoCodigoProducto(a: string | null | undefined, b: string | null | undefined): boolean {
  const clave = claveCodigoProducto(a)
  return clave !== '' && clave === claveCodigoProducto(b)
}

/** Lo que se guarda: el código sin los espacios de los bordes, o null si no hay código. */
export function codigoParaGuardar(codigo: string | null | undefined): string | null {
  const limpio = (codigo ?? '').trim()
  return limpio === '' ? null : limpio
}

/**
 * Patrón de `ilike` que acierta el código sin mirar mayúsculas (los comodines de LIKE, escapados).
 * Sirve para que la base achique los candidatos; la comparación de verdad es
 * `mismoCodigoProducto`. Un código guardado con espacios en los bordes no lo acierta: a ése lo
 * frena el server. null si no hay código que buscar.
 */
export function patronCodigoProducto(codigo: string | null | undefined): string | null {
  const limpio = (codigo ?? '').replace(/^ +| +$/g, '')
  if (limpio === '') return null
  return limpio.replace(/[\\%_]/g, c => `\\${c}`)
}

/** El índice único del server: sucursal + `upper(btrim(codigo))`, sin los vacíos. */
export const INDICE_CODIGO_PRODUCTO_UNICO = 'productos_codigo_unico_por_sucursal'

/**
 * ¿Es el rechazo del índice único del código? Un 23505 con el nombre del índice en `message`,
 * `details` o `hint`. Llega cuando dos altas se cruzan y las dos pasaron la verificación previa:
 * el trigger del server, que da el mensaje con el producto, tampoco ve la fila del otro hasta
 * que confirma.
 */
export function esCodigoDuplicadoDeBase(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const e = error as { code?: unknown; message?: unknown; details?: unknown; hint?: unknown }
  if (String(e.code ?? '') !== '23505') return false
  return [e.message, e.details, e.hint].some(t => typeof t === 'string' && t.includes(INDICE_CODIGO_PRODUCTO_UNICO))
}

/**
 * El aviso de código repetido, el mismo en el alta, en la edición y cuando lo frena el índice.
 * Tiene que decir qué hacer: quien lo lee casi siempre está cargando una factura y no sabe que
 * el producto ya lo creó él mismo un minuto antes. Con `status = 409`: un duplicado no deja de
 * serlo, no se reintenta.
 */
export function errorCodigoDuplicado(codigo: string | null | undefined, nombreExistente?: string | null, enEdicion = false): Error {
  const queHacer = enEdicion
    ? 'Buscalo por nombre o código, o dejale a este otro código.'
    : 'Buscalo por nombre o código y agregalo, o cargá este con otro código.'
  const mensaje = nombreExistente
    ? `Ya existe un producto con código "${codigo}": «${nombreExistente}». ${queHacer}`
    : `Ya existe un producto con código "${codigo}" en esta sucursal. ${queHacer}`
  const error = new Error(mensaje)
  ;(error as Error & { status?: number }).status = 409
  return error
}
