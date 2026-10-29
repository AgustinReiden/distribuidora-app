/**
 * Los respaldos sin red del service worker (#1267). Se reprodujeron en vite
 * preview con tres builds seguidos y el server apagado:
 *
 * - Tras un deploy, la navegación trae el HTML nuevo con el SW viejo al mando.
 *   Sin red, el `import()` de un chunk lazy del build nuevo fallaba aunque el
 *   archivo YA estaba en el precache (lo dejó ahí el SW que espera).
 * - Si el HTML guardado era de una versión anterior al SW activo, su JS de
 *   entrada ya no estaba en el precache y la app quedaba en el spinner.
 *
 * `generateSW` copia estas funciones a `sw.js` con `toString()`, así que además
 * se prueban serializadas: una referencia a algo de afuera reventaría recién en
 * el teléfono.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { respaldoNavegacionSinRed, respaldoRecursoSinRed } from './swRespaldos'

const PRECACHE = 'workbox-precache-v2-https://crecer.example/'

/** Un CacheStorage mínimo: el orden de las cachés es el de creación, como en el navegador. */
function cacheStorageFalso(contenido: Record<string, Record<string, string>>): CacheStorage {
  const sinQuery = (url: string): string => new URL(url, 'https://crecer.example').pathname
  const abrir = (nombre: string) => ({
    match: async (req: string, opts?: { ignoreSearch?: boolean }) => {
      const buscado = opts?.ignoreSearch ? sinQuery(req) : new URL(req, 'https://crecer.example').href
      for (const [clave, cuerpo] of Object.entries(contenido[nombre] ?? {})) {
        const k = opts?.ignoreSearch ? sinQuery(clave) : new URL(clave, 'https://crecer.example').href
        if (k === buscado) return new Response(cuerpo)
      }
      return undefined
    },
  })
  return {
    keys: async () => Object.keys(contenido),
    open: async (nombre: string) => abrir(nombre),
    match: async (req: string, opts?: { ignoreSearch?: boolean }) => {
      for (const nombre of Object.keys(contenido)) {
        const r = await abrir(nombre).match(req, opts)
        if (r) return r
      }
      return undefined
    },
  } as unknown as CacheStorage
}

/** La función tal como queda en sw.js: su texto, evaluado sin el módulo alrededor. */
function serializada<F>(fn: F): F {
  return new Function(`return (${String(fn)})`)() as F
}

const original = globalThis.caches

describe('respaldos sin red del service worker', () => {
  afterEach(() => {
    globalThis.caches = original
  })

  describe.each([
    ['la función', (f: typeof respaldoNavegacionSinRed) => f],
    ['serializada como en sw.js', serializada],
  ])('navegación (%s)', (_nombre, preparar) => {
    let navegar: typeof respaldoNavegacionSinRed
    beforeEach(() => {
      navegar = preparar(respaldoNavegacionSinRed)
    })

    it('sirve el index.html del precache, no el HTML viejo que quedó en html-cache', async () => {
      globalThis.caches = cacheStorageFalso({
        'html-cache': { '/index.html': 'html v1' },
        [PRECACHE]: { '/index.html?__WB_REVISION__=abc': 'html v2', '/assets/index-v2.js': 'js' },
      })

      const r = await navegar()

      expect(await r?.text()).toBe('html v2')
    })

    it('sin precache no inventa nada', async () => {
      globalThis.caches = cacheStorageFalso({ 'html-cache': { '/index.html': 'html v1' } })

      expect(await navegar()).toBeUndefined()
    })
  })

  describe.each([
    ['la función', (f: typeof respaldoRecursoSinRed) => f],
    ['serializada como en sw.js', serializada],
  ])('JS/CSS (%s)', (_nombre, preparar) => {
    it('encuentra en el precache el chunk del build que espera', async () => {
      globalThis.caches = cacheStorageFalso({
        [PRECACHE]: { '/assets/AnalyticsContainer-v2.js': 'chunk v2' },
        'static-resources': { '/assets/index-v2.js': 'entrada' },
      })
      const recurso = preparar(respaldoRecursoSinRed)

      const r = await recurso({ request: new Request('https://crecer.example/assets/AnalyticsContainer-v2.js') })

      expect(await r?.text()).toBe('chunk v2')
    })

    it('lo que no está en ninguna caché sigue fallando', async () => {
      globalThis.caches = cacheStorageFalso({ [PRECACHE]: {} })
      const recurso = preparar(respaldoRecursoSinRed)

      expect(await recurso({ request: new Request('https://crecer.example/assets/otro.js') })).toBeUndefined()
    })
  })
})
