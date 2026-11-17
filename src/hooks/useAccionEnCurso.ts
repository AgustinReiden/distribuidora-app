import { useCallback, useRef, useState } from 'react'

/**
 * Una acción que espera la red antes de mostrar nada (releer una lista, traer los combos):
 * mientras corre se sabe que está en curso, para avisarlo en pantalla, y un segundo toque
 * se ignora en vez de repetirla (#1630, H5).
 */
export function useAccionEnCurso() {
  const [enCurso, setEnCurso] = useState(false)
  const corriendo = useRef(false)

  const correr = useCallback(async <T,>(accion: () => Promise<T>): Promise<T | undefined> => {
    if (corriendo.current) return undefined
    corriendo.current = true
    setEnCurso(true)
    try {
      return await accion()
    } finally {
      corriendo.current = false
      setEnCurso(false)
    }
  }, [])

  return { enCurso, correr }
}
