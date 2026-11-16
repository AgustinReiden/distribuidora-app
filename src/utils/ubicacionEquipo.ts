/**
 * El equipo del preventista, visto desde la ubicación (#1602).
 *
 * Tres preventistas de una sucursal tenían sus pedidos 100 % en `gps_status =
 * 'denied'` desde hacía meses y nadie sabía qué teléfono tenían ni si usaban la
 * app instalada o el navegador. Acá vive lo que se puede decidir sin tocar el
 * navegador: qué equipo es (por el user agent), por qué está bloqueada la
 * ubicación, qué pasos mostrarle para desbloquearla y qué diagnóstico guardar con
 * cada captura. Lo que lee el navegador (Permissions API, `display-mode`, la marca
 * local) vive en `useGeolocationPermission` y `useGeolocationCapture`.
 */
import type { GpsStatus } from '../hooks/useGeolocationCapture'

/** Lo que contesta `navigator.permissions.query({ name: 'geolocation' })`; `unsupported` si no se pudo preguntar. */
export type EstadoPermisoGeo = 'granted' | 'prompt' | 'denied' | 'unsupported'

export type SistemaEquipo = 'android' | 'ios' | 'otro'
export type NavegadorEquipo = 'chrome' | 'samsung' | 'edge' | 'opera' | 'firefox' | 'safari' | 'otro'

export interface EntornoEquipo {
  so: SistemaEquipo
  soVersion: number | null
  navegador: NavegadorEquipo
  navegadorVersion: number | null
  /** La app instalada (PWA en `display-mode: standalone`), no una pestaña del navegador. */
  instalada: boolean
}

function mayor(m: RegExpMatchArray | null, grupo = 1): number | null {
  const n = m?.[grupo] ? Number.parseInt(m[grupo], 10) : NaN
  return Number.isFinite(n) ? n : null
}

/**
 * El equipo según el user agent. `maxTouchPoints` distingue un iPad, que desde
 * iPadOS 13 se presenta como una Mac.
 *
 * La versión es la que declara el user agent, que no siempre es la real: Chrome
 * congela Android en 10 desde la reducción del user agent, y Safari en iOS 26
 * declara la 18. Sirve para separar familias, no para saber el modelo.
 */
export function entornoDelEquipo(
  ua: string,
  { instalada = false, maxTouchPoints = 0 }: { instalada?: boolean; maxTouchPoints?: number } = {},
): EntornoEquipo {
  const texto = ua || ''
  let so: SistemaEquipo = 'otro'
  let soVersion: number | null = null
  if (/Android/i.test(texto)) {
    so = 'android'
    soVersion = mayor(texto.match(/Android\s+(\d+)/i))
  } else if (/iPhone|iPad|iPod/i.test(texto) || (/Macintosh/i.test(texto) && maxTouchPoints > 1)) {
    so = 'ios'
    soVersion = mayor(texto.match(/OS (\d+)[_.]\d/i)) ?? mayor(texto.match(/Version\/(\d+)/i))
  }

  // El orden importa: Samsung, Edge y Opera también dicen "Chrome", y todo
  // navegador de iOS dice "Safari".
  let navegador: NavegadorEquipo = 'otro'
  let navegadorVersion: number | null = null
  const reglas: Array<[NavegadorEquipo, RegExp]> = [
    ['samsung', /SamsungBrowser\/(\d+)/i],
    ['edge', /Edg(?:e|A|iOS)?\/(\d+)/i],
    ['opera', /(?:OPR|OPT|OPiOS)\/(\d+)/i],
    ['firefox', /(?:Firefox|FxiOS)\/(\d+)/i],
    ['chrome', /(?:Chrome|CriOS)\/(\d+)/i],
    ['safari', /Version\/(\d+)[\d.]*\s.*Safari/i],
  ]
  for (const [nombre, re] of reglas) {
    const m = texto.match(re)
    if (m) {
      navegador = nombre
      navegadorVersion = mayor(m)
      break
    }
  }
  if (navegador === 'otro' && so === 'ios' && /AppleWebKit/i.test(texto)) navegador = 'safari'

  return { so, soVersion, navegador, navegadorVersion, instalada }
}

/**
 * Por qué está bloqueada la ubicación, con el permiso leído DESPUÉS del error:
 * - `sitio`: este sitio tiene la ubicación bloqueada en el navegador (la API dice
 *   `denied`), o no se sabe (`unsupported`) y es lo más probable.
 * - `sistema`: el sitio sí tiene permiso (la API dice `granted` o `prompt`) y aun
 *   así `getCurrentPosition` devolvió PERMISSION_DENIED: la Ubicación del teléfono
 *   está apagada o el navegador no tiene el permiso del sistema.
 */
export type CausaBloqueo = 'sitio' | 'sistema'

export function causaDelBloqueo(permiso: EstadoPermisoGeo): CausaBloqueo {
  return permiso === 'granted' || permiso === 'prompt' ? 'sistema' : 'sitio'
}

const NOMBRE_NAVEGADOR: Record<NavegadorEquipo, string> = {
  chrome: 'Chrome',
  samsung: 'Samsung Internet',
  edge: 'Edge',
  opera: 'Opera',
  firefox: 'Firefox',
  safari: 'Safari',
  otro: 'el navegador',
}

const REINTENTAR = 'Volvé acá y tocá «Ya lo activé, reintentar».'

