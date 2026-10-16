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
 * La recarga solo es automatica cuando no hay NADA que perder (ver
 * `puedeAplicarSinPreguntar`): recien abierta la app, o al volver a una pestania
 * que estuvo abandonada un buen rato, sin un modal abierto ni un campo en
 * edicion. En cualquier otro momento decide ella con el cartel, porque un
 * reload sorpresa mientras carga un pedido le borra lo tipeado. Antes el cartel
 * era la unica via y reaparecia en cada apertura de la app mientras hubiera un
 * SW esperando, aunque ya corriera el build nuevo. Y el "Actualizar" pasa por
 * el service worker (ver `aplicarActualizacionSW`): un reload pelado volveria a
 * servir el index.html viejo del precache y el cartel no se iria nunca.
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
const ESPERA_TRAS_POSPONER_MS = 4 * 60 * 60 * 1000
/** Ventana tras abrir la app en la que todavia no hay nada que perder. */
const VENTANA_ARRANQUE_MS = 20 * 1000
/** Pestania escondida al menos esto = abandonada: al volver se actualiza sola. */
const AUSENCIA_LARGA_MS = 30 * 60 * 1000
/** Tope contra un loop de recargas si la actualizacion automatica no prospera. */
const ENFRIAMIENTO_AUTO_MS = 10 * 60 * 1000

const CLAVE_POSPUESTO = 'actualizacion:pospuesto-hasta'
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

/** Hay un modal abierto o un campo en edicion: recargar le borraria algo. */
function hayTrabajoEnCurso(): boolean {
  if (typeof document === 'undefined') return false
  if (document.querySelector('[role="dialog"], [role="alertdialog"]')) return true
  const el = document.activeElement as HTMLElement | null
  if (!el) return false
  return el.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)
}

/**
 * Se puede saltar al build nuevo sin preguntar: nada en curso y, ademas, o la
 * app acaba de abrirse o la pestania estuvo abandonada. Corta con un
 * enfriamiento para que una actualizacion que no prospera no entre en loop.
 */
function puedeAplicarSinPreguntar(ausenteMs: number): boolean {
  if (Date.now() - leerNumero(CLAVE_AUTO) < ENFRIAMIENTO_AUTO_MS) return false
  if (hayTrabajoEnCurso()) return false
  const recienAbierta = performance.now() < VENTANA_ARRANQUE_MS
  return recienAbierta || ausenteMs >= AUSENCIA_LARGA_MS
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
  /** Esconde el cartel por un rato. */
  posponer: () => void
}

export function useActualizacionDisponible(): ActualizacionDisponible {
  const [disponible, setDisponible] = useState(() => hayActualizacionSWEsperando() && Date.now() >= leerNumero(CLAVE_POSPUESTO))
  const [actualizando, setActualizando] = useState(false)
  // En sessionStorage para que sobreviva a una recarga: en memoria, el "Mas
  // tarde" se perdia al recargar y el cartel volvia a saltar enseguida.
  const pospuestoHasta = useRef(leerNumero(CLAVE_POSPUESTO))
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

  /** Salta solo si no hay nada que perder; si no, queda el cartel. */
  const intentarAuto = useCallback((ausenteMs: number): boolean => {
    if (!hayNuevo.current) return false
    // El "Mas tarde" tambien frena el salto automatico.
    if (Date.now() < pospuestoHasta.current) return false
    if (!puedeAplicarSinPreguntar(ausenteMs)) return false
    guardarNumero(CLAVE_AUTO, Date.now())
    actualizar()
    return true
  }, [actualizar])

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
        hayNuevo.current = true
        if (!intentarAuto(0)) setDisponible(true)
      }
    } catch {
      /* sin conexion: se reintenta en el proximo ciclo */
    }
  }, [activo, intentarAuto])

  useEffect(() => {
    if (!activo) return

    void chequear()

    const alVolver = (): void => {
      if (document.visibilityState === 'hidden') {
        escondidaDesde.current ??= Date.now()
        return
      }
      if (document.visibilityState !== 'visible') return
      const ausente = escondidaDesde.current === null ? 0 : Date.now() - escondidaDesde.current
      escondidaDesde.current = null
      // Si salta sola no hace falta mostrar nada.
      if (intentarAuto(ausente)) return
      void chequear()
    }
    document.addEventListener('visibilitychange', alVolver)
    window.addEventListener('focus', alVolver)

    const id = setInterval(() => { void chequear() }, INTERVALO_MS)

    // El service worker dejo un build nuevo esperando. Respeta el "Mas tarde"
    // igual que el chequeo de /version.json.
    const desuscribir = suscribirActualizacionSW(() => {
      hayNuevo.current = true
      if (Date.now() < pospuestoHasta.current) return
      if (!intentarAuto(0)) setDisponible(true)
    })

    return () => {
      document.removeEventListener('visibilitychange', alVolver)
      window.removeEventListener('focus', alVolver)
      clearInterval(id)
      desuscribir()
    }
  }, [activo, chequear, intentarAuto])

  const posponer = useCallback(() => {
    pospuestoHasta.current = Date.now() + ESPERA_TRAS_POSPONER_MS
    guardarNumero(CLAVE_POSPUESTO, pospuestoHasta.current)
    setDisponible(false)
  }, [])

  return { disponible, buildActual: BUILD_ACTUAL, actualizando, actualizar, posponer }
}

export default useActualizacionDisponible
