import { useMemo, useState } from 'react'

export const FILAS_POR_PAGINA = 20

/**
 * Paginación en el cliente sobre una lista que ya está completa en memoria.
 *
 * `resetKey` vuelve a la página 1 cuando cambia (un filtro, una búsqueda): se
 * detecta durante el render, que es como React pide ajustar estado a partir de
 * una entrada sin pasar por un efecto. La página se recorta al rango válido,
 * así que si la lista se achica no queda una página vacía sin control para volver.
 */
export function usePaginado<T>(items: readonly T[], resetKey: string = '', porPagina: number = FILAS_POR_PAGINA) {
  const [paginaActual, setPaginaActual] = useState(1)
  const [claveVista, setClaveVista] = useState(resetKey)
  if (claveVista !== resetKey) {
    setClaveVista(resetKey)
    setPaginaActual(1)
  }

  const totalPaginas = Math.ceil(items.length / porPagina)
  const pagina = Math.min(paginaActual, Math.max(1, totalPaginas))
  const visibles = useMemo(() => {
    const inicio = (pagina - 1) * porPagina
    return items.slice(inicio, inicio + porPagina)
  }, [items, pagina, porPagina])

  return { visibles, pagina, totalPaginas, setPagina: setPaginaActual, inicio: (pagina - 1) * porPagina }
}
