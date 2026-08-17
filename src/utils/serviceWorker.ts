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
 * - El salto al build nuevo lo decide la usuaria con el cartel
 *   (`BannerActualizacion`), nunca la app sola: un reload sorpresa mientras
 *   carga un pedido le borra lo tipeado.
 * - `aplicarActualizacionSW()` es lo que ejecuta ese salto, y tiene que pasar
 *   SI o SI por el service worker: con el SW controlando la pagina, un
 *   `location.reload()` pelado vuelve a servir el index.html viejo del
 *   precache y el cartel queda para siempre sin hacer nada.
 */
import { registerSW } from 'virtual:pwa-register'
import { logger } from './logger'

/** Cuanto esperamos a que el SW nuevo termine de instalarse antes de recargar igual. */
const ESPERA_INSTALACION_MS = 10000

type Escucha = () => void

let registro: ServiceWorkerRegistration | null = null
let activarSwEnEspera: ((recargarPagina?: boolean) => Promise<void>) | null = null
let hayVersionEsperando = false
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
 * Espera a que el SW que se esta instalando pase a "esperando".
 * Devuelve false si no habia ninguno o si tardo demasiado.
 */
function esperarSwEnEspera(reg: ServiceWorkerRegistration): Promise<boolean> {
  if (reg.waiting) return Promise.resolve(true)

  const instalando = reg.installing
  if (!instalando) return Promise.resolve(false)

  return new Promise<boolean>(resolve => {
    const terminar = (resultado: boolean): void => {
      clearTimeout(temporizador)
      instalando.removeEventListener('statechange', alCambiarEstado)
      resolve(resultado)
    }

    const alCambiarEstado = (): void => {
      if (instalando.state === 'installed') terminar(Boolean(reg.waiting))
      else if (instalando.state === 'redundant') terminar(false)
    }

    const temporizador = setTimeout(() => terminar(false), ESPERA_INSTALACION_MS)
    instalando.addEventListener('statechange', alCambiarEstado)
  })
}

/**
 * Salta al build nuevo. Es lo que ejecuta el boton "Actualizar" del cartel.
 *
 * Si hay un service worker esperando, lo activa y la recarga la dispara el
 * propio plugin cuando cambia el controlador; sin eso, la recarga volveria a
 * servir el index.html viejo del precache y el cartel no se iria nunca.
 * Si no hay service worker (navegador sin soporte, registro fallido), recarga
 * a la antigua.
 */
export async function aplicarActualizacionSW(): Promise<void> {
  const reg = registro

  if (reg && activarSwEnEspera) {
    try {
      if (!reg.waiting) {
        // El cartel puede venir de /version.json, que se entera antes que el
        // navegador: hay que ir a buscar el sw.js nuevo.
        await reg.update()
        await esperarSwEnEspera(reg)
      }

      if (reg.waiting) {
        await activarSwEnEspera(true)
        return
      }
    } catch (err) {
      logger.warn('[sw] Fallo la activacion del build nuevo, se recarga igual', err)
    }
  }

  window.location.reload()
}

/** Solo para tests: vuelve el modulo a cero. */
export function _resetServiceWorkerParaTests(): void {
  registro = null
  activarSwEnEspera = null
  hayVersionEsperando = false
  escuchas.clear()
}
