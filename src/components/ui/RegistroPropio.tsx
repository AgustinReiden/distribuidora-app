/**
 * RegistroPropio - El registro de lo ilegible de un subformulario con su propio guardar, adentro
 * de otro formulario (el «crear producto rápido» de una compra, el alta de un lote en la ficha).
 *
 * Un rojo adentro frena SU botón y no el Guardar de afuera (N7 de la segunda pasada de #1644), y
 * el botón de adentro no guarda el valor de antes (T1 de la tercera pasada: todo botón que guarda
 * mira su registro). `aviso` es el `AvisoCamposEnRojo` del subformulario, para ponerlo al lado de
 * su botón:
 *
 *   <RegistroPropio>
 *     {({ hay, aviso }) => (
 *       <>…campos… {aviso} <Button disabled={hay} onClick={() => { if (!hay) crear() }} /></>
 *     )}
 *   </RegistroPropio>
 */
import type { ReactElement, ReactNode } from 'react'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'
import { AvisoCamposEnRojo } from './AvisoCamposEnRojo'

export function RegistroPropio({ children }: { children: (frenado: { hay: boolean; aviso: ReactNode }) => ReactNode }): ReactElement {
  const ilegibles = useRegistroIlegibles()
  return (
    <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
      {children({ hay: ilegibles.hay, aviso: <AvisoCamposEnRojo className="mb-1" /> })}
    </RegistroIlegiblesContext.Provider>
  )
}

export default RegistroPropio
