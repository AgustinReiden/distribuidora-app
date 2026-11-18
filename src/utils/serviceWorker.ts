/**
 * Registro del service worker.
 *
 * Por que existe este archivo: `vite-plugin-pwa` estaba configurado con
 * `injectRegister: false`, o sea que el registro lo tenia que hacer la app a
 * mano, y el unico lugar que lo hacia (`PWAPrompt`) nunca se monto. Resultado:
 * la app generaba `sw.js` en cada build y nadie lo registraba nunca.
 *
 * Eso es lo que dejaba la app agregada al inicio en iPhone con la pantalla en
 * blanco: sin service worker no hay nada cacheado, asi que si el telefono no
 * llega a bajar el index.html al abrir la app (senal mala, cambio de red,
 * deploy a medio subir) no se ve NADA. Y en modo standalone no hay barra de
 * direcciones ni boton de recargar, asi que la unica salida era borrar el
 * icono y volver a agregarlo al inicio.
 *
 * Como esta armado el ciclo de actualizacion, que es donde esto se puso feo en
 * marzo (chunks viejos, ver `lazyWithReload.ts`):
 *
 * - `skipWaiting: false` + `clientsClaim: false` (vite.config.js). El service
 *   worker nuevo se queda ESPERANDO y no le saca la alfombra a la sesion en
 *   curso: la pestania abierta sigue sirviendose del precache viejo, completo
 *   y consistente. Justo lo contrario de marzo, cuando el SW nuevo tomaba
 *   control a mitad de sesion y los `import()` del bundle viejo se iban a 404.
 * - D57 (1563-b8 de #1563): el salto al build nuevo es obligatorio. El cartel
 *   (`BannerActualizacion`) avisa y la app salta sola al volver a ella o al
 *   cambiar de pantalla (`useActualizacionDisponible`). Nunca encima de trabajo
 *   a medio cargar: bajar e instalar el build puede tardar ~45 s, así que justo
 *   antes de recargar se vuelve a preguntar (`puedeRecargar`); si en ese momento
 *   hay algo en curso, el SW queda esperando y el próximo disparo lo activa.
 * - `aplicarActualizacionSW()` es lo que ejecuta ese salto, y tiene que pasar
 *   SI o SI por el service worker: un `location.reload()` pelado no activa al
 *   que espera, asi que el viejo sigue al mando y el cartel queda para siempre.
 * - Una navegacion nueva (abrir la app, recargar) va a la red primero y trae el
 *   HTML del build nuevo aunque el SW viejo siga controlando (#1267). Los chunks
 *   de ese HTML los sirve el precache que dejo el SW que espera; sin red, la
 *   navegacion sirve el index.html precacheado del propio SW (`swRespaldos.ts`).
 */
import { registerSW } from 'virtual:pwa-register'
import { logger } from './logger'

/**
 * Cuanto esperamos a que el SW nuevo termine de instalarse antes de rendirnos.
 * Instalar es bajar TODO el precache: con senal mala 10 s no alcanzaba, el
 * boton caia al reload pelado con el SW viejo todavia al mando y el cartel
 * volvia a aparecer (hay que apretarlo "varias veces"). El boton muestra
 * "Actualizando..." mientras espera, asi que esperar de mas no confunde.
 */
const ESPERA_INSTALACION_MS = 30000

/**
 * Cuanto esperamos a que `update()` (ir a buscar el sw.js) responda. Con senal
 * que no pasa datos no falla: queda colgado hasta que corta el navegador, y
 * mientras tanto `aplicando` no se libera y los toques siguientes no hacen
 * nada (#1373).
 */
const ESPERA_UPDATE_MS = 15000

type Escucha = () => void

let registro: ServiceWorkerRegistration | null = null
let activarSwEnEspera: ((recargarPagina?: boolean) => Promise<void>) | null = null
let hayVersionEsperando = false
let aplicando: Promise<ResultadoSalto> | null = null
const escuchas = new Set<Escucha>()

function avisar(): void {
  escuchas.forEach(escucha => {
    try {
      escucha()
    } catch (err) {
      logger.warn('[sw] Fallo un suscriptor de actualizacion', err)
    }
  })
}

/**
 * Registra el service worker. Se llama una sola vez, en el arranque.
 * No lanza nunca: si el registro falla, la app funciona igual, solo que sin
 * modo offline.
 */
export function registrarServiceWorker(): void {
  // En dev el bundle lo sirve vite con HMR y no hay sw.js que registrar.
  if (!import.meta.env.PROD) return
  if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return
  if (activarSwEnEspera) return

  try {
    activarSwEnEspera = registerSW({
      immediate: true,

      // Hay un build nuevo instalado y esperando. No recargamos: prendemos el
      // cartel y que decida ella.
      onNeedRefresh() {
        hayVersionEsperando = true
        logger.info('[sw] Hay una version nueva esperando')
        avisar()
      },

      onOfflineReady() {
        logger.info('[sw] La app quedo disponible sin conexion')
      },

      onRegisteredSW(_url: string, registroSW?: ServiceWorkerRegistration) {
        registro = registroSW ?? null
      },

      onRegisterError(error: Error) {
        logger.error('[sw] No se pudo registrar el service worker', error)
      },
    })
  } catch (err) {
    logger.error('[sw] No se pudo registrar el service worker', err)
  }
}

