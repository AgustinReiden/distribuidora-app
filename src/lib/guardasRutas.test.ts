import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  GUARDAS_RUTAS,
  RUTAS_PUBLICAS,
  destinoDeRuta,
  puedeEntrar,
  type FlagsRutas,
  type RutaGuardada,
} from './guardasRutas'

/**
 * Guardas de rol de las rutas del router (#863).
 *
 * Dos partes, y cada una cubre lo que la otra no:
 *
 *  1. MATRIZ: rol × ruta, escrita a mano. NO se deriva de `GUARDAS_RUTAS`: es el
 *     contrato de lo que cada rol puede abrir. Si alguien cambia un predicado de
 *     la tabla (p. ej. `/hoy` a `isPreventista || isAdmin`) la celda deja de
 *     coincidir y esto se pone rojo. Si el cambio es a propósito, se cambia la
 *     matriz en el mismo PR.
 *
 *  2. ESTRUCTURA: lee `src/App.tsx` como texto (como el trinquete de botones
 *     crudos) y comprueba que el router de verdad pasa por la tabla. Sin esto la
 *     matriz probaría una tabla que nadie usa: bastaría volver a escribir una
 *     guarda a mano en App.tsx para que el router y el test se desacoplen en
 *     silencio. Qué cubre, y nada más:
 *       - todo `<Route path="…">` del bloque `<Routes>` está en `GUARDAS_RUTAS` o
 *         en `RUTAS_PUBLICAS`, y toda entrada de las dos tiene su `<Route>`;
 *       - todo `<Route>` de la tabla toma su elemento de `guardar('<su ruta>', …)`
 *         y no escribe un `<Navigate>` ni un flag de rol por su cuenta;
 *       - `guardar` delega en `destinoDeRuta` y le pasa los cuatro flags de rol.
 *     Qué NO cubre: que `isAdmin`, `isPreventista`… se deriven bien del rol
 *     efectivo (eso es de `MainAppInner`, fuera del alcance de este test), ni lo
 *     que muestra el menú (`TopNavigation.test.tsx` tiene su propia tabla).
 *     El parseo es a propósito simple: parte el bloque de rutas en cada
 *     `<Route` y trabaja sobre el texto de cada trozo, sin armar un AST.
 */

type Rol = 'admin' | 'encargado' | 'preventista' | 'transportista' | 'deposito'

const ROLES: readonly Rol[] = ['admin', 'encargado', 'preventista', 'transportista', 'deposito']

// Los flags de cada rol efectivo único. El transportista no enciende ninguno:
// ninguna guarda lo nombra.
const FLAGS_DE: Record<Rol, FlagsRutas> = {
  admin: { isAdmin: true, isPreventista: false, isEncargado: false, isDeposito: false },
  encargado: { isAdmin: false, isPreventista: false, isEncargado: true, isDeposito: false },
  preventista: { isAdmin: false, isPreventista: true, isEncargado: false, isDeposito: false },
  transportista: { isAdmin: false, isPreventista: false, isEncargado: false, isDeposito: false },
  deposito: { isAdmin: false, isPreventista: false, isEncargado: false, isDeposito: true },
}

// Quién entra a cada ruta guardada. El que no está en la lista rebota.
const ENTRAN: Record<RutaGuardada, readonly Rol[]> = {
  '/dashboard': ['admin', 'preventista'],
  '/hoy': ['preventista'],
  '/mis-entregas': ['admin', 'encargado', 'preventista'],
  '/reportes': ['admin'],
  '/usuarios': ['admin'],
  '/proveedores': ['admin'],
  '/promociones': ['admin'],
  '/analytics': ['admin'],
  '/comisiones': ['admin'],
  '/metas': ['admin'],
  '/reportes-gerenciales': ['admin'],
  '/geolocalizacion': ['admin'],
  '/bot-telegram': ['admin'],
  '/condiciones-mayoristas': ['admin'],
  '/configuracion': ['admin', 'encargado'],
  '/recorridos': ['admin', 'encargado'],
  '/recorrido-preventista': ['admin', 'encargado'],
  '/compras': ['admin', 'encargado'],
  '/horarios-clientes': ['admin', 'encargado'],
  '/transferencias': ['admin', 'encargado'],
  '/rendiciones': ['admin', 'encargado'],
  '/salvedades': ['admin', 'encargado'],
  '/vencimientos': ['admin', 'encargado', 'deposito'],
}

const RUTAS = Object.keys(ENTRAN) as RutaGuardada[]

// Adónde rebota quien no entra: /pedidos en todas salvo /bot-telegram.
const sinoEsperado = (ruta: RutaGuardada): string =>
  ruta === '/bot-telegram' ? '/dashboard' : '/pedidos'

