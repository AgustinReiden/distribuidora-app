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
 * D57 (decision del duenio, 1563-b8 de #1563): la actualizacion es obligatoria.
 * El cartel avisa y el salto llega solo al volver a la app o al cambiar de
 * pantalla (ver `saltarAlBuildNuevo`); ya no hay «Mas tarde». Sigue sin saltar
 * con un modal abierto o un campo en edicion, porque le borraria lo tipeado: lo
 * hace en el proximo cambio de pantalla o vuelta a la app. Y el "Actualizar"
 * pasa por el service worker (ver `aplicarActualizacionSW`): un reload pelado
 * volveria a servir el index.html viejo del precache y el cartel no se iria nunca.
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  aplicarActualizacionSW,
  hayActualizacionSWEsperando,
  suscribirActualizacionSW,
} from '../utils/serviceWorker'
import { saltarAlBuildNuevo, type DisparadorActualizacion } from '../utils/actualizacionObligatoria'
import { hayTrabajoEnCurso } from '../utils/trabajoEnCurso'

/** Cada cuanto se pregunta, con la pestania visible. */
const INTERVALO_MS = 15 * 60 * 1000
/** Ventana tras abrir la app en la que todavia no hay nada que perder. */
const VENTANA_ARRANQUE_MS = 20 * 1000
/** Tope contra un loop de recargas si la actualizacion automatica no prospera. */
const ENFRIAMIENTO_AUTO_MS = 10 * 60 * 1000

const CLAVE_AUTO = 'actualizacion:ultimo-auto'

function leerNumero(clave: string): number {
  try {
    return Number(sessionStorage.getItem(clave)) || 0
  } catch {
    return 0
  }
}

function guardarNumero(clave: string, valor: number): void {
  try {
    sessionStorage.setItem(clave, String(valor))
  } catch {
    /* modo privado o storage bloqueado: el cartel igual funciona */
  }
}

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
  /** Esta saltando al build nuevo (el boton espera, no se repite el toque). */
  actualizando: boolean
  /** Recarga para tomar el build nuevo. */
  actualizar: () => void
  /**
   * Esconde el cartel. No pospone nada (D57): el salto llega igual al volver a
   * la app o al cambiar de pantalla, y el cartel vuelve con el proximo aviso.
   */
  ocultar: () => void
}

/**
 * `ruta` es la pantalla actual (`location.pathname`): cuando cambia, con un build
 * nuevo esperando, se salta (D57). Sin ella, sólo al volver a la app.
 */