/** Suscribe al aviso de "hay un build nuevo esperando". Devuelve el desuscriptor. */
export function suscribirActualizacionSW(escucha: Escucha): () => void {
  escuchas.add(escucha)
  return () => { escuchas.delete(escucha) }
}

/** true si el service worker ya bajo un build nuevo y lo tiene en espera. */
export function hayActualizacionSWEsperando(): boolean {
  return hayVersionEsperando
}

/**
 * Que paso con la instalacion del SW nuevo:
 * - `esperando`: quedo instalado y esperando, listo para activarse.
 * - `sin-instalacion`: no habia ninguno instalandose. Tras un `update()` que
 *   respondio, es que el sw.js es el mismo: la red anduvo y no hay build nuevo.
 * - `fallo`: se estaba instalando y no termino (se paso del plazo o quedo
 *   `redundant`). Bajar el precache es lo que la senal mala no deja: no hay
 *   red confirmada que traiga el build (#1373).
 */
type ResultadoInstalacion = 'esperando' | 'sin-instalacion' | 'fallo'

/** Espera a que el SW que se esta instalando pase a "esperando". */
function esperarSwEnEspera(reg: ServiceWorkerRegistration): Promise<ResultadoInstalacion> {
  if (reg.waiting) return Promise.resolve('esperando')

  const instalando = reg.installing
  if (!instalando) return Promise.resolve('sin-instalacion')

  return new Promise<ResultadoInstalacion>(resolve => {
    const terminar = (resultado: ResultadoInstalacion): void => {
      clearTimeout(temporizador)
      instalando.removeEventListener('statechange', alCambiarEstado)
      resolve(resultado)
    }

    const alCambiarEstado = (): void => {
      if (instalando.state === 'installed') terminar(reg.waiting ? 'esperando' : 'fallo')
      else if (instalando.state === 'redundant') terminar('fallo')
    }

    const temporizador = setTimeout(() => terminar('fallo'), ESPERA_INSTALACION_MS)
    instalando.addEventListener('statechange', alCambiarEstado)
  })
}

/** `reg.update()` con plazo: si no responde se trata como una red que no anda. */
function actualizarConPlazo(reg: ServiceWorkerRegistration): Promise<void> {
  let temporizador: ReturnType<typeof setTimeout> | undefined
  const vencido = new Promise<never>((_, reject) => {
    temporizador = setTimeout(
      () => reject(new Error(`update() sin respuesta en ${ESPERA_UPDATE_MS / 1000} s`)),
      ESPERA_UPDATE_MS,
    )
  })
  return Promise.race([reg.update().then(() => undefined), vencido]).finally(() => clearTimeout(temporizador))
}

/**
 * Cómo terminó un salto:
 * - `recargando`: se activó el SW en espera (la recarga la dispara el plugin) o
 *   se recargó a la antigua;
 * - `pospuesto`: estaba todo listo pero `puedeRecargar` dijo que no (hay algo a
 *   medio cargar). El SW nuevo queda esperando y el próximo salto lo activa sin
 *   tocar la red (H1 de la revisión de B12a);
 * - `sin-red`: no se pudo bajar el build (sin red, `update()` que falla o no
 *   responde, instalación que no termina). Ver `reintentarAlVolverLaRed`.
 */
export type ResultadoSalto = 'recargando' | 'pospuesto' | 'sin-red'

export interface OpcionesSalto {
  /**
   * Se pregunta JUSTO antes de recargar, no al empezar: bajar e instalar el
   * build puede tardar ~45 s y en ese rato se pudo abrir un formulario. Sin
   * esto, el salto automático de D57 recargaba encima de un pedido a medio
   * cargar. El botón "Actualizar" no lo pasa: ahí la decisión es de quien toca.
   */
  puedeRecargar?: () => boolean
}

/**
 * Salta al build nuevo. Lo ejecutan el boton "Actualizar" del cartel y el salto
 * automático de D57.
 *
 * Si hay un service worker esperando, lo activa y la recarga la dispara el
 * propio plugin cuando cambia el controlador; sin eso, la recarga volveria a
 * servir el index.html viejo del precache y el cartel no se iria nunca.
 * Si no hay service worker (navegador sin soporte, registro fallido), recarga
 * a la antigua. Sin red, o si el `update()` falla, no hace nada de eso: ver
 * `reintentarAlVolverLaRed`.
 */
export function aplicarActualizacionSW(opciones: OpcionesSalto = {}): Promise<ResultadoSalto> {
  // Un solo salto a la vez: un segundo toque mientras el primero espera la
  // instalacion no tiene que lanzar otro update ni otro reload.
  if (!aplicando) {
    aplicando = ejecutarActualizacion(opciones.puedeRecargar ?? (() => true)).finally(() => { aplicando = null })
  }
  return aplicando
}

