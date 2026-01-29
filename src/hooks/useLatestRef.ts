/**
 * useLatestRef
 *
 * Hook de utilidad para mantener una referencia actualizada a un valor.
 * Útil para evitar dependencias innecesarias en useCallback/useMemo.
 *
 * Uso:
 * ```typescript
 * const valueRef = useLatestRef(value)
 * const handler = useCallback(() => {
 *   // Usar valueRef.current en lugar de value
 *   console.log(valueRef.current)
 * }, [valueRef]) // Dependencia estable del ref
 * ```
 *
 * Ventajas:
 * - La referencia del objeto MutableRefObject nunca cambia
 * - El valor .current siempre está actualizado
 * - Reduce dependencias en useCallback de 15+ a refs estables
 */
import { useRef, useEffect, MutableRefObject } from 'react'

/**
 * Mantiene una referencia actualizada al valor más reciente.
 * No causa re-renders cuando el valor cambia.
 *
 * @param value El valor a mantener como referencia
 * @returns Un MutableRefObject que siempre tiene el valor más reciente
 */
export function useLatestRef<T>(value: T): MutableRefObject<T> {
  const ref = useRef<T>(value)

  // Actualizar ref después del render
  useEffect(() => {
    ref.current = value
  })

  return ref
}

export default useLatestRef
