/**
 * El borrador local de la compra nueva: cuándo se escribe, cuándo se ofrece y
 * cuándo se borra. El formato y el acceso a localStorage viven en
 * utils/borradorCompra; acá sólo el ciclo de vida.
 *
 * Reglas, en orden de importancia:
 *  1. Nunca se descarta en silencio. Si al abrir hay un borrador, el autosave
 *     queda APAGADO hasta que el usuario elija retomarlo o descartarlo: si no,
 *     el estado vacío del modal recién abierto lo pisaría en el primer tick.
 *  2. Registrar la compra cancela el autosave pendiente y borra el borrador. Si
 *     el debounce sobreviviera al guardado, la compra registrada volvería a
 *     ofrecerse como borrador y se podría registrar dos veces.
 *  3. Al desmontar se escribe lo pendiente. El cambio de sucursal cierra el
 *     modal (useResetOnSucursalChange en ComprasContainer) y sin esto se
 *     perdería lo tipeado en el último segundo. La clave la congela el que
 *     llama al montar: si se recalculara, el flush del desmontaje caería en la
 *     sucursal NUEVA.
 *  4. Otra pestaña con la misma clave avisa (evento `storage`): dos pestañas
 *     cargando la misma compra se pisan el borrador, y si la otra la registró,
 *     registrar ésta la duplica.
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import type { CompraState } from '../components/modals/ModalCompra.reducer'
import { compraTieneCambios } from '../utils/compraTieneCambios'
import {
  leerBorrador, serializarBorrador, estadoDesdeBorrador,
  leerStorage, escribirStorage, borrarStorage,
} from '../utils/borradorCompra'
import type { LecturaBorrador } from '../utils/borradorCompra'

/** Lo que pasó con el borrador en otra pestaña. */
export type CambioEnOtraPestana = 'modificado' | 'borrado' | null

export interface BorradorCompraApi {
  /** Lo que había al abrir y espera decisión. `ninguno` = nada pendiente. */
  pendiente: LecturaBorrador;
  /** Devuelve el estado a hidratar (o null si no había uno legible) y prende el autosave. */
  retomar: () => CompraState | null;
  /** Borra lo pendiente y prende el autosave. */
  descartarPendiente: () => void;
  /** Llamar después de registrar la compra: corta el autosave y borra el borrador. */
  finalizar: () => void;
  otraPestana: CambioEnOtraPestana;
  cerrarAvisoOtraPestana: () => void;
}

export const DEMORA_AUTOSAVE_MS = 800

export function useBorradorCompra(
  clave: string | null,
  state: CompraState,
  demoraMs: number = DEMORA_AUTOSAVE_MS,
): BorradorCompraApi {
  const [pendiente, setPendiente] = useState<LecturaBorrador>(
    () => (clave ? leerBorrador(leerStorage(clave)) : { tipo: 'ninguno' })
  )
  const [otraPestana, setOtraPestana] = useState<CambioEnOtraPestana>(null)

  const habilitado = clave !== null && pendiente.tipo === 'ninguno'

  const estadoRef = useRef(state)
  const habilitadoRef = useRef(habilitado)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  /** Lo último que ESTA pestaña escribió (para no avisarse a sí misma y saber qué es propio). */
  const escritoRef = useRef<string | null>(null)
  /** Compra registrada: no se escribe nunca más. */
  const finalizadoRef = useRef(false)

  useEffect(() => {
    estadoRef.current = state
    habilitadoRef.current = habilitado
  })

  const cancelarTimer = () => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
  }

  const escribirAhora = useCallback(() => {
    cancelarTimer()
    if (!clave || finalizadoRef.current || !habilitadoRef.current) return
    const s = estadoRef.current
    if (!compraTieneCambios(s)) {
      // Sólo se borra lo propio: una compra vacía recién abierta no puede
      // llevarse puesto el borrador que otra pestaña acaba de escribir.
      if (escritoRef.current !== null) {
        borrarStorage(clave)
        escritoRef.current = null
      }
      return
    }
    const valor = serializarBorrador(s, new Date())
    if (escribirStorage(clave, valor)) escritoRef.current = valor
  }, [clave])

  // Autosave con debounce.
  useEffect(() => {
    if (!habilitado) return
    cancelarTimer()
    timerRef.current = setTimeout(escribirAhora, demoraMs)
  }, [state, habilitado, demoraMs, escribirAhora])

  // Flush al desmontar y al irse de la página.
  useEffect(() => {
    const alIrse = () => { if (timerRef.current !== null) escribirAhora() }
    window.addEventListener('pagehide', alIrse)
    return () => {
      window.removeEventListener('pagehide', alIrse)
      alIrse()
    }
  }, [escribirAhora])

  // Otra pestaña tocó la misma clave.
  useEffect(() => {
    if (!clave) return
    const alCambiar = (e: StorageEvent) => {
      if (e.key !== clave || finalizadoRef.current) return
      if (e.newValue !== null && e.newValue === escritoRef.current) return
      if (!habilitadoRef.current) {
        // Todavía se está decidiendo qué hacer con el de al abrir: se ofrece
        // el que hay ahora, no uno que ya no existe.
        setPendiente(leerBorrador(e.newValue))
        return
      }
      setOtraPestana(e.newValue === null ? 'borrado' : 'modificado')
    }
    window.addEventListener('storage', alCambiar)
    return () => window.removeEventListener('storage', alCambiar)
  }, [clave])

  const retomar = useCallback((): CompraState | null => {
    if (pendiente.tipo !== 'ok') return null
    // Lo retomado pasa a ser propio: si después se vacía la compra, se borra.
    escritoRef.current = clave ? leerStorage(clave) : null
    setPendiente({ tipo: 'ninguno' })
    return estadoDesdeBorrador(pendiente.borrador)
  }, [pendiente, clave])

  const descartarPendiente = useCallback(() => {
    if (clave) borrarStorage(clave)
    escritoRef.current = null
    setPendiente({ tipo: 'ninguno' })
  }, [clave])

  const finalizar = useCallback(() => {
    finalizadoRef.current = true
    cancelarTimer()
    if (clave) borrarStorage(clave)
    escritoRef.current = null
  }, [clave])

  const cerrarAvisoOtraPestana = useCallback(() => setOtraPestana(null), [])

  return { pendiente, retomar, descartarPendiente, finalizar, otraPestana, cerrarAvisoOtraPestana }
}