export function useActualizacionDisponible(ruta?: string): ActualizacionDisponible {
  const [disponible, setDisponible] = useState(() => hayActualizacionSWEsperando())
  const [actualizando, setActualizando] = useState(false)
  const hayNuevo = useRef(hayActualizacionSWEsperando())
  const escondidaDesde = useRef<number | null>(null)
  // En dev el bundle lo sirve vite con HMR y no hay version.json que pedir.
  const activo = !import.meta.env.DEV

  const actualizar = useCallback(() => {
    setActualizando(true)
    // La recarga la dispara el cambio de controlador un instante despues de que
    // esto resuelva: se mantiene deshabilitado un rato y, si igual no llego
    // (offline, error), se vuelve a habilitar el boton.
    void aplicarActualizacionSW().finally(() => {
      setTimeout(() => setActualizando(false), 15000)
    })
  }, [])

  /** Salta solo si es el momento (D57); si no, queda el cartel. */
  const intentarAuto = useCallback((disparador: DisparadorActualizacion): boolean => {
    if (!hayNuevo.current) return false
    const salta = saltarAlBuildNuevo({
      disparador,
      trabajoEnCurso: hayTrabajoEnCurso(),
      enEnfriamiento: Date.now() - leerNumero(CLAVE_AUTO) < ENFRIAMIENTO_AUTO_MS,
      recienAbierta: performance.now() < VENTANA_ARRANQUE_MS,
    })
    if (!salta) return false
    const autoAnterior = leerNumero(CLAVE_AUTO)
    guardarNumero(CLAVE_AUTO, Date.now())
    setActualizando(true)
    // H1: lo que había en pantalla al dispararse no alcanza. Bajar e instalar
    // el build tarda hasta ~45 s; justo antes de recargar se vuelve a mirar.
    void aplicarActualizacionSW({ puedeRecargar: () => !hayTrabajoEnCurso() })
      .then(resultado => {
        if (resultado !== 'pospuesto') {
          // La recarga la dispara el cambio de controlador: se espera un rato.
          setTimeout(() => setActualizando(false), 15000)
          return
        }
        // No fue un salto que no prosperó: el build quedó listo y el próximo
        // disparo lo activa enseguida, sin enfriamiento. El cartel vuelve a su
        // estado normal (N4): nada se está actualizando, espera a lo que hay en pantalla.
        guardarNumero(CLAVE_AUTO, autoAnterior)
        setActualizando(false)
        setDisponible(true)
      }, () => {
        setTimeout(() => setActualizando(false), 15000)
      })
    return true
  }, [])

  const chequear = useCallback(async (disparador: DisparadorActualizacion) => {
    if (!activo) return
    if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return

    try {
      // El query param + no-store evitan depender de los headers del hosting.
      const res = await fetch(`/version.json?t=${Date.now()}`, { cache: 'no-store' })
      if (!res.ok) return

      const { buildId } = await res.json() as { buildId?: string }
      // Sin red, con un deploy a medio subir o si el hosting devuelve el
      // index.html en vez del json, no molestamos: el silencio es preferible
      // a un cartel que no se puede sacar.
      if (typeof buildId === 'string' && buildId && buildId !== __APP_BUILD_ID__) {
        hayNuevo.current = true
        if (!intentarAuto(disparador)) setDisponible(true)
      }
    } catch {
      /* sin conexion: se reintenta en el proximo ciclo */
    }
  }, [activo, intentarAuto])

  useEffect(() => {
    if (!activo) return

    void chequear('aviso')

    const alVolver = (): void => {
      if (document.visibilityState === 'hidden') {
        escondidaDesde.current ??= Date.now()
        return
      }
      if (document.visibilityState !== 'visible') return
      // Volvio a la app si estuvo escondida; un `focus` sin eso (otra ventana
      // encima) sólo pregunta.
      const disparador: DisparadorActualizacion = escondidaDesde.current === null ? 'aviso' : 'volver'
      escondidaDesde.current = null
      // Si salta sola no hace falta mostrar nada.
      if (intentarAuto(disparador)) return
      void chequear(disparador)
    }
    document.addEventListener('visibilitychange', alVolver)
    window.addEventListener('focus', alVolver)

    const id = setInterval(() => { void chequear('aviso') }, INTERVALO_MS)

    // El service worker dejo un build nuevo esperando.
    const desuscribir = suscribirActualizacionSW(() => {
      hayNuevo.current = true
      if (!intentarAuto('aviso')) setDisponible(true)
    })

    return () => {
      document.removeEventListener('visibilitychange', alVolver)
      window.removeEventListener('focus', alVolver)
      clearInterval(id)
      desuscribir()
    }
  }, [activo, chequear, intentarAuto])

  // D57: cambiar de pantalla con un build nuevo esperando lo aplica. La primera
  // ruta no cuenta: es la de la apertura, que ya miró el chequeo del arranque.
  const rutaAnterior = useRef(ruta)
  useEffect(() => {
    if (!activo || ruta === undefined || ruta === rutaAnterior.current) return
    rutaAnterior.current = ruta
    intentarAuto('pantalla')
  }, [activo, ruta, intentarAuto])

  const ocultar = useCallback(() => {
    setDisponible(false)
  }, [])

  return { disponible, buildActual: BUILD_ACTUAL, actualizando, actualizar, ocultar }
}

export default useActualizacionDisponible
