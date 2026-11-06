import { useState } from 'react'
import { nuevoRequestId } from '../utils/idempotencia'

/**
 * Devuelve un UUID **estable por intención de escritura**.
 *
 * La regla es: mientras la huella no cambie, todos los intentos reciben el mismo
 * UUID y el servidor los deduplica (mig 167). Si el usuario edita el monto o la
 * forma de pago, la huella cambia, sale un UUID nuevo y eso sí se registra
 * aparte — porque es otro pago, no un reintento.
 *
 * Esto es lo que cubre el agujero real: el botón ya se deshabilita mientras la
 * request está en vuelo, pero si la respuesta se pierde el modal muestra un
 * error, el usuario vuelve a apretar y hoy eso inserta el pago de nuevo (pedido
 * 3602: el mismo pago tres veces en 17 segundos).
 *
 * @example
 * const requestId = useRequestIdEstable()
 * const huella = `${clienteId}|${monto}|${formaPago}|${fecha}`
 * await registrarPago({ ..., clientRequestId: requestId(huella) })
 * // para un pago dividido, un UUID por línea:
 * const ids = lineas.map((_, i) => requestId(`${huella}#${i}`))
 */
export type RequestIdEstable = ((huella: string) => string) & {
  /**
   * El cobro salió bien: sus huellas dejan de tener clave (COB-F-5). Sin esto, un
   * segundo cobro idéntico (mismos pedidos, forma y fecha —p. ej. anular un pago y
   * volver a marcar—) reusa la clave y el server lo toma por replay: el toast dice
   * "pagado" y no se registra nada. Mismo criterio que `olvidarRequestIds` (#1410).
   * Llamarlo sólo ante un éxito: tras un error la clave tiene que sobrevivir.
   */
  olvidar: (huellas: readonly string[]) => void
}

function crearRequestIdEstable(): RequestIdEstable {
  const cache = new Map<string, string>()
  const requestId = (huella: string): string => {
    const existente = cache.get(huella)
    if (existente) return existente
    const id = nuevoRequestId()
    cache.set(huella, id)
    return id
  }
  const olvidar = (huellas: readonly string[]): void => {
    for (const h of huellas) cache.delete(h)
  }
  return Object.assign(requestId, { olvidar })
}

export function useRequestIdEstable(): RequestIdEstable {
  // La cache vive en la closure del estado inicial: una por componente y estable
  // entre renders (la identidad de la función no cambia).
  const [requestId] = useState(crearRequestIdEstable)
  return requestId
}
