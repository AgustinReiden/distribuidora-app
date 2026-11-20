import { useEffect, useRef } from 'react'
import { registrarAtrasModal } from '../utils/atrasModales'

/**
 * El «atrás» del teléfono cierra esta ventana mientras está abierta (decisión 4 del dueño, #1603; la
 * mecánica está en `utils/atrasModales`). `pedirCierre` es lo mismo que haría la X o Escape: cerrar, o
 * preguntar «¿Salir sin guardar?» si hay datos. Con `activo` en false no se anota (la ventana está cerrada).
 *
 * LATENTE (N4 de la revisión de C7, sin camino real hoy): si con la ventana abierta se navega a otra ruta (un
 * `Link` o un `navigate()` dentro de la ventana), su entrada queda en el medio del historial. El primer «atrás»
 * desde la pantalla nueva vuelve bien, pero el siguiente no hace nada, y si ahí se abre otra ventana con la
 * misma profundidad, el primer «atrás» no la cierra (la marca vieja se toma por un «adelante»). Los `navigate()`
 * de la app salen de pantallas que no son ventanas. Quien ponga un `Link` o un `navigate()` DENTRO de una
 * ventana tiene que cerrarla antes o marcar las entradas con un id de sesión (ver `utils/atrasModales.ts`).
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