/**
 * Cuando el salto no se puede hacer porque no hay red (o el `update()` fallo),
 * NO se da de baja el SW ni se recarga (#1302): sin red el reload no tiene de
 * donde traer nada, y sin SW tampoco hay precache -- queda la pantalla de error
 * del navegador y el preventista no ve ni sus pedidos encolados. El cartel
 * sigue en pantalla (nadie lo baja) y, cuando vuelve la conexion, se va a
 * buscar el sw.js nuevo en silencio: al quedar esperando, el plugin avisa por
 * `onNeedRefresh` y el proximo salto activa sin tocar la red. Volver la senal no
 * recarga: el salto llega con el proximo cambio de pantalla o vuelta a la app
 * (D57), o con el boton.
 */
let reintentoAlVolverLaRed: (() => void) | null = null

function reintentarAlVolverLaRed(): void {
  if (reintentoAlVolverLaRed || typeof window === 'undefined') return

  const alVolver = (): void => {
    window.removeEventListener('online', alVolver)
    reintentoAlVolverLaRed = null
    const reg = registro
    if (!reg || reg.waiting) return
    reg.update().catch((err: unknown) => {
      // Se cayo otra vez: se espera la proxima vez que vuelva la conexion.
      logger.warn('[sw] No se pudo buscar el build nuevo al volver la conexion', err)
      reintentarAlVolverLaRed()
    })
  }

  reintentoAlVolverLaRed = alVolver
  window.addEventListener('online', alVolver)
}

function sinRed(): boolean {
  return typeof navigator !== 'undefined' && navigator.onLine === false
}

async function ejecutarActualizacion(puedeRecargar: () => boolean): Promise<ResultadoSalto> {
  const reg = registro

  if (reg && activarSwEnEspera) {
    try {
      if (!reg.waiting) {
        // Ir a buscar el sw.js nuevo necesita red: sin ella no hay nada que
        // esperar ni que dar de baja.
        if (sinRed()) {
          logger.warn('[sw] Sin conexion: se mantiene el service worker y el cartel')
          reintentarAlVolverLaRed()
          return 'sin-red'
        }

        // El cartel puede venir de /version.json, que se entera antes que el
        // navegador: hay que ir a buscar el sw.js nuevo.
        try {
          await actualizarConPlazo(reg)
        } catch (err) {
          // Un `update()` que falla, o que no responde, es una red que no anda,
          // aunque `navigator.onLine` diga que si (senal mala, portal cautivo).
          logger.warn('[sw] No se pudo buscar el build nuevo, se mantiene el service worker', err)
          reintentarAlVolverLaRed()
          return 'sin-red'
        }
        const instalacion = await esperarSwEnEspera(reg)
        if (instalacion === 'fallo') {
          // Se estaba bajando el build nuevo y no llego: el mismo modo de falla
          // que #1302. Dar de baja el SW dejaria la app sin precache y la
          // recarga sin red que traiga el build (#1373). Si termina de bajar
          // despues, `onNeedRefresh` avisa y el proximo toque activa.
          logger.warn('[sw] El build nuevo no termino de instalarse, se mantiene el service worker')
          reintentarAlVolverLaRed()
          return 'sin-red'
        }
      }

      if (reg.waiting) {
        // Recién ahora, con el build bajado, se mira si se puede recargar (H1).
        if (!puedeRecargar()) {
          logger.info('[sw] Build nuevo listo; se activa en el proximo salto (hay trabajo en curso)')
          hayVersionEsperando = true
          return 'pospuesto'
        }
        await activarSwEnEspera(true)
        return 'recargando'
      }
    } catch (err) {
      logger.warn('[sw] Fallo la activacion del build nuevo, se recarga igual', err)
    }

    // Se fue la red mientras esperaba la instalacion: mismo criterio.
    if (sinRed()) {
      reintentarAlVolverLaRed()
      return 'sin-red'
    }

    if (!puedeRecargar()) return 'pospuesto'

    // El `update()` respondio y no hay build nuevo instalandose (el sw.js es el
    // mismo): la red anduvo. Un reload con el SW viejo al mando devolveria el
    // mismo bundle y el cartel reaparece: lo damos de baja para que la recarga
    // vaya a la red. El SW nuevo se registra solo al arrancar.
    try {
      await reg.unregister?.()
    } catch (err) {
      logger.warn('[sw] No se pudo dar de baja el service worker viejo', err)
    }
  } else if (!puedeRecargar()) {
    return 'pospuesto'
  }

  window.location.reload()
  return 'recargando'
}

/** Solo para tests: vuelve el modulo a cero. */
export function _resetServiceWorkerParaTests(): void {
  if (reintentoAlVolverLaRed) window.removeEventListener('online', reintentoAlVolverLaRed)
  reintentoAlVolverLaRed = null
  registro = null
  activarSwEnEspera = null
  hayVersionEsperando = false
  aplicando = null
  escuchas.clear()
}
