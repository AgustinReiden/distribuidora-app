import { useEffect, useRef } from 'react'
import { registrarAtrasModal } from '../utils/atrasModales'

/**
 * El «atrás» del teléfono cierra esta ventana mientras está abierta (decisión 4 del dueño, #1603; la
 * mecánica está en `utils/atrasModales`). `pedirCierre` es lo mismo que haría la X o Escape: cerrar, o
 * preguntar «¿Salir sin guardar?» si hay datos. Con `activo` en false no se anota (la ventana está cerrada).
 */
export function useAtrasCierraModal(pedirCierre: () => void, activo = true): void {
  // Siempre el último: el «atrás» llama al cierre de HOY, no al del render en que se abrió.
  const ultimo = useRef(pedirCierre)
  useEffect(() => {
    ultimo.current = pedirCierre
  })
  useEffect(() => {
    if (!activo) return
    return registrarAtrasModal(() => ultimo.current())
  }, [activo])
}
