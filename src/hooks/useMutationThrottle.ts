/**
 * Hook para prevenir doble-submit en mutaciones
 *
 * Ignora llamadas que ocurren dentro de la ventana de throttle
 * después de la primera ejecución exitosa.
 */
import { useRef, useState, useCallback } from 'react'

interface UseMutationThrottleReturn<TArgs extends unknown[], TResult> {
  /** Función throttled — ignora calls duplicados dentro de la ventana */
  throttledFn: (...args: TArgs) => Promise<TResult | undefined>
  /** Si la función fue throttled recientemente */
  isThrottled: boolean
}

export function useMutationThrottle<TArgs extends unknown[], TResult>(
  mutationFn: (...args: TArgs) => Promise<TResult>,
  throttleMs = 2000
): UseMutationThrottleReturn<TArgs, TResult> {
  const lastCallRef = useRef(0)
  const [isThrottled, setIsThrottled] = useState(false)

  const throttledFn = useCallback(
    async (...args: TArgs): Promise<TResult | undefined> => {
      const now = Date.now()
      if (now - lastCallRef.current < throttleMs) {
        return undefined
      }
      lastCallRef.current = now
      setIsThrottled(true)
      try {
        return await mutationFn(...args)
      } finally {
        setTimeout(() => setIsThrottled(false), throttleMs)
      }
    },
    [mutationFn, throttleMs]
  )

  return { throttledFn, isThrottled }
}