/**
 * Los pasos para desbloquear la ubicación, según el equipo y la causa.
 *
 * Los nombres de menú cambian entre versiones y fabricantes, así que se nombra
 * lo que dura (la dirección del sitio, la configuración del teléfono, el nombre
 * del navegador) y, cuando hay dos caminos, se dan los dos. La app instalada no
 * tiene barra de dirección ni menú ⋮: en Android comparte los permisos con el
 * navegador con el que se instaló, así que se cambian desde ahí.
 */
export function instruccionesDesbloqueo(entorno: EntornoEquipo, causa: CausaBloqueo): string[] {
  const nav = NOMBRE_NAVEGADOR[entorno.navegador]

  if (entorno.so === 'android') {
    if (causa === 'sistema') {
      return [
        'Deslizá desde arriba de la pantalla y fijate que «Ubicación» esté prendida.',
        `Si ya estaba prendida: abrí los Ajustes del teléfono → Aplicaciones → ${entorno.navegador === 'otro' ? 'tu navegador' : nav} → Permisos → Ubicación, y elegí «Permitir solo mientras se usa la app».`,
        REINTENTAR,
      ]
    }
    const navAndroid = entorno.navegador === 'otro' ? 'Chrome' : nav
    const pasos = entorno.instalada
      ? [
          `Esta app usa los permisos de ${navAndroid}. Abrí ${navAndroid} (el navegador, no la app) y entrá a la misma dirección.`,
          'Tocá el ícono que está a la izquierda de la dirección (un candado o unas rayitas) → Permisos o Ubicación → «Permitir».',
          `Si no lo encontrás: menú de ${navAndroid} → Configuración → Configuración de sitios → Ubicación, buscá esta dirección y ponela en «Permitir».`,
        ]
      : [
          'Tocá el ícono que está a la izquierda de la dirección (un candado o unas rayitas) → Permisos o Ubicación → «Permitir».',
          `Si no lo encontrás: menú de ${navAndroid} (los tres puntos) → Configuración → Configuración de sitios → Ubicación, buscá esta dirección y ponela en «Permitir».`,
        ]
    return [...pasos, 'Fijate también que la Ubicación del teléfono esté prendida.', REINTENTAR]
  }

  if (entorno.so === 'ios') {
    if (causa === 'sistema' || entorno.instalada) {
      return [
        'Abrí Ajustes → Privacidad y seguridad → Localización, y fijate que esté prendida.',
        'En esa misma lista, entrá a «Sitios web de Safari» y elegí «Al usar la app».',
        ...(entorno.instalada ? ['En Ajustes, buscá «Safari» → Ubicación, y elegí «Preguntar» o «Permitir».'] : []),
        REINTENTAR,
      ]
    }
    return [
      'En Ajustes, buscá «Safari» → Ubicación, y elegí «Preguntar» o «Permitir».',
      'Si sigue bloqueada: Ajustes → Privacidad y seguridad → Localización → «Sitios web de Safari» → «Al usar la app».',
      REINTENTAR,
    ]
  }

  if (causa === 'sistema') {
    return [
      'Fijate que la ubicación de la computadora esté prendida y que el navegador tenga permiso para usarla (en la configuración de privacidad del sistema).',
      REINTENTAR,
    ]
  }
  return [
    'Tocá el ícono que está a la izquierda de la dirección (un candado o similar) → Ubicación → «Permitir».',
    `Si no lo encontrás, buscá «Ubicación» en la configuración de sitios de ${nav}.`,
    REINTENTAR,
  ]
}

/**
 * Lo que se guarda del equipo con cada captura (`gps_diagnostico`, mig NNN). Corto
 * a propósito: familia y versión mayor, nunca el user agent entero. La columna
 * tiene un tope de tamaño.
 */
export interface DiagnosticoGps {
  /** Estado de la Permissions API después de la captura. */
  permiso: EstadoPermisoGeo
  /** `GeolocationPositionError.code` (1 denegado, 2 sin posición, 3 timeout), o null si salió bien. */
  error: number | null
  instalada: boolean
  /** p. ej. `chrome 131`, `samsung 27`, `safari 18`. */
  navegador: string
  /** p. ej. `android 10`, `ios 18`, `otro`. */
  so: string
}

function conVersion(nombre: string, version: number | null): string {
  return version == null ? nombre : `${nombre} ${version}`
}

export function diagnosticoGps(
  entorno: EntornoEquipo,
  permiso: EstadoPermisoGeo,
  error: number | null,
): DiagnosticoGps {
  return {
    permiso,
    error: Number.isInteger(error) ? error : null,
    instalada: entorno.instalada,
    navegador: conVersion(entorno.navegador, entorno.navegadorVersion),
    so: conVersion(entorno.so, entorno.soVersion),
  }
}

/**
 * ¿Hay que pedirle al preventista el motivo para seguir sin coordenadas?
 *
 * #1602, decisión a revisar por el dueño: también con `denied`. Antes un timeout
 * pedía un motivo escrito y el permiso denegado no pedía nada, así que lo más
 * cómodo era quedarse en denegado. Para volver atrás: `status !== 'ok' && status
 * !== 'denied'` (y el texto de «Continuar sin GPS» en `GeolocationGate`).
 */
export function pideMotivoSinGps(status: GpsStatus): status is Exclude<GpsStatus, 'ok'> {
  return status !== 'ok'
}
