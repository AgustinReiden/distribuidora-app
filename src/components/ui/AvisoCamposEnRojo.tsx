/**
 * AvisoCamposEnRojo - Al lado del Guardar que frena el registro de lo ilegible (N4 de la segunda
 * pasada de #1644): dice cuántos campos en rojo hay y lleva al primero (lo trae a la vista, abre la
 * sección si está cerrada y le pone el foco). Sin campos en rojo no muestra nada.
 *
 * Va adentro del `RegistroIlegiblesContext.Provider` del formulario, junto al botón:
 *
 *   <AvisoCamposEnRojo />
 *   <Button disabled={… || ilegibles.hay}>Guardar</Button>
 *
 * Es una sola pieza para todos los formularios: el texto no cambia por formulario.
 */
import type { ReactElement } from 'react'
import { useCamposEnRojo } from '../../hooks/useRegistroIlegibles'

function textoCamposEnRojo(n: number): string {
  return n === 1 ? 'Hay un campo en rojo para corregir' : `Hay ${n} campos en rojo para corregir`
}

export function AvisoCamposEnRojo({ className = '' }: { className?: string }): ReactElement | null {
  const campos = useCamposEnRojo()
  if (!campos || campos.motivos.length === 0) return null
  return (
    <p role="status" className={`flex flex-wrap items-center gap-x-2 text-xs font-medium text-red-700 dark:text-red-300 ${className}`}>
      <span>{textoCamposEnRojo(campos.motivos.length)}</span>
      <button
        type="button"
        onClick={() => { campos.irAlPrimero() }}
        className="underline underline-offset-2 hover:text-red-800 dark:hover:text-red-200"
      >
        Ir al campo
      </button>
    </p>
  )
}

export default AvisoCamposEnRojo
