/**
 * Mientras `activo` sea true, la pantalla declara trabajo en curso: la
 * actualización obligatoria (D57) no recarga encima. Ver `utils/trabajoEnCurso`.
 */
import { useEffect } from 'react'
import { marcarTrabajoEnCurso } from '../utils/trabajoEnCurso'

export function useTrabajoEnCurso(activo: boolean, motivo: string): void {
  useEffect(() => {
    if (!activo) return
    return marcarTrabajoEnCurso(motivo)
  }, [activo, motivo])
}

export default useTrabajoEnCurso
