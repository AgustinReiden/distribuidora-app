import { useCallback, useMemo, useRef } from 'react'
import { olvidarRequestIds, requestIdPersistente } from '../utils/requestIdPersistente'

/**
 * La clave de idempotencia de un cobro, estable por huella como la de
 * `useRequestIdEstable`, pero que además sobrevive a cerrar el modal y a una
 * recarga (#1410, `utils/requestIdPersistente`).
 *
 * Mientras el modal está abierto, la clave que ya tiene la conserva en memoria:
 * no depende de que el almacenamiento la siga teniendo (pudo vencer sin
 * reintentos, pisarla otra pestaña o caerse por el tope). El almacenamiento es
 * para reabrir y para recargar.
 *
 * @example
 * const { requestId, olvidar } = useRequestIdPersistente()
 * await registrarPago({ ..., clientRequestId: requestId(huella) })
 * olvidar([huella]) // salió bien: el mismo pago otra vez es otro pago
 */
export function useRequestIdPersistente(): {
  requestId: (huella: string) => string
  olvidar: (huellas: readonly string[]) => void
} {
  const enMemoria = useRef<Map<string, string>>(new Map())

  const requestId = useCallback((huella: string): string => {
    const id = requestIdPersistente(huella, Date.now(), enMemoria.current.get(huella))
    enMemoria.current.set(huella, id)
    return id
  }, [])

  const olvidar = useCallback((huellas: readonly string[]): void => {
    for (const h of huellas) enMemoria.current.delete(h)
    olvidarRequestIds(huellas)
  }, [])

  return useMemo(() => ({ requestId, olvidar }), [requestId, olvidar])
}
