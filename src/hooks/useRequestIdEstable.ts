import { useCallback, useRef } from 'react'
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
export function useRequestIdEstable(): (huella: string) => string {
  const cache = useRef<Map<string, string>>(new Map())

  return useCallback((huella: string): string => {
    const existente = cache.current.get(huella)
    if (existente) return existente
    const id = nuevoRequestId()
    cache.current.set(huella, id)
    return id
  }, [])
}
