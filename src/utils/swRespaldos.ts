/**
 * Respaldos sin red del service worker (#1267).
 *
 * `generateSW` (vite-plugin-pwa) los copia a `sw.js` con `toString()`: cada
 * función tiene que ser AUTOCONTENIDA, sin imports, constantes del módulo ni
 * helpers de afuera. Viven acá y no inline en `vite.config.js` sólo para poder
 * probarlas, también serializadas (`swRespaldos.test.ts`).
 *
 * Lo que los hace posibles es un detalle de workbox: el precache es UNA sola
 * caché para todas las versiones. El SW nuevo, al instalarse, deja ahí los
 * archivos de su build; recién al activarse borra los del anterior.
 */

/**
 * El HTML que se sirve sin red (o con más de 3 s de espera): el `index.html`
 * que precacheó el propio SW, no el último que se bajó.
 *
 * Antes era el último HTML de la red, guardado en `html-cache`, y podía ser de
 * otra versión que la del SW al mando. Si era más viejo (el SW se actualizó sin
 * una navegación de por medio y la app se abrió sin señal), su JS de entrada ya
 * no estaba en el precache y la app quedaba en el spinner de arranque. Con una
 * versión esperando hay dos `index.html` en el precache, y cualquiera sirve: los
 * assets de las dos están ahí y `respaldoRecursoSinRed` los encuentra.
 */
export const respaldoNavegacionSinRed = async (): Promise<Response | undefined> => {
  const precache = (await caches.keys()).find(nombre => nombre.startsWith('workbox-precache-v2-'))
  if (!precache) return undefined
  const cache = await caches.open(precache)
  return (await cache.match('/index.html', { ignoreSearch: true, ignoreVary: true })) || undefined
}

/**
 * Un JS o CSS que no está en `static-resources` y no se pudo bajar: se busca en
 * todas las cachés.
 *
 * Es el caso de la primera apertura tras un deploy: la navegación va a la red y
 * trae el HTML nuevo con el SW viejo todavía al mando. Los chunks lazy de ese
 * HTML ya los dejó en el precache el SW que espera, pero el viejo no los rutea
 * (su ruta de precache sólo conoce su propio manifiesto), y sin señal el
 * `import()` fallaba. Los assets tienen el hash en el nombre: cualquier copia
 * con esa URL es la correcta.
 */
export const respaldoRecursoSinRed = async ({ request }: { request: Request }): Promise<Response | undefined> =>
  (await caches.match(request.url, { ignoreSearch: true, ignoreVary: true })) || undefined
