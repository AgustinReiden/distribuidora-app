/**
 * Claves estables para los renglones de una lista que se agrega y se quita (T6 de la tercera pasada
 * de #1644). Con `key={index}`, quitar un renglón le pasaba al de abajo el borrador del que se fue
 * (un campo en rojo cambiaba de renglón) y desfasaba lo que se guarda por índice (qué renglón está
 * en rojo).
 *
 *   const claves = useClavesDeRenglones(lineas.length)
 *   agregar: setLineas([...lineas, nueva]); claves.agregar()
 *   quitar:  setLineas(lineas.filter((_, j) => j !== i)); claves.quitar(i)
 *   <div key={claves.de(i)}>…</div>
 *
 * Si la lista cambia de largo por otro camino (un reinicio, una carga), las claves se rehacen: los
 * renglones se vuelven a montar, que es lo correcto para una lista nueva.
 */
import { useRef, useState } from 'react'

export function useClavesDeRenglones(largo: number): {
  de: (i: number) => number
  agregar: () => void
  quitar: (i: number) => void
} {
  const [claves, setClaves] = useState<number[]>(() => Array.from({ length: largo }, (_, i) => i))
  const proxima = useRef(largo)
  const vigentes = claves.length === largo ? claves : Array.from({ length: largo }, (_, i) => -1 - i)
  return {
    de: i => vigentes[i] ?? -1 - i,
    agregar: () => setClaves([...vigentes, proxima.current++]),
    quitar: i => setClaves(vigentes.filter((_, j) => j !== i)),
  }
}

export default useClavesDeRenglones