describe('guardas de rutas: matriz rol × ruta', () => {
  it('la matriz tiene exactamente las rutas de la tabla', () => {
    expect([...RUTAS].sort()).toEqual(Object.keys(GUARDAS_RUTAS).sort())
  })

  describe.each(RUTAS)('%s', (ruta) => {
    it.each(ROLES)('%s', (rol) => {
      const entra = ENTRAN[ruta].includes(rol)
      expect(puedeEntrar(ruta, FLAGS_DE[rol])).toBe(entra)

      // /condiciones-mayoristas no monta nada: quien entra es redirigido.
      const destino = entra
        ? (ruta === '/condiciones-mayoristas' ? '/productos?vista=condiciones' : null)
        : sinoEsperado(ruta)
      expect(destinoDeRuta(ruta, FLAGS_DE[rol])).toBe(destino)
    })
  })

  it('/hoy es sólo del preventista: ni el admin entra', () => {
    expect(puedeEntrar('/hoy', FLAGS_DE.admin)).toBe(false)
    expect(puedeEntrar('/hoy', FLAGS_DE.preventista)).toBe(true)
  })

  it('el rebote de /bot-telegram es /dashboard y el de todas las demás /pedidos', () => {
    const distintas = RUTAS.filter(ruta => GUARDAS_RUTAS[ruta].sino !== '/pedidos')
    expect(distintas).toEqual(['/bot-telegram'])
    expect(GUARDAS_RUTAS['/bot-telegram'].sino).toBe('/dashboard')
  })
})

describe('guardas de rutas: App.tsx pasa por la tabla', () => {
  const __dirname = path.dirname(fileURLToPath(import.meta.url))
  const appSrc = fs
    .readFileSync(path.resolve(__dirname, '..', 'App.tsx'), 'utf8')
    .replace(/\r\n/g, '\n')

  // El bloque de rutas, sin los comentarios JSX (una frase como "sólo el
  // preventista" no tiene que contar como código), partido en un trozo por
  // `<Route`. `<Routes>` no cuenta: tras `<Route` va una `s`, no un espacio.
  const inicio = appSrc.indexOf('<Routes>')
  const fin = appSrc.indexOf('</Routes>')
  const bloque = appSrc.slice(inicio, fin).replace(/\{\/\*[\s\S]*?\*\/\}/g, '')
  const trozos = bloque.split(/<Route(?=\s)/).slice(1)
  const rutasDeApp = trozos.map(trozo => {
    const m = /\bpath="([^"]+)"/.exec(trozo)
    return { path: m ? m[1] : null, trozo }
  })

  it('encuentra el bloque <Routes> y sus rutas', () => {
    expect(inicio).toBeGreaterThanOrEqual(0)
    expect(fin).toBeGreaterThan(inicio)
    expect(rutasDeApp.length).toBeGreaterThan(0)
    // Un <Route> sin `path="…"` literal no se puede verificar: que falle fuerte.
    expect(rutasDeApp.filter(r => r.path === null)).toEqual([])
  })

  it('todo <Route> está en la tabla o en las públicas, y viceversa', () => {
    const enApp = rutasDeApp.map(r => r.path as string)
    expect(new Set(enApp).size).toBe(enApp.length) // sin paths repetidos
    const enTabla = [...Object.keys(GUARDAS_RUTAS), ...RUTAS_PUBLICAS]
    expect([...enApp].sort()).toEqual([...enTabla].sort())
  })

  it.each(RUTAS)('%s toma su elemento de guardar() con su propia ruta', (ruta) => {
    const entradas = rutasDeApp.filter(r => r.path === ruta)
    expect(entradas).toHaveLength(1)
    const { trozo } = entradas[0]

    // `guardar('<ruta>', <algo>)` como elemento del <Route>. La que sólo
    // redirige (`redirigeA` en la tabla) no monta nada: va con `null`.
    const redirige = 'redirigeA' in GUARDAS_RUTAS[ruta]
    const segundoArg = redirige ? 'null' : '<'
    const escapada = ruta.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    expect(trozo).toMatch(
      new RegExp(`element=\\{\\s*guardar\\(\\s*'${escapada}'\\s*,\\s*${segundoArg}`),
    )

    // Y ninguna guarda escrita a mano al lado.
    expect(trozo).not.toMatch(/<Navigate/)
    expect(trozo).not.toMatch(/\bis(?:Admin|Preventista|Encargado|Deposito|Transportista|AdminOrEncargado)\b|effectiveRol/)
  })

  it('ningún <Route> llama a guardar() con una ruta que no es la suya', () => {
    for (const { path: ruta, trozo } of rutasDeApp) {
      const llamadas = [...trozo.matchAll(/guardar\(\s*'([^']+)'/g)].map(m => m[1])
      expect({ ruta, llamadas }).toEqual({
        ruta,
        llamadas: ruta !== null && ruta in GUARDAS_RUTAS ? [ruta] : [],
      })
    }
  })

  it('guardar() delega en la tabla y le pasa los cuatro flags de rol', () => {
    expect(appSrc).toMatch(/const guardar = [\s\S]*?destinoDeRuta\(\s*ruta,\s*flagsRutas\s*\)/)
    expect(appSrc).toMatch(
      /const flagsRutas: FlagsRutas = \{\s*isAdmin,\s*isPreventista,\s*isEncargado,\s*isDeposito,?\s*\}/,
    )
  })
})
