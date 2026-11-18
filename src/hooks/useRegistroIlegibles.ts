/**
 * El registro de los campos de número que no se entienden (B20, revisión de la lente: «lo que está
 * en rojo no se guarda»).
 *
 * Un formulario crea su registro y lo pone alrededor de sus campos:
 *
 *   const ilegibles = useRegistroIlegibles()
 *   <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
 *     …campos…
 *     <AvisoCamposEnRojo />
 *     <Button disabled={guardando || ilegibles.hay} onClick={guardar}>Guardar</Button>
 *   </RegistroIlegiblesContext.Provider>
 *
 * `NumberInput`, `CampoNumero` e `InputMonto` se anotan solos mientras están en rojo
 * (`useAnotarIlegible`). Con un registro alrededor, un `NumberInput` en rojo se queda en rojo al
 * salir (no vuelve al valor de antes), porque el formulario no deja guardar mientras haya uno.
 * El que guarda además corta con `if (ilegibles.hay) return`.
 *
 * Cada formulario tiene SU registro: un subformulario con su propio guardar (los lotes de la ficha)
 * pone el suyo, para que su rojo no frene el Guardar de afuera (N7 de la segunda pasada).
 *
 * `AvisoCamposEnRojo`, al lado del Guardar, dice cuántos hay y lleva al primero (N4): lo busca en
 * el orden de la pantalla, abre la sección que lo tiene si está cerrada (`AbrirSeccionContext`,
 * como el carrito del alta) y le pone el foco.
 */
import { createContext, useContext, useEffect, useId, useMemo, useSyncExternalStore, type RefObject } from 'react'

/** Lo que hace falta para llevar al usuario a un campo en rojo. */
interface CampoAnotado {
  elemento: () => HTMLElement | null
  /** Abre la sección que lo contiene, si está cerrada (el carrito del alta). */
  abrir: (() => void) | null
}

export interface RegistroIlegibles {
  /** Anota (con su motivo) o borra (null) un campo. */
  marcar: (id: string, motivo: string | null, campo?: CampoAnotado) => void
  /** Los motivos de los campos que hoy están en rojo. */
  motivos: () => string[]
  suscribir: (aviso: () => void) => () => void
  /** Lleva al primer campo en rojo (en el orden de la pantalla). Devuelve si encontró uno. */
  irAlPrimero: () => boolean
}

function crearRegistro(): RegistroIlegibles {
  const campos = new Map<string, string>()
  const dondeEstan = new Map<string, CampoAnotado>()
  const avisos = new Set<() => void>()
  let foto: string[] = []
  return {
    marcar(id, motivo, campo) {
      if (motivo !== null && campo) dondeEstan.set(id, campo)
      if (motivo === null) dondeEstan.delete(id)
      if (motivo === null ? !campos.has(id) : campos.get(id) === motivo) return
      if (motivo === null) campos.delete(id)
      else campos.set(id, motivo)
      foto = [...campos.values()]
      avisos.forEach(a => a())
    },
    motivos: () => foto,
    suscribir(aviso) {
      avisos.add(aviso)
      return () => { avisos.delete(aviso) }
    },
    irAlPrimero() {
      const conElemento = [...dondeEstan.entries()]
        .filter(([id]) => campos.has(id))
        .map(([, c]) => ({ c, el: c.elemento() }))
        .filter((x): x is { c: CampoAnotado; el: HTMLElement } => x.el !== null && x.el.isConnected)
      if (conElemento.length === 0) return false
      conElemento.sort((a, b) => (a.el.compareDocumentPosition(b.el) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1))
      const { c, el } = conElemento[0]
      c.abrir?.()
      // Después de abrir la sección (un render), el campo ya se ve: se lo trae a la vista y se enfoca.
      setTimeout(() => {
        // Un `<details>` cerrado (las opciones avanzadas del grupo de precio) esconde el campo y no
        // lo deja tomar el foco: se abre (T5 de la tercera pasada).
        for (let d = el.closest('details'); d; d = d.parentElement?.closest('details') ?? null) d.open = true
        el.scrollIntoView?.({ block: 'center', behavior: 'smooth' })
        el.focus({ preventScroll: true })
      }, 0)
      return true
    },
  }
}

export const RegistroIlegiblesContext = createContext<RegistroIlegibles | null>(null)

/**
 * La sección que se puede cerrar con campos adentro (el carrito del alta) dice cómo abrirse: el
 * aviso de los campos en rojo la abre para llevar al usuario al primero.
 */
export const AbrirSeccionContext = createContext<(() => void) | null>(null)

/** El registro de un formulario: `hay` es true mientras algún campo de adentro esté en rojo. */
export function useRegistroIlegibles(): { registro: RegistroIlegibles; hay: boolean; motivos: string[] } {
  const registro = useMemo(() => crearRegistro(), [])
  const motivos = useSyncExternalStore(registro.suscribir, registro.motivos, registro.motivos)
  return { registro, hay: motivos.length > 0, motivos }
}

/** Lo que muestra el aviso de los campos en rojo del registro de alrededor. */
export function useCamposEnRojo(): { motivos: string[]; irAlPrimero: () => boolean } | null {
  const registro = useContext(RegistroIlegiblesContext)
  const vacio = useMemo(() => ({ suscribir: () => () => {}, motivos: () => [] as string[] }), [])
  const fuente = registro ?? vacio
  const motivos = useSyncExternalStore(fuente.suscribir, fuente.motivos, fuente.motivos)
  if (!registro) return null
  return { motivos, irAlPrimero: registro.irAlPrimero }
}

/**
 * Para un campo: lo anota en el registro del formulario mientras `motivo` no sea null. Devuelve si
 * hay un registro alrededor. `elemento` es el input, para que el aviso pueda llevar al usuario.
 */
export function useAnotarIlegible(motivo: string | null, elemento?: RefObject<HTMLElement | null>): boolean {
  const registro = useContext(RegistroIlegiblesContext)
  const abrir = useContext(AbrirSeccionContext)
  const id = useId()
  useEffect(() => {
    if (!registro) return
    registro.marcar(id, motivo, { elemento: () => elemento?.current ?? null, abrir })
  }, [registro, id, motivo, elemento, abrir])
  useEffect(() => () => { registro?.marcar(id, null) }, [registro, id])
  return registro !== null
}
