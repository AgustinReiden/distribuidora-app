/**
 * Detecta que hay un deploy nuevo mientras la app esta abierta.
 *
 * Una pestania que queda abierta corre el bundle que cargo ese dia, y los
 * `import()` lazy se resuelven contra ESE build. Asi es como la usuaria
 * termino cancelando pedidos en agosto con el modal de texto libre de julio y
 * sin ver los entregados-impagos en Entrega y Pago Masivos.
 *
 * Hay dos formas de enterarse, y usamos las dos porque avisan en momentos
 * distintos:
 *
 * 1. `/version.json`: se compara contra el build id inyectado en el bundle. Se
 *    entera enseguida, aunque el navegador todavia no haya ido a revisar el
 *    service worker.
 * 2. El service worker, cuando termina de bajar el build nuevo y lo deja
 *    esperando. Es el que avisa aunque el chequeo de arriba no haya corrido.
 *
 * La recarga NUNCA es automatica. El aviso es un cartel que ella acepta cuando
 * quiere, porque un reload sorpresa mientras carga un pedido le borra lo
 * tipeado. Y el "Actualizar" pasa por el service worker (ver
 * `aplicarActualizacionSW`): un reload pelado volveria a servir el index.html
 * viejo del precache y el cartel no se iria nunca.
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  aplicarActualizacionSW,
  hayActualizacionSWEsperando,
  suscribirActualizacionSW,
} from '../utils/serviceWorker'

/** Cada cuanto se pregunta, con la pestania visible. */
const INTERVALO_MS = 15 * 60 * 1000
/** Cuanto se calla el cartel cuando eligen "Mas tarde". */
const ESPERA_TRAS_POSPONER_MS = 60 * 60 * 1000

/**
 * Build que corre esta pestania. Se lee como constante (y no llamando al hook)
 * para poder mostrarlo en la UI sin arrancar un segundo ciclo de chequeo.
 */
export const BUILD_ACTUAL: string =
  typeof __APP_BUILD_ID__ === 'string' ? __APP_BUILD_ID__ : 'dev'

export interface ActualizacionDisponible {
  /** Hay un build nuevo publicado y esta pestania corre uno viejo. */
  disponible: boolean
  /** Build que corre esta pestania. Sirve para soporte. */
  buildActual: string
  /** Recarga para tomar el build nuevo. */
  actualizar: () => void
  /** Esconde el cartel por un rato. */
  posponer: () => void
}

export function useActualizacionDisponible(): ActualizacionDisponible {
  const [disponible, setDisponible] = useState(() => hayActualizacionSWEsperando())
  const pospuestoHasta = useRef(0)
  // En dev el bundle lo sirve vite con HMR y no hay version.json que pedir.
  const activo = !import.meta.env.DEV

  const chequear = useCallback(async () => {
    if (!activo) return
    if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return
    if (Date.now() < pospuestoHasta.current) return

    try {
      // El query param + no-store evitan depender de los headers del hosting.
      const res = await fetch(`/version.json?t=${Date.now()}`, { cache: 'no-store' })
      if (!res.ok) return

      const { buildId } = await res.json() as { buildId?: string }
      // Sin red, con un deploy a medio subir o si el hosting devuelve el
      // index.html en vez del json, no molestamos: el silencio es preferible
      // a un cartel que no se puede sacar.
      if (typeof buildId === 'string' && buildId && buildId !== __APP_BUILD_ID__) {
        setDisponible(true)
      }
    } catch {
      /* sin conexion: se reintenta en el proximo ciclo */
    }
  }, [activo])

  useEffect(() => {
    if (!activo) return

    void chequear()

    const alVolver = (): void => {
      if (document.visibilityState === 'visible') void chequear()
    }
    document.addEventListener('visibilitychange', alVolver)
    window.addEventListener('focus', alVolver)

    const id = setInterval(() => { void chequear() }, INTERVALO_MS)

    // El service worker dejo un build nuevo esperando. Respeta el "Mas tarde"
    // igual que el chequeo de /version.json.
    const desuscribir = suscribirActualizacionSW(() => {
      if (Date.now() < pospuestoHasta.current) return
      setDisponible(true)
    })

    return () => {
      document.removeEventListener('visibilitychange', alVolver)
      window.removeEventListener('focus', alVolver)
      clearInterval(id)
      desuscribir()
    }
  }, [activo, chequear])

  const actualizar = useCallback(() => {
    void aplicarActualizacionSW()
  }, [])

  const posponer = useCallback(() => {
    pospuestoHasta.current = Date.now() + ESPERA_TRAS_POSPONER_MS
    setDisponible(false)
  }, [])

  return { disponible, buildActual: BUILD_ACTUAL, actualizar, posponer }
}

export default useActualizacionDisponible
