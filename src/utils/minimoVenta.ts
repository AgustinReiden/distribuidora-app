/**
 * Límite de la cantidad mínima de venta de un producto: la base lo hace cumplir con un
 * CHECK (`cantidad_minima_venta` > 0 y hasta 100.000). El formulario lo valida antes,
 * para que nadie llegue al error crudo de la base.
 */
export const CANTIDAD_MINIMA_VENTA_MAXIMA = 100_000

/** El texto del tope, igual en todos los formularios. */
export const MENSAJE_MINIMO_VENTA_MAXIMO =
  'El mínimo de venta no puede superar las 100.000 unidades. Dejalo vacío si no hay mínimo.'

/**
 * Error de un mínimo de venta tipeado, o null si se puede guardar. Vacío, null y 0 significan
 * «sin mínimo» (el formulario los manda como null): no son error.
 */
export function errorDeMinimoVenta(cantidad: number | null | undefined): string | null {
  if (cantidad == null || cantidad === 0) return null
  if (!Number.isFinite(cantidad)) return 'El mínimo de venta debe ser un número'
  if (!Number.isInteger(cantidad)) return 'El mínimo de venta debe ser un número entero'
  if (cantidad < 0) return 'El mínimo de venta no puede ser negativo'
  if (cantidad > CANTIDAD_MINIMA_VENTA_MAXIMA) return MENSAJE_MINIMO_VENTA_MAXIMO
  return null
}
