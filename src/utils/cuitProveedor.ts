/**
 * Comparación del CUIT de un proveedor (1557-b10, decisión del dueño en #1557:
 * «el CUIT de un proveedor es único por sucursal, comparado sin guiones»).
 *
 * El CUIT se guarda como lo tipeó quien lo cargó —«30-71234567-8», «30712345678»
 * o «30 71234567 8»—, así que dos escrituras de la misma persona jurídica no son
 * iguales como texto. Para compararlos se usa siempre el CUIT limpio: sólo los
 * dígitos. El índice único del server (B2) usa la misma regla.
 */

/** Sólo los dígitos del CUIT. '' si no tiene ninguno. */
export function cuitLimpio(cuit: string | null | undefined): string {
  return (cuit ?? '').replace(/\D/g, '')
}

/**
 * Patrón de `ilike` que acierta el CUIT con cualquier separador entre dígitos
 * («3%0%7%1…»). Sirve para que la base achique los candidatos; la comparación
 * de verdad es `mismoCuit`. null si no hay dígitos que buscar.
 */
export function patronCuit(cuit: string | null | undefined): string | null {
  const digitos = cuitLimpio(cuit)
  return digitos === '' ? null : `%${digitos.split('').join('%')}%`
}

/** ¿Es el mismo CUIT, sin importar los guiones o espacios? Un CUIT sin dígitos no es igual a nada. */
export function mismoCuit(a: string | null | undefined, b: string | null | undefined): boolean {
  const limpioA = cuitLimpio(a)
  return limpioA !== '' && limpioA === cuitLimpio(b)
}

/** El índice único del server: sucursal + dígitos del CUIT (migración de B2). */
export const INDICE_CUIT_UNICO = 'proveedores_cuit_unico_por_sucursal'

/**
 * ¿Es el rechazo del índice único del CUIT? Un 23505 con el nombre del índice
 * en `message`, `details` o `hint`. Lo que llega cuando dos altas o una edición
 * se saltean la verificación previa del front (una carrera, o editar un
 * proveedor y ponerle el CUIT de otro).
 */
export function esCuitDuplicadoDeBase(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const e = error as { code?: unknown; message?: unknown; details?: unknown; hint?: unknown }
  if (String(e.code ?? '') !== '23505') return false
  return [e.message, e.details, e.hint].some(t => typeof t === 'string' && t.includes(INDICE_CUIT_UNICO))
}

/**
 * El aviso de CUIT repetido, el mismo en el alta, en la edición y cuando lo
 * frena el índice. Con `status = 409` para que el reintento global de las
 * mutations no lo repita: un duplicado no deja de serlo.
 */
export function errorCuitDuplicado(cuit: string | null | undefined, nombreExistente?: string | null): Error {
  const mensaje = nombreExistente
    ? `Ya existe un proveedor con CUIT "${cuit}": ${nombreExistente}`
    : `Ya existe un proveedor con CUIT "${cuit}" en esta sucursal. Buscalo en la lista de proveedores.`
  const error = new Error(mensaje)
  ;(error as Error & { status?: number }).status = 409
  return error
}
