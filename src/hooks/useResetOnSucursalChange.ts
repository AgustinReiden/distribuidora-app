import { useEffect, useRef } from 'react'
import { useSucursal } from '../contexts/SucursalContext'

/**
 * Dispara `reset` cuando cambia la sucursal activa.
 *
 * Util para cerrar modales y limpiar estado local que no es TanStack Query
 * (que el `SucursalContext` ya invalida globalmente). No se dispara en el
 * mount inicial: solo cuando `currentSucursalId` transita de un id a otro.
 */
export function useResetOnSucursalChange(reset: () => void): void {
  const { currentSucursalId } = useSucursal()
  const prevRef = useRef<number | null>(null)
  useEffect(() => {
    if (prevRef.current !== null && prevRef.current !== currentSucursalId) {
      reset()
    }
    prevRef.current = currentSucursalId
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentSucursalId])
}
