import { useEffect, useRef, useState } from 'react'

/**
 * ¿El formulario cambió respecto de como abrió? Para las ventanas cuyo formulario son varios `useState` sueltos
 * (gasto, empleado): se pasa un objeto con lo que el usuario puede tocar y se compara con su foto de la
 * apertura. La foto se saca un instante después de montar (`setTimeout 0`), cuando los valores que se
 * completan solos al abrir ya están puestos: sólo cuenta lo que cambia a mano después. Antes de la foto,
 * nunca hay cambios.
 */
export function useCambiosDesdeApertura(valor: unknown): boolean {
  const ahora = JSON.stringify(valor)
  const ultimo = useRef(ahora)
  const [foto, setFoto] = useState<string | null>(null)
  useEffect(() => {
    ultimo.current = ahora
  })
  useEffect(() => {
    const t = setTimeout(() => setFoto(ultimo.current), 0)
    return () => clearTimeout(t)
  }, [])
  return foto !== null && foto !== ahora
}
