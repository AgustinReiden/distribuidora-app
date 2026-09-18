/**
 * Cortafuegos de red de la galería.
 *
 * La config ya fuerza `VITE_SUPABASE_URL` al placeholder (ver
 * `vite.gallery.config.js`), así que ninguna petición puede llegar a producción.
 * Esto es la segunda mitad: bloquear TODO lo que salga del propio origen, para que
 * la garantía no dependa de que nadie se equivoque con una variable de entorno.
 *
 * Hace falta porque no alcanza con configurar el QueryClient: las opciones que un
 * hook le pasa a `useQuery` le ganan a los defaults del cliente, y
 * `useNotificacionesQuery` (src/hooks/queries/useNotificacionesQuery.ts:46-48)
 * fija `refetchInterval: 60_000` y `staleTime: 30_000` a mano. La campanita
 * volvía a pedir cada minuto y dejaba un `ERR_NAME_NOT_RESOLVED` en la consola
 * por vuelta. El rechazo de acá lo absorbe TanStack (`retry: false` y un
 * `QueryCache.onError` vacío) y los datos precargados se quedan como están.
 *
 * Los módulos de Vite y su HMR viajan por el mismo origen, así que no los toca.
 */
const ORIGEN = window.location.origin
const fetchOriginal = window.fetch.bind(window)

// `Parameters<typeof fetch>` en vez de `RequestInfo`/`RequestInit`: son tipos del
// lib DOM, no globales de runtime, y la regla `no-undef` de eslint (que corre sobre
// TS con la config de JS) los marcaría como no definidos.
type EntradaFetch = Parameters<typeof fetch>[0]
type OpcionesFetch = Parameters<typeof fetch>[1]

function urlDe(input: EntradaFetch): string {
  if (typeof input === 'string') return input
  if (input instanceof URL) return input.href
  return input.url
}

window.fetch = (input: EntradaFetch, init?: OpcionesFetch): ReturnType<typeof fetch> => {
  const url = urlDe(input)
  const esPropio = url.startsWith('/') || url.startsWith('.') || url.startsWith(ORIGEN)

  if (esPropio) return fetchOriginal(input, init)

  // `debug` y no `warn`: es el comportamiento esperado, no una falla.
  console.debug('[galería] petición externa bloqueada:', url)
  return Promise.reject(new Error(`[galería] sin red: ${url}`))
}
