/**
 * El registro de los campos de número que no se entienden (B20, revisión de la lente: «lo que está
 * en rojo no se guarda»).
 *
 * Un formulario crea su registro y lo pone alrededor de sus campos:
 *
 *   const ilegibles = useRegistroIlegibles()
 *   <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
 *     …campos…
 *     <Button disabled={guardando || ilegibles.hay} onClick={guardar}>Guardar</Button>
 *   </RegistroIlegiblesContext.Provider>
 *
 * `NumberInput`, `CampoNumero` e `InputMonto` se anotan solos mientras están en rojo
 * (`useAnotarIlegible`). Con un registro alrededor, un `NumberInput` en rojo se queda en rojo al
 * salir (no vuelve al valor de antes), porque el formulario no deja guardar mientras haya uno.
 * El que guarda además corta con `if (ilegibles.hay) return`.
 */
import { createContext, useContext, useEffect, useId, useMemo, useSyncExternalStore } from 'react'

export interface RegistroIlegibles {
  /** Anota (con su motivo) o borra (null) un campo. */
  marcar: (id: string, motivo: string | null) => void
  /** Los motivos de los campos que hoy están en rojo. */
  motivos: () => string[]
  suscribir: (aviso: () => void) => () => void
}

function crearRegistro(): RegistroIlegibles {
  const campos = new Map<string, string>()
  const avisos = new Set<() => void>()
  let foto: string[] = []
  return {
    marcar(id, motivo) {
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
  }
}

export const RegistroIlegiblesContext = createContext<RegistroIlegibles | null>(null)

/** El registro de un formulario: `hay` es true mientras algún campo de adentro esté en rojo. */
export function useRegistroIlegibles(): { registro: RegistroIlegibles; hay: boolean; motivos: string[] } {
  const registro = useMemo(() => crearRegistro(), [])
  const motivos = useSyncExternalStore(registro.suscribir, registro.motivos, registro.motivos)
  return { registro, hay: motivos.length > 0, motivos }
}

/**
 * Para un campo: lo anota en el registro del formulario mientras `motivo` no sea null. Devuelve si
 * hay un registro alrededor.
 */
export function useAnotarIlegible(motivo: string | null): boolean {
  const registro = useContext(RegistroIlegiblesContext)
  const id = useId()
  useEffect(() => {
    if (!registro) return
    registro.marcar(id, motivo)
  }, [registro, id, motivo])
  useEffect(() => () => { registro?.marcar(id, null) }, [registro, id])
  return registro !== null
}
