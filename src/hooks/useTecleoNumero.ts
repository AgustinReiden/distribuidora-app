/**
 * Para un campo de texto con un número (D17, #1560): devuelve la función del `onChange`, que pone
 * los miles mientras se tipea y escribe la tecla del punto como coma (`formatearTecleo`), y repone
 * el cursor después del mismo dígito cuando entra o sale un punto de miles.
 *
 *   const tecleo = useTecleoNumero()
 *   <input type="text" inputMode="decimal" value={texto}
 *     onChange={e => setTexto(tecleo(texto, e))} />
 *
 * El primer argumento es lo que el campo mostraba antes de la tecla. Sirve para varios campos del
 * mismo componente: se tipea en uno a la vez. La precarga va con `numeroConMiles`.
 */
import { useCallback, useLayoutEffect, useRef, type ChangeEvent } from 'react'
import { formatearTecleo, type OpcionesTecleo } from '../utils/normalizarNumero'

export function useTecleoNumero(
  opciones: Pick<OpcionesTecleo, 'negativo'> = {},
): (anterior: string, e: ChangeEvent<HTMLInputElement>) => string {
  const pendiente = useRef<{ input: HTMLInputElement; cursor: number } | null>(null)
  useLayoutEffect(() => {
    const p = pendiente.current
    pendiente.current = null
    if (p && document.activeElement === p.input) p.input.setSelectionRange(p.cursor, p.cursor)
  })
  const negativo = opciones.negativo ?? false
  return useCallback((anterior: string, e: ChangeEvent<HTMLInputElement>): string => {
    const crudo = e.target.value
    const direccion = (e.nativeEvent as InputEvent).inputType === 'deleteContentForward' ? 'adelante' : 'atras'
    const r = formatearTecleo(anterior, crudo, e.target.selectionStart ?? crudo.length, { direccion, negativo })
    pendiente.current = { input: e.target, cursor: r.cursor }
    return r.texto
  }, [negativo])
}
