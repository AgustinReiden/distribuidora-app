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

/**
 * ¿Este cambio es un pegado (o algo soltado), y no una tecla? Lo dice el evento nativo
 * (`inputType`, N8 de la segunda pasada de #1644): pegar «1,500» sobre «15.000» seleccionado deja un
 * texto más corto, y medirlo por el largo lo tomaba por tipeo. Sin `inputType` (un `change`
 * sintético), cuenta el largo: más de un carácter de una vez es un pegado.
 */
export function esPegado(e: ChangeEvent<HTMLInputElement>, anterior: string): boolean {
  const tipo = (e.nativeEvent as InputEvent | undefined)?.inputType
  if (tipo) return tipo.startsWith('insertFromPaste') || tipo === 'insertFromDrop'
  return e.target.value.length - anterior.length > 1
}

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
