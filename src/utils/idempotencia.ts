/**
 * UUIDs de idempotencia para escrituras que no se pueden duplicar (pagos).
 *
 * El servidor (mig 167) deduplica por `client_request_id`: si ya vio ese UUID,
 * devuelve el resultado de la primera vez en lugar de volver a escribir. Para
 * que eso sirva, el UUID tiene que ser el MISMO en todos los reintentos del
 * mismo pago y DISTINTO si el usuario cambia el monto o la forma de pago —
 * de eso se encarga `useRequestIdEstable`.
 */

/**
 * `crypto.randomUUID` necesita contexto seguro y no existe en iOS Safari < 15.4.
 * La app corre en el reparto, en teléfonos viejos, así que hay fallback sobre
 * `getRandomValues` (v4 armado a mano) antes de caer en algo no criptográfico.
 */
export function nuevoRequestId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }

  if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40 // versión 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80 // variante RFC 4122
    const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  }

  // Último recurso: no hay crypto. Peor un UUID débil que ninguno — igual solo
  // tiene que ser único dentro de la ventana de reintentos de un pago.
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16)
  })
}
