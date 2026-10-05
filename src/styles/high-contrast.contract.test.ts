import { afterEach, describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import React from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider, useTheme } from '../contexts/ThemeContext'

/**
 * Test de CONTRATO para src/styles/high-contrast.css.
 *
 * Por que existe: high-contrast.css no se puede testear renderizando (jsdom no
 * aplica hojas de estilo), y sus selectores son clases LITERALES de Tailwind
 * (".bg-blue-600", "[class*=\"btn-primary\"]", etc.), invisibles para tsc y
 * para eslint. Si una migracion de UI borra el ultimo "bg-blue-600" de src/,
 * el modo de alto contraste deja de cubrir ese boton y nada se entera.
 *
 * Que hace este archivo:
 *   1) Parsea high-contrast.css (con node:fs, sin CSS parser externo) y
 *      extrae cada selector de clase (".xxx") y cada selector de atributo
 *      ([class*="xxx"]) que aparece en una regla.
 *   2) Recorre src/**\/*.{ts,tsx} (sin tests, sin este propio archivo) y arma
 *      un corpus de todo lo que hay adentro de un string/template literal de
 *      cada archivo — ahi es donde vive un className real.
 *   3) Por cada selector de clase (".xxx") no-huerfano, asevera que aparece
 *      como TOKEN EXACTO en ese corpus. Por cada [class*="xxx"] no-huerfano,
 *      asevera que "xxx" aparece como SUBSTRING de algun token con pinta de
 *      utilidad de Tailwind (ver punto 3-bis: NO alcanza con buscarlo en
 *      cualquier string de src/, ver el bug que eso causaba). Por cada
 *      HUERFANO_CONOCIDO (de cualquiera de las dos listas), asevera que sigue
 *      sin aparecer (si aparece, la lista dejo de ser honesta y hay que
 *      sacarlo de ahi).
 *   3-bis) Bug ya corregido en este archivo: el check de [class*="xxx"] usaba
 *      "el substring aparece en CUALQUIER string literal de src/", que es la
 *      concatenacion de TODOS los strings del codebase, no solo los que son
 *      listas de clases. Con ese criterio, "alert", "error", "success" y
 *      "warning" daban falsos positivos por role="alert" (32 usos), los tipos
 *      de toast 'error'/'success'/'warning' en los containers, ids de
 *      aria-describedby (`error-${field}` en useZodValidation.ts,
 *      'monto-minimo-error' en VistaConfiguracion.tsx), la categoria de
 *      breadcrumb de Sentry 'error-boundary' (ErrorBoundary.tsx) y la columna
 *      SQL 'dias_alerta_vencimiento' — ninguno es una clase CSS, y los cuatro
 *      tests quedaban verdes pasara lo que pasara con esas clases. Por eso el
 *      check de [class*="xxx"] no busca en TODO el corpus: busca solo dentro
 *      de TOKENS_UTILIDAD_TAILWIND (ver mas abajo), que son los tokens
 *      individuales (no strings enteros) con forma de utilidad de Tailwind.
 *      Con ese corpus mas chico, "alert"/"error"/"success"/"warning" pasan a
 *      ser huerfanos genuinos (0 coincidencias), igual que "modal", "overlay"
 *      y "tag".
 *
 * Exclusiones documentadas:
 *   - ".high-contrast" y ".dark": clases de ESTADO que ThemeContext togglea
 *     sobre <html>, no clases de un componente. Buscarlas en src/ no dice
 *     nada (aparecen en decenas de archivos por motivos que no tienen que
 *     ver con este contrato).
 *   - ".reduce-motion": mismo caso que las dos anteriores. ThemeContext la
 *     togglea sobre <html> exactamente igual que "high-contrast" y "dark"
 *     (ver src/contexts/ThemeContext.tsx). No es un exclusion "extra" en el
 *     sentido de una excepcion rara: es la MISMA categoria (clase de estado
 *     del <html>) que las dos que pide el enunciado, y por eso se excluye
 *     con el mismo criterio.
 *
 * Lo que el contrato de mas abajo ("cableado de alto contraste") cierra
 * ademas del parseo de arriba:
 *   - Que ThemeContext.tsx REALMENTE aplique la clase "high-contrast" sobre
 *     <html> (no solo que el texto crudo del archivo contenga el regex del
 *     toggle: eso queda verde con la linea comentada, con el segundo
 *     argumento en `false`, o con el useEffect entero borrado y un
 *     remanente en un comentario). El chequeo de comportamiento renderiza
 *     <ThemeProvider> con un consumidor real y usa userEvent para togglear.
 *   - Que high-contrast.css TODAVIA tenga reglas ".high-contrast ..." y
 *     ".reduce-motion ...": la clase esta excluida de la extraccion de
 *     selectores (con buen motivo, ver arriba), asi que sin este chequeo un
 *     renombre del lado del CSS (".high-contrast" -> ".contraste-alto") deja
 *     a los tests de este archivo en verde con la feature muerta, porque
 *     nadie mira el CSS y ThemeContext.tsx.
 */

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const SRC_DIR = path.resolve(__dirname, '..')
const CSS_PATH = path.join(__dirname, 'high-contrast.css')
const MAIN_TSX_PATH = path.join(SRC_DIR, 'main.tsx')
const THEME_CONTEXT_PATH = path.join(SRC_DIR, 'contexts', 'ThemeContext.tsx')

// -----------------------------------------------------------------------
// 1) Extraccion de selectores desde high-contrast.css
// -----------------------------------------------------------------------

const CLASES_DE_ESTADO_EXCLUIDAS = new Set<string>(['high-contrast', 'dark', 'reduce-motion'])

/** ".dark\:bg-gray-800" -> "dark:bg-gray-800" · ".bg-black\/50" -> "bg-black/50" */
function desescaparClaseCss(crudo: string): string {
  return crudo.replace(/\\([:/.[\]])/g, '$1')
}

interface SelectoresExtraidos {
  clases: string[]
  atributosSubstring: string[]
}

/**
 * Extrae, de un CSS plano (sin @media ni reglas anidadas, que es lo que hay
 * en high-contrast.css hoy), cada selector de clase (".xxx", con escapes CSS
 * ya des-escapados al token real de Tailwind) y cada selector de atributo
 * [class*="xxx"].
 */
function extraerSelectores(cssCrudo: string): SelectoresExtraidos {
  const sinComentarios = cssCrudo.replace(/\/\*[\s\S]*?\*\//g, '')
  // Nos quedamos solo con las LISTAS de selectores: cada bloque de
  // declaraciones "{ ... }" se reemplaza por un espacio. No hay reglas
  // anidadas en este archivo, asi que un reemplazo plano alcanza.
  const soloSelectores = sinComentarios.replace(/\{[^}]*\}/g, ' ')

  const clases = new Set<string>()
  const claseRe = /\.((?:\\.|[A-Za-z0-9_-])+)/g
  let matchClase: RegExpExecArray | null
  while ((matchClase = claseRe.exec(soloSelectores))) {
    const nombre = desescaparClaseCss(matchClase[1])
    if (!CLASES_DE_ESTADO_EXCLUIDAS.has(nombre)) {
      clases.add(nombre)
    }
  }

  const atributosSubstring = new Set<string>()
  const atributoRe = /\[class\*="([^"]+)"\]/g
  let matchAtributo: RegExpExecArray | null
  while ((matchAtributo = atributoRe.exec(soloSelectores))) {
    atributosSubstring.add(matchAtributo[1])
  }

  return { clases: [...clases], atributosSubstring: [...atributosSubstring] }
}

const cssCrudo = fs.readFileSync(CSS_PATH, 'utf-8')
const { clases: CLASES_CSS, atributosSubstring: ATRIBUTOS_CSS } = extraerSelectores(cssCrudo)

// -----------------------------------------------------------------------
// 2) Corpus de src/**/*.{ts,tsx}: solo lo que hay dentro de un string o
//    template literal (que es donde vive un className real).
// -----------------------------------------------------------------------
//
// Por que no alcanza con buscar el token "delimitado por espacios, comillas
// o backticks" directo sobre el texto crudo del archivo: un identificador
// JS puede quedar delimitado por espacios sin ser una clase. Por ejemplo
// `const { bg, icon, btn } = iconConfig[...]` en ModalConfirmacion.tsx deja
// "btn" rodeado de espacios sin que sea jamas una clase CSS aplicada — el
// className real interpola la VARIABLE (`${btn}`), no la palabra "btn". Un
// grep ingenuo sobre texto crudo cuenta ese falso positivo; extraer primero
// el contenido de los strings/template literals lo evita.
//
// Tambien hace falta ser comment-aware: un comentario en español con una
// comilla suelta (p. ej. una cita) puede arrancar un "string" fantasma que
// el proximo comentario cierra varios archivos-equivalentes de texto mas
// adelante, contaminando el corpus con basura. Por eso el tokenizer de abajo
// saca "// ..." y "/* ... */" ANTES de mirar comillas, en una sola pasada.
//
// Y los specifiers de import/require ("../modals/ModalCliente") son un
// string literal como cualquier otro, pero no son una clase: si no se sacan,
// un import a "modals/ModalCliente" alimenta falso-positivamente
// [class*="modal"]. Por eso se neutralizan antes de tokenizar.

function listarArchivosFuente(dir: string): string[] {
  const resultado: string[] = []
  for (const entrada of fs.readdirSync(dir, { withFileTypes: true })) {
    const rutaCompleta = path.join(dir, entrada.name)
    if (entrada.isDirectory()) {
      resultado.push(...listarArchivosFuente(rutaCompleta))
      continue
    }
    if (!/\.(ts|tsx)$/.test(entrada.name)) continue
    if (entrada.name.includes('.test.')) continue
    resultado.push(rutaCompleta)
  }
  return resultado
}

function quitarRutasDeImport(codigo: string): string {
  return codigo
    .replace(/\bfrom\s+(["'])(?:[^"'\\]|\\.)*\1/g, 'from IMPORT_PATH')
    .replace(/\bimport\s*\(\s*(["'])(?:[^"'\\]|\\.)*\1\s*\)/g, 'import(IMPORT_PATH)')
    .replace(/\brequire\s*\(\s*(["'])(?:[^"'\\]|\\.)*\1\s*\)/g, 'require(IMPORT_PATH)')
}

/**
 * Tokenizer minimo a mano (no un parser de JS completo): recorre el codigo
 * caracter a caracter, salta comentarios de linea y de bloque, y devuelve el
 * contenido interior de cada string ("...", '...') y template literal
 * (`...`). Dentro de un template, una interpolacion `${...}` se reemplaza
 * por un espacio (no es texto de clase) contando llaves para saber donde
 * termina, incluso si el codigo interior vuelve a abrir `{`.
 */
function extraerLiteralesDeCadena(codigoOriginal: string): string[] {
  const codigo = quitarRutasDeImport(codigoOriginal)
  const literales: string[] = []
  let i = 0
  const n = codigo.length
  while (i < n) {
    const c = codigo[i]
    const c2 = codigo[i + 1]

    if (c === '/' && c2 === '/') {
      i += 2
      while (i < n && codigo[i] !== '\n') i++
      continue
    }
    if (c === '/' && c2 === '*') {
      i += 2
      while (i < n && !(codigo[i] === '*' && codigo[i + 1] === '/')) i++
      i += 2
      continue
    }
    if (c === '"' || c === "'") {
      const comilla = c
      let j = i + 1
      let buf = ''
      while (j < n && codigo[j] !== comilla) {
        if (codigo[j] === '\\') { buf += ' '; j += 2; continue }
        buf += codigo[j]
        j++
      }
      literales.push(buf)
      i = j + 1
      continue
    }
    if (c === '`') {
      let j = i + 1
      let buf = ''
      let profundidadInterpolacion = 0
      while (j < n) {
        if (codigo[j] === '\\') { buf += ' '; j += 2; continue }
        if (profundidadInterpolacion === 0 && codigo[j] === '`') { j++; break }
        if (profundidadInterpolacion === 0 && codigo[j] === '$' && codigo[j + 1] === '{') {
          buf += ' '
          profundidadInterpolacion = 1
          j += 2
          continue
        }
        if (profundidadInterpolacion > 0) {
          if (codigo[j] === '{') profundidadInterpolacion++
          else if (codigo[j] === '}') profundidadInterpolacion--
          j++
          continue
        }
        buf += codigo[j]
        j++
      }
      literales.push(buf)
      i = j
      continue
    }
    i++
  }
  return literales
}

interface CorpusFuente {
  /** Cada "palabra" (separada por espacios) encontrada dentro de un literal. */
  palabras: Set<string>
  /** Todos los literales concatenados, para busqueda por substring. */
  comoTexto: string
  archivosEscaneados: number
}

function construirCorpusDeSrc(): CorpusFuente {
  const palabras = new Set<string>()
  const partes: string[] = []
  const archivos = listarArchivosFuente(SRC_DIR)
  for (const archivo of archivos) {
    const contenido = fs.readFileSync(archivo, 'utf-8')
    for (const interior of extraerLiteralesDeCadena(contenido)) {
      partes.push(interior)
      for (const palabra of interior.split(/\s+/)) {
        if (palabra) palabras.add(palabra)
      }
    }
  }
  return { palabras, comoTexto: partes.join(' '), archivosEscaneados: archivos.length }
}

const CORPUS = construirCorpusDeSrc()

// -----------------------------------------------------------------------
// 2-bis) Sub-corpus para los checks de [class*="xxx"]: SOLO los tokens (no
// strings enteros) de CORPUS.palabras que tienen forma de utilidad de
// Tailwind. Ver el punto 3-bis del docstring de arriba: el bug que esto
// corrige era buscar el substring en CUALQUIER string de src/ (comentarios,
// mensajes de error, ids de aria-describedby, categorias de Sentry,
// columnas SQL...), no solo en los que son listas de clases.
//
// El regex es una heuristica, no un parser de Tailwind: un token pasa el
// filtro si tiene la forma "(variante:)*-?utilidad(-sufijo)*", donde
// "utilidad" es uno de los prefijos de Tailwind que aparecen en este CSS
// (bg, text, border, rounded, p/px/py, m, w, h, flex, grid, gap, items,
// justify, font, shadow, opacity, z, ring, outline, cursor, overflow,
// transition, animate, fill, stroke, sr) mas "btn". Verificado a mano sobre el
// corpus actual (~59500 palabras, ~900 pasan el filtro): "border" y "shadow"
// siguen dando >0 coincidencias (135 y 13 tokens respectivamente), "bg-" y
// "text-" tambien (273 y 201), y "alert"/"error"/"success"/"warning"/"modal"/
// "overlay"/"tag" dan 0 — son huerfanos genuinos, no un artefacto de busqueda
// por substring sobre texto libre.
//
// Por que "btn" esta en la lista si NO es una utilidad de Tailwind: "btn-primary"
// no pinta nada por si sola, es el gancho literal que Button variant="primary"
// (src/components/ui/button-variants.ts) emite para que [class*="btn-primary"]
// de este CSS lo alcance. Es una clase real de un className real; sin este
// prefijo el filtro la descartaria por su forma y el selector parecería huerfano
// teniendo cobertura.
const UTILIDAD_TAILWIND_RE =
  /^(?:[a-z][a-z0-9-]*:)*-?(bg|text|border|rounded|p|px|py|m|w|h|flex|grid|gap|items|justify|font|shadow|opacity|z|ring|outline|cursor|overflow|transition|animate|fill|stroke|sr|btn)(-[a-z0-9./[\]%()#]+)*$/

const TOKENS_UTILIDAD_TAILWIND = new Set(
  [...CORPUS.palabras].filter(palabra => UTILIDAD_TAILWIND_RE.test(palabra))
)

/**
 * true si `substring` aparece DENTRO de algun token de src/ que ademas tiene
 * pinta de utilidad de Tailwind — no si aparece en cualquier string de
 * src/. Esto es lo que reemplaza a `CORPUS.comoTexto.includes(substring)`
 * para los checks de [class*="xxx"].
 */
function apareceComoSubstringDeUtilidadTailwind(substring: string): boolean {
  for (const token of TOKENS_UTILIDAD_TAILWIND) {
    if (token.includes(substring)) return true
  }
  return false
}

// -----------------------------------------------------------------------
// 3) Huerfanos conocidos: selectores de high-contrast.css que HOY no
//    matchean ningun elemento real en src/. Verificados a mano (ver el
//    porque de cada uno) contra el corpus de arriba.
// -----------------------------------------------------------------------

const HUERFANOS_CONOCIDOS_CLASES = new Set<string>([
  // Todas las apariciones en src/ son "hover:bg-gray-300", "dark:bg-gray-300"
  // o "disabled:bg-gray-300" — clases DISTINTAS para Tailwind (cada variante
  // es un token propio). El selector ".bg-gray-300" a secas no matchea
  // ninguna de esas.
  'bg-gray-300',
  // Es el NOMBRE DE UNA VARIABLE en ModalConfirmacion.tsx
  // (`const { bg, icon, btn } = iconConfig[...]`), interpolada como
  // `${btn}` en el className. El texto literal "btn" nunca queda como clase.
  'btn',
  // "card" no aparece como clase; solo como palabra suelta en comentarios
  // ("la card", "del card") y como parte de OTRO token, "card-in" (nombre
  // de una animacion en tailwind.config.js), que no es "card".
  'card',
  // Mismo patron que "btn": "badge" solo aparece como property key de un
  // objeto de estilos (`badge: 'bg-emerald-100 ...'`) o como palabra suelta
  // en comentarios/prosa. El valor de esa property nunca es literalmente
  // la palabra "badge".
  'badge',
  // Unica aparicion es "dark:text-yellow-500" (variante), igual que
  // bg-gray-300 arriba.
  'text-yellow-500',
  // No aparece en absoluto en src/ (ni como clase ni en comentarios). Tailwind
  // trae `.sr-only` de fabrica pero NO `.sr-only-focusable` (es convencion de
  // Bootstrap): nada en la app la usa hoy.
  'sr-only-focusable',
])

const HUERFANOS_CONOCIDOS_ATRIBUTOS = new Set<string>([
  // "btn-primary" ya NO es huerfano: lo emite Button variant="primary"
  // (src/components/ui/button-variants.ts) como gancho literal para que
  // [class*="btn-primary"] cubra al primario nuevo, que pinta con `brand` y no
  // con `blue`. Si algun dia se saca ese gancho del primitivo, este selector
  // vuelve a esta lista.
  //
  // El unico lugar donde aparece el substring "modal" dentro de un string es
  // en specifiers de import ("../modals/ModalCliente"), que se neutralizan
  // antes de armar el corpus (ver quitarRutasDeImport). Ninguna clase real
  // contiene "modal".
  'modal',
  // "overlay" solo aparece en comentarios (nunca en un string/className).
  'overlay',
  // "tag" solo aparece como identificador JS (`tags:` en ErrorBoundary.tsx,
  // Sentry) o dentro de otras palabras; nunca dentro de un string de clase.
  'tag',
  // Corregido: antes este archivo buscaba "alert" en CUALQUIER string de
  // src/ (CORPUS.comoTexto), y ahi SI aparece — pero solo como
  // role="alert" (32 usos) y como parte de la columna SQL
  // 'dias_alerta_vencimiento' (usePoliticasComercialesQuery.ts, contiene
  // "alerta" que a su vez contiene "alert"), nunca como clase. Contra
  // TOKENS_UTILIDAD_TAILWIND (que filtra por FORMA de utilidad de Tailwind,
  // no por substring libre) da 0 coincidencias: es un huerfano genuino.
  'alert',
  // Mismo bug, mismo fix. "error" aparecia en CUALQUIER string de src/ por
  // los tipos de toast/confirmacion ('error' en los containers), ids de
  // aria-describedby (`error-${field}` en useZodValidation.ts,
  // 'monto-minimo-error' en VistaConfiguracion.tsx) y la categoria de
  // breadcrumb de Sentry 'error-boundary' (ErrorBoundary.tsx) — ninguno es
  // una clase CSS. 0 coincidencias contra TOKENS_UTILIDAD_TAILWIND.
  'error',
  // Mismo bug, mismo fix: "success" solo aparecia como tipo de
  // toast/confirmacion ('success' en los containers), nunca como clase.
  'success',
  // Mismo bug, mismo fix: "warning" solo aparecia como tipo de
  // toast/confirmacion ('warning' en los containers, p. ej.
  // PedidosContainer.tsx), nunca como clase.
  'warning',
])

// -----------------------------------------------------------------------
// 4) Los tests
// -----------------------------------------------------------------------

describe('contrato: parser de high-contrast.css (sanity check)', () => {
  // Antes esto fijaba solo la CANTIDAD (28 y 12). Un swap 1-a-1 en el CSS
  // (sacar ".bg-blue-600" y agregar ".bg-indigo-600" en el mismo PR)
  // mantenia el conteo en 28 sin que nada se pusiera rojo: el `it` del
  // selector viejo simplemente dejaba de generarse (los tests de la
  // describe de "selectores de clase" nacen de un `for (const clase of CLASES_CSS)`), y un test que
  // no existe nunca falla. Fijar el CONJUNTO ordenado en vez del largo hace
  // que ese swap se note: vitest muestra el diff exacto (que selector entro,
  // cual salio).
  it('extrajo exactamente el conjunto de selectores de clase esperado', () => {
    const ESPERADAS = [
      'badge',
      'bg-black/50',
      'bg-blue-500',
      'bg-blue-600',
      // Lo emite Button variant="primary" (src/components/ui/button-variants.ts):
      // el primitivo pinta con la escala `brand`, no con `blue`, asi que la regla
      // del primario tuvo que sumar el selector para seguir cubriendolo.
      'bg-brand-600',
      'bg-gray-100',
      'bg-gray-200',
      'bg-gray-300',
      'bg-gray-50',
      'bg-green-500',
      'bg-green-600',
      // Lo emite Button variant="success" (green-700, porque green-600 con
      // texto blanco no llega a AA): la regla de exito lo sumo para que un
      // boton migrado no caiga en el generico monocromo.
      'bg-green-700',
      'bg-red-500',
      'bg-red-600',
      'bg-white',
      // El riel de Card con accent (src/components/ui/Card.tsx, mapa ACENTO): la
      // regla de #815 lo mantiene en 6px en alto contraste.
      'border-l-4',
      'btn',
      'card',
      'dark:bg-gray-800',
      'dark:bg-gray-900',
      'rounded-full',
      'rounded-lg',
      'rounded-xl',
      'sr-only',
      'sr-only-focusable',
      'text-green-500',
      'text-green-600',
      'text-red-500',
      'text-red-600',
      'text-yellow-500',
      'text-yellow-600',
    ]
    expect(
      [...CLASES_CSS].sort(),
      'El conjunto de selectores ".xxx" de high-contrast.css cambio. Si fue a proposito ' +
        '(sumaste/sacaste una regla), actualiza la lista ESPERADAS de este test Y revisa ' +
        'HUERFANOS_CONOCIDOS_CLASES. Si no tocaste el CSS a proposito, alguien agrego un ' +
        '@media o una regla anidada: el parser de este archivo es plano (reemplaza "{...}" ' +
        'por un espacio) y descarta selectores anidados en silencio — hay que enseñarle a ' +
        'anidar antes de tocar esta lista.'
    ).toEqual(ESPERADAS)
  })

  it('extrajo exactamente el conjunto de selectores [class*="..."] esperado', () => {
    const ESPERADOS = [
      'alert',
      'bg-',
      'border',
      'btn-primary',
      'error',
      'modal',
      'overlay',
      'shadow',
      'success',
      'tag',
      'text-',
      'warning',
    ]
    expect(
      [...ATRIBUTOS_CSS].sort(),
      'El conjunto de selectores [class*="..."] de high-contrast.css cambio. Si fue a ' +
        'proposito, actualiza la lista ESPERADOS de este test Y revisa ' +
        'HUERFANOS_CONOCIDOS_ATRIBUTOS. Si no tocaste el CSS a proposito, alguien agrego un ' +
        '@media o una regla anidada: el parser de este archivo es plano y descarta selectores ' +
        'anidados en silencio — hay que enseñarle a anidar antes de tocar esta lista.'
    ).toEqual(ESPERADOS)
  })

  it('escaneo al menos un archivo de src/ para armar el corpus', () => {
    // Cinturon y tiradores: si esto da 0, listarArchivosFuente esta rota
    // (por ejemplo, apuntando a un directorio que no existe) y TODOS los
    // tests de "no-huerfano" de abajo pasarian en falso por falta de datos.
    expect(CORPUS.archivosEscaneados).toBeGreaterThan(300)
  })

  it('el heuristico de utilidades Tailwind encontro suficientes tokens en el corpus', () => {
    // Mismo espiritu que el check de arriba, pero para el sub-corpus de la
    // seccion 2-bis: si UTILIDAD_TAILWIND_RE se rompe (por ejemplo, un typo
    // que la deja sin matchear nada), TOKENS_UTILIDAD_TAILWIND queda vacio y
    // los checks de [class*="..."] del describe de mas abajo fallarian TODOS —
    // incluidos "border" y "shadow", que hoy tienen cobertura real. Un
    // umbral bajo (muy por debajo de los ~900 actuales) alcanza para
    // detectar "la regex dejo de matchear nada" sin ser fragil ante cambios
    // normales del codebase.
    expect(TOKENS_UTILIDAD_TAILWIND.size).toBeGreaterThan(300)
  })
})

describe('contrato: selectores de clase (".xxx") de high-contrast.css', () => {
  for (const clase of CLASES_CSS) {
    const esHuerfanoConocido = HUERFANOS_CONOCIDOS_CLASES.has(clase)
    const titulo = esHuerfanoConocido
      ? `".${clase}" sigue siendo un huerfano conocido (no deberia aparecer en src/)`
      : `".${clase}" sigue usandose en src/ (el alto contraste todavia lo cubre)`

    it(titulo, () => {
      const aparece = CORPUS.palabras.has(clase)
      if (esHuerfanoConocido) {
        expect(
          aparece,
          `El huerfano conocido "${clase}" empezo a aparecer en src/: sacalo de ` +
            'HUERFANOS_CONOCIDOS_CLASES en high-contrast.contract.test.ts, la lista dejo de ser honesta.'
        ).toBe(false)
      } else {
        expect(
          aparece,
          `La clase "${clase}" ya no existe en src/: actualiza src/styles/high-contrast.css en el mismo PR ` +
            'para que el alto contraste siga cubriendo ese elemento (o, si la quita fue a proposito, sumala a ' +
            'HUERFANOS_CONOCIDOS_CLASES en este archivo).'
        ).toBe(true)
      }
    })
  }
})

describe('contrato: selectores de atributo [class*="..."] de high-contrast.css', () => {
  for (const atributo of ATRIBUTOS_CSS) {
    const esHuerfanoConocido = HUERFANOS_CONOCIDOS_ATRIBUTOS.has(atributo)
    const titulo = esHuerfanoConocido
      ? `[class*="${atributo}"] sigue siendo un huerfano conocido (no deberia matchear nada en src/)`
      : `[class*="${atributo}"] sigue matcheando algo en src/ (el alto contraste todavia lo cubre)`

    it(titulo, () => {
      // OJO: esto NO busca en cualquier string de src/ (CORPUS.comoTexto) —
      // eso es lo que causaba que "alert"/"error"/"success"/"warning"
      // dieran falso-positivo por role="alert", tipos de toast, ids de
      // aria-describedby, etc. Busca solo dentro de tokens con pinta de
      // utilidad de Tailwind (ver seccion 2-bis).
      const aparece = apareceComoSubstringDeUtilidadTailwind(atributo)
      if (esHuerfanoConocido) {
        expect(
          aparece,
          `El huerfano conocido [class*="${atributo}"] empezo a matchear un token con pinta de clase Tailwind ` +
            'en src/: sacalo de HUERFANOS_CONOCIDOS_ATRIBUTOS en high-contrast.contract.test.ts, la lista dejo ' +
            'de ser honesta.'
        ).toBe(false)
      } else {
        expect(
          aparece,
          `El substring "${atributo}" (selector [class*="${atributo}"]) ya no aparece dentro de ningun token ` +
            'con pinta de clase Tailwind en src/: actualiza src/styles/high-contrast.css en el mismo PR (o, si ' +
            'la quita fue a proposito, sumalo a HUERFANOS_CONOCIDOS_ATRIBUTOS en este archivo).'
        ).toBe(true)
      }
    })
  }
})

// -----------------------------------------------------------------------
// 5) El hover de un botón no deja sus rótulos 1:1
// -----------------------------------------------------------------------
//
// `.high-contrast button:hover` invierte fondo y color del botón, pero
// `.high-contrast span/p/div` le fuerza el color primario a CADA hijo: con el
// fondo ya invertido, el rótulo en <span> (ícono + <span>texto</span>, casi
// todos los botones) quedaba del color del fondo. Lo arreglan dos reglas que
// hacen heredar el color invertido; jsdom no aplica hojas de estilo, así que
// se fijan acá por texto. Los selectores se comparan ENTEROS a propósito: su
// forma es la que les da la especificidad ((0,3,2) o más) con la que le ganan a
// `.high-contrast span` (0,1,1) y a `.high-contrast svg[class*="text-"]` (0,2,1),
// todas con !important. Un "simplificado" a `.high-contrast button:hover span`
// sigue ganando, pero pierde el `:not([class*="bg-"])` que deja a los badges
// con su propio texto sobre su propio fondo.

interface ReglaCss {
  selectores: string[]
  cuerpo: string
}

/** Parte una lista de selectores por las comas de primer nivel (no las de `:is(a, b)`). */
function partirSelectores(lista: string): string[] {
  const partes: string[] = []
  let profundidad = 0
  let actual = ''
  for (const c of lista) {
    if (c === '(') profundidad++
    if (c === ')') profundidad--
    if (c === ',' && profundidad === 0) {
      partes.push(actual)
      actual = ''
      continue
    }
    actual += c
  }
  partes.push(actual)
  return partes.map(s => s.trim().replace(/\s+/g, ' '))
}

/** Las reglas del CSS plano (mismo supuesto que extraerSelectores: sin anidar). */
function reglasDelCss(css: string): ReglaCss[] {
  const sinComentarios = css.replace(/\/\*[\s\S]*?\*\//g, '')
  const reglas: ReglaCss[] = []
  const reglaRe = /([^{}]+)\{([^}]*)\}/g
  let match: RegExpExecArray | null
  while ((match = reglaRe.exec(sinComentarios))) {
    reglas.push({ selectores: partirSelectores(match[1]), cuerpo: match[2] })
  }
  return reglas
}

const REGLAS_CSS = reglasDelCss(cssCrudo)
const HOVERS_DE_BOTON = ['button:hover', '[role="button"]:hover', '.btn:hover'] as const

function reglaConSelector(selector: string): ReglaCss | undefined {
  return REGLAS_CSS.find(regla => regla.selectores.includes(selector))
}

describe('contrato: el hover de un botón no deja sus rótulos 1:1', () => {
  it.each(HOVERS_DE_BOTON)('".high-contrast %s" sigue invirtiendo fondo y texto (el motivo de las reglas de abajo)', hover => {
    const regla = reglaConSelector(`.high-contrast ${hover}`)
    expect(regla, `No hay regla ".high-contrast ${hover}" en high-contrast.css`).toBeDefined()
    expect(regla?.cuerpo).toMatch(/background-color:\s*var\(--color-text-primary\)\s*!important/)
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*var\(--color-bg-primary\)\s*!important/)
  })

  it.each(HOVERS_DE_BOTON)('en "%s" los span/p/div sin fondo propio heredan el color invertido', hover => {
    const selector = `.high-contrast ${hover} :is(span, p, div):not([class*="bg-"])`
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, el rótulo en <span> de un botón en hover ` +
        'queda forzado al color primario sobre el fondo ya invertido (1:1, invisible).'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/color:\s*inherit\s*!important/)
  })

  it.each(HOVERS_DE_BOTON)('en "%s" los íconos con text-* heredan el color invertido', hover => {
    const selector = `.high-contrast ${hover} svg[class*="text-"]`
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, \`.high-contrast svg[class*="text-"]\` le ` +
        'fuerza el color primario al ícono y desaparece contra el fondo invertido del botón.'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/color:\s*inherit\s*!important/)
  })
})

// -----------------------------------------------------------------------
// 6) Donde el hover NO invierte el fondo, los rótulos no heredan
// -----------------------------------------------------------------------
//
// Las reglas de la sección 5 dan por hecho que el hover invirtió el FONDO del
// botón. En dos casos otra regla le gana el fondo y lo deja fijo, mientras el
// color del botón sí se invierte: el deshabilitado (--color-bg-secondary) y,
// en modo oscuro, el de `dark:bg-gray-800/900` (negro). Heredar ahí dejaba el
// rótulo del color del fondo: blanco sobre #f0f0f0 en claro, negro sobre negro
// en oscuro (medido en Chromium con la hoja real). Las excepciones devuelven
// los hijos al color primario, como antes de la herencia.
//
// Se fijan los DOS lados. Si desaparece la regla que fija el fondo (o el
// deshabilitado sube por encima del hover en la hoja), el fondo vuelve a
// invertirse y la excepción pasa a ser el bug: color primario sobre el fondo
// invertido. Por eso se asevera también el motivo, no sólo la excepción.

const FONDOS_FIJOS_EN_HOVER = [
  {
    caso: 'deshabilitado',
    boton: '.high-contrast button:disabled:hover',
    fija: '.high-contrast button:disabled',
    fondo: '--color-bg-secondary',
  },
  {
    caso: 'modo oscuro con dark:bg-gray-800',
    boton: '.high-contrast.dark button.dark\\:bg-gray-800:hover',
    fija: '.high-contrast.dark .dark\\:bg-gray-800',
    fondo: '--color-bg-primary',
  },
  {
    caso: 'modo oscuro con dark:bg-gray-900',
    boton: '.high-contrast.dark button.dark\\:bg-gray-900:hover',
    fija: '.high-contrast.dark .dark\\:bg-gray-900',
    fondo: '--color-bg-primary',
  },
] as const

describe('contrato: donde el hover no invierte el fondo, los rótulos no heredan', () => {
  it.each(FONDOS_FIJOS_EN_HOVER)('$caso: sigue la regla que le fija el fondo (el motivo de la excepción)', ({ fija, fondo }) => {
    const regla = reglaConSelector(fija)
    expect(regla, `No hay regla "${fija}" en high-contrast.css: si ya no fija el fondo, sacá también su excepción`).toBeDefined()
    expect(regla?.cuerpo).toMatch(new RegExp(`background-color:\\s*var\\(${fondo}\\)\\s*!important`))
  })

  it('el deshabilitado le gana el fondo al hover por orden: misma especificidad, va después en la hoja', () => {
    const hover = REGLAS_CSS.findIndex(regla => regla.selectores.includes('.high-contrast button:hover'))
    const deshabilitado = REGLAS_CSS.findIndex(regla => regla.selectores.includes('.high-contrast button:disabled'))

    expect(hover).toBeGreaterThanOrEqual(0)
    expect(deshabilitado).toBeGreaterThan(hover)
  })

  it.each(FONDOS_FIJOS_EN_HOVER)('$caso: span/p/div sin fondo propio vuelven al color primario', ({ boton }) => {
    const selector = `${boton} :is(span, p, div):not([class*="bg-"])`
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, el rótulo hereda el color invertido del botón ` +
        'sobre un fondo que no se invirtió (1:1, invisible).'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/color:\s*var\(--color-text-primary\)\s*!important/)
  })

  it.each(FONDOS_FIJOS_EN_HOVER)('$caso: los íconos con text-* vuelven al color primario', ({ boton }) => {
    const selector = `${boton} svg[class*="text-"]`
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, el ícono hereda el color invertido del botón ` +
        'sobre un fondo que no se invirtió.'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/color:\s*var\(--color-text-primary\)\s*!important/)
  })
})

// -----------------------------------------------------------------------
// 7) El rótulo en <span> de un botón hereda el color de su botón (#756)
// -----------------------------------------------------------------------
//
// `.high-contrast span` (0,1,1) le fuerza el color primario a todo <span>. En un
// botón que pinta su propio fondo con el color primario (el primario con el
// gancho `btn-primary`: fondo --color-text-primary, texto --color-bg-primary) el
// rótulo en <span> (`<span className="hidden sm:inline">Guardar</span>`) quedaba
// negro sobre negro, 1:1; en el de peligro y el de éxito, negro sobre rojo o
// verde oscuro, 2,1:1. La regla de abajo lo hace heredar el color de su botón.
//
// Se fija el selector ENTERO. El `:where(:not([class*="bg-"]))` no es adorno:
// deja afuera a los <span> que pintan su propio fondo (un contador, un chip), que
// con un `color: inherit` a secas heredarían el blanco del botón sobre su propio
// fondo claro (medido en Chromium: 17,2:1 pasa a 1,2:1). Y va dentro de `:where()`
// para no sumar especificidad: así la regla (0,1,2) le gana a `.high-contrast
// span` (0,1,1) y sigue perdiendo contra los colores por clase (`.text-red-500`,
// (0,2,0)).

const BOTONES_CON_SPAN = ['button', '[role="button"]'] as const

describe('contrato: el rótulo en <span> de un botón hereda el color de su botón', () => {
  it('sigue la regla que le fuerza el color primario a todo <span> (el motivo de la herencia)', () => {
    const regla = reglaConSelector('.high-contrast span')
    expect(regla, 'No hay regla ".high-contrast span" en high-contrast.css: si ya no fuerza el color, sacá también la herencia').toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*var\(--color-text-primary\)\s*!important/)
  })

  it('el primario sigue pintando fondo y texto con colores opuestos (de ahí el negro sobre negro)', () => {
    const regla = reglaConSelector('.high-contrast [class*="btn-primary"]')
    expect(regla, 'No hay regla para [class*="btn-primary"] en high-contrast.css').toBeDefined()
    expect(regla?.cuerpo).toMatch(/background-color:\s*var\(--color-text-primary\)\s*!important/)
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*var\(--color-bg-primary\)\s*!important/)
  })

  it.each(BOTONES_CON_SPAN)('en "%s" el <span> sin fondo propio hereda el color del botón', boton => {
    const selector = `.high-contrast ${boton} > span:where(:not([class*="bg-"]))`
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, ".high-contrast span" le fuerza el color primario ` +
        'al rótulo en <span> de un botón y queda del color de su fondo (negro sobre negro en el primario).'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*inherit\s*!important/)
  })
})

// -----------------------------------------------------------------------
// 8) El hover no invierte el texto directo donde no invierte el fondo (#792)
// -----------------------------------------------------------------------
//
// Las reglas de la sección 6 devuelven al color primario a los HIJOS del botón.
// Falta el texto que va DIRECTO en el <button> (sin <span>): no hay hijo al que
// heredarle nada, y el `color: var(--color-bg-primary)` de `.high-contrast
// button:hover` cae sobre un fondo que no se invirtió: blanco sobre #f0f0f0 en el
// deshabilitado, negro sobre negro en `dark:bg-gray-800/900` (medido en Chromium).
//
// La especificidad de estas reglas es a propósito (0,2,1), la de `button:hover`, y
// gana por ORDEN. Con `.high-contrast` pelado serían (0,3,1) y le pasarían por
// encima a las reglas de color de los botones de estado en modo oscuro
// (`.high-contrast.dark .bg-red-600` y `.bg-green-*`, (0,3,0), texto negro sobre
// rojo o verde fluor), que ya aciertan en hover: un deshabilitado `bg-green-700`
// pasaba de 15,3:1 a 1,37:1. El `:where()` saca `.high-contrast` y `.dark` de la
// cuenta; por eso se compara el selector entero.

const TEXTO_DIRECTO_SIN_INVERTIR = [
  { caso: 'deshabilitado', selector: ':where(.high-contrast) button:disabled:hover' },
  { caso: 'modo oscuro con dark:bg-gray-800', selector: ':where(.high-contrast.dark) button.dark\\:bg-gray-800:hover' },
  { caso: 'modo oscuro con dark:bg-gray-900', selector: ':where(.high-contrast.dark) button.dark\\:bg-gray-900:hover' },
] as const

describe('contrato: el hover no invierte el texto directo donde no invierte el fondo', () => {
  it.each(TEXTO_DIRECTO_SIN_INVERTIR)('$caso: el texto directo vuelve al color primario', ({ selector }) => {
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, ".high-contrast button:hover" invierte el color ` +
        'del texto directo del botón sobre un fondo que no se invirtió (1:1, invisible).'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*var\(--color-text-primary\)\s*!important/)
  })

  it.each(TEXTO_DIRECTO_SIN_INVERTIR)('$caso: va después de ".high-contrast button:hover" (misma especificidad, gana por orden)', ({ selector }) => {
    const hover = REGLAS_CSS.findIndex(regla => regla.selectores.includes('.high-contrast button:hover'))
    const excepcion = REGLAS_CSS.findIndex(regla => regla.selectores.includes(selector))

    expect(hover).toBeGreaterThanOrEqual(0)
    expect(excepcion).toBeGreaterThan(hover)
  })

  it.each(['.high-contrast.dark .bg-red-600', '.high-contrast.dark .bg-green-700'])(
    'sigue la regla de color de "%s" en modo oscuro (la que estas excepciones no pueden pisar)',
    selector => {
      const regla = reglaConSelector(selector)
      expect(regla, `No hay regla "${selector}" en high-contrast.css`).toBeDefined()
      expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*#000000\s*!important/)
    }
  )
})

// -----------------------------------------------------------------------
// 9) El riel de color de Card con accent se conserva (#815)
// -----------------------------------------------------------------------
//
// `Card` con `accent` pinta un riel a la izquierda (`border-l-4 border-l-<tono>`,
// mapa ACENTO de Card.tsx). La regla genérica de tarjetas pone `border: 2px solid`
// con !important, que le gana al `border-l-4` sin importar la especificidad: el
// riel quedaba en un borde parejo de 2px (medido: de 4px a 2px). En alto contraste
// el riel se conserva en 6px, con el color de borde del modo y sin tono por
// estado (el estado se lee por el texto del badge). Misma especificidad (0,2,0)
// que la genérica: gana por ORDEN.

describe('contrato: el riel de color de Card con accent se conserva en alto contraste', () => {
  it('sigue la regla genérica de tarjetas que pisa el borde de los cuatro lados (el motivo del riel)', () => {
    const regla = reglaConSelector('.high-contrast .rounded-xl')
    expect(regla, 'No hay regla ".high-contrast .rounded-xl" en high-contrast.css: si ya no pisa el borde, sacá también el riel').toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])border:\s*2px\s+solid\s+var\(--color-border\)\s*!important/)
  })

  it('".border-l-4" deja el borde izquierdo en 6px con el color de borde del modo', () => {
    const regla = reglaConSelector('.high-contrast .border-l-4')
    expect(
      regla,
      'Falta la regla ".high-contrast .border-l-4" en high-contrast.css: sin ella, el borde de 2px de las tarjetas le ' +
        'gana al riel de Card con accent y desaparece.'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])border-left:\s*6px\s+solid\s+var\(--color-border\)\s*!important/)
  })

  it('va después de la regla genérica de tarjetas (misma especificidad, gana por orden)', () => {
    const generica = REGLAS_CSS.findIndex(regla => regla.selectores.includes('.high-contrast .rounded-xl'))
    const riel = REGLAS_CSS.findIndex(regla => regla.selectores.includes('.high-contrast .border-l-4'))

    expect(generica).toBeGreaterThanOrEqual(0)
    expect(riel).toBeGreaterThan(generica)
  })
})

// -----------------------------------------------------------------------
// 10) El rótulo de un botón deshabilitado con color propio se lee (#870)
// -----------------------------------------------------------------------
//
// `.high-contrast button:disabled` le fija el FONDO al botón
// (--color-bg-secondary), pero un botón con color propio —el primario con
// `btn-primary`, el de peligro, el de éxito— conserva el `color` que su regla
// pensó para SU fondo, que ya no está: blanco sobre #f0f0f0 (1,14:1) en claro y,
// en oscuro, el primario negro sobre #1a1a1a (1,21:1), aun sin pasar el mouse
// (medido en Chromium con la hoja real). La regla nueva devuelve el rótulo al
// color primario. Importan tres cosas, y las tres se fijan:
//  - ESPECIFICIDAD: (0,2,1) le gana a las reglas de color del botón, (0,2,0).
//  - ORDEN: empata en (0,2,1) con `.high-contrast button:hover` y le gana por ir
//    después; si va antes, el hover vuelve a invertir el texto sobre un fondo que
//    no se invirtió.
//  - Que PIERDA contra `.high-contrast.dark .bg-red-600` y `.bg-green-*` (0,3,0):
//    ésas fijan fondo y color juntos (negro sobre rojo o verde fluor) y pisarles
//    sólo el color dejaría blanco sobre fluor (un deshabilitado `bg-green-700`
//    pasaba de 15,3:1 a 1,37:1: el mismo cuidado de #792).
// jsdom no aplica hojas de estilo, así que se fija por texto, con los selectores
// enteros y una cuenta mínima de especificidad.

type Especificidad = readonly [number, number, number]

/**
 * Especificidad (a, b, c) de un selector compuesto simple, que es lo que hay en
 * high-contrast.css. `:where()` no suma nada; `:is(a, b)` y `:not(a, b)` suman lo
 * que el más específico de sus argumentos (y ellos mismos, nada), como pide la
 * spec. No maneja `:has()`: ahí tira en vez de contar mal en silencio.
 */
function especificidad(selector: string): Especificidad {
  let resto = selector
    .replace(/:where\((?:[^()]|\([^()]*\))*\)/g, ' ')
    // `dark\:bg-gray-800` es UNA clase: el escape no abre una pseudoclase.
    .replace(/\\./g, 'x')
  if (/:has\(/.test(resto)) {
    throw new Error(`especificidad() no maneja :has: ${selector}`)
  }
  // Se sacan de a una, con sus paréntesis balanceados (un argumento puede traer `:not(...)`).
  let deArgumentos: Especificidad = [0, 0, 0]
  for (let abre = /:(?:is|not)\(/.exec(resto); abre; abre = /:(?:is|not)\(/.exec(resto)) {
    const desde = abre.index + abre[0].length
    let profundidad = 1
    let fin = desde
    while (fin < resto.length && profundidad > 0) {
      if (resto[fin] === '(') profundidad++
      if (resto[fin] === ')') profundidad--
      fin++
    }
    const masEspecifico = partirSelectores(resto.slice(desde, fin - 1))
      .map(especificidad)
      .reduce((a, b) => (compararEspecificidad(a, b) >= 0 ? a : b))
    deArgumentos = [
      deArgumentos[0] + masEspecifico[0],
      deArgumentos[1] + masEspecifico[1],
      deArgumentos[2] + masEspecifico[2],
    ]
    resto = `${resto.slice(0, abre.index)} ${resto.slice(fin)}`
  }
  const atributos = resto.match(/\[[^\]]*\]/g)?.length ?? 0
  resto = resto.replace(/\[[^\]]*\]/g, ' ')
  const clases = resto.match(/\.[\w-]+/g)?.length ?? 0
  const pseudoclases = resto.match(/(?<!:):[\w-]+/g)?.length ?? 0
  resto = resto.replace(/\.[\w-]+|(?<!:):[\w-]+/g, ' ')
  const tipos = resto.match(/[a-z][\w-]*/gi)?.length ?? 0
  return [deArgumentos[0], deArgumentos[1] + clases + atributos + pseudoclases, deArgumentos[2] + tipos]
}

/** > 0 si `a` es más específico que `b`, < 0 si menos, 0 si empatan. */
function compararEspecificidad(a: Especificidad, b: Especificidad): number {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] - b[i]
  }
  return 0
}

const BOTON_DESHABILITADO = '.high-contrast button:disabled'
const COLOR_PRIMARIO = /(?:^|[;\s])color:\s*var\(--color-text-primary\)\s*!important/

/** La regla que fija el COLOR del deshabilitado (la que le fija el fondo es otra, más arriba en la hoja). */
function reglaDeColorDelDeshabilitado(): ReglaCss | undefined {
  return REGLAS_CSS.find(regla => regla.selectores.includes(BOTON_DESHABILITADO) && COLOR_PRIMARIO.test(regla.cuerpo))
}

// Las reglas de color de un botón con color propio en claro: cada una pinta un
// color pensado para su propio fondo, que el deshabilitado reemplaza.
const COLOR_PROPIO_EN_CLARO = [
  { selector: '.high-contrast [class*="btn-primary"]', color: 'var\\(--color-bg-primary\\)' },
  { selector: '.high-contrast .bg-blue-600', color: 'var\\(--color-bg-primary\\)' },
  { selector: '.high-contrast .bg-brand-600', color: 'var\\(--color-bg-primary\\)' },
  { selector: '.high-contrast .bg-red-600', color: '#ffffff' },
  { selector: '.high-contrast .bg-green-700', color: '#ffffff' },
] as const

// Las de modo oscuro que fijan fondo y color JUNTOS: el deshabilitado no las pisa.
const PAR_FONDO_COLOR_EN_OSCURO = [
  { selector: '.high-contrast.dark .bg-red-600', fondo: '#ff4444' },
  { selector: '.high-contrast.dark .bg-green-700', fondo: '#00ff00' },
] as const

describe('contrato: el rótulo de un botón deshabilitado con color propio se lee', () => {
  it.each([
    ['.high-contrast button:hover', [0, 2, 1]],
    [BOTON_DESHABILITADO, [0, 2, 1]],
    ['.high-contrast [class*="btn-primary"]', [0, 2, 0]],
    ['.high-contrast.dark .bg-red-600', [0, 3, 0]],
    ['.high-contrast.dark button.dark\\:bg-gray-800:hover', [0, 4, 1]],
    [':where(.high-contrast) button:disabled:hover', [0, 2, 1]],
    ['.high-contrast span', [0, 1, 1]],
    ['.high-contrast button > span:where(:not([class*="bg-"]))', [0, 1, 2]],
    // `:is()` y `:not()` valen lo que su argumento más específico (las reglas de #888 los usan).
    ['.high-contrast svg[class*="text-"]', [0, 2, 1]],
    ['.high-contrast button:hover :is(span, p, div):not([class*="bg-"])', [0, 3, 2]],
    ['.high-contrast button:disabled:hover :is(span, p, div):not([class*="bg-"])', [0, 4, 2]],
    ['.high-contrast button:disabled:hover svg[class*="text-"]', [0, 4, 2]],
    ['.high-contrast.dark button.dark\\:bg-gray-800:hover :is(span, p, div):not([class*="bg-"])', [0, 5, 2]],
    ['.a :is(span, .x)', [0, 2, 0]],
    ['.a :not(.x, span)', [0, 2, 0]],
  ] as const)('la cuenta de especificidad de "%s" da %j (la base de los casos de abajo)', (selector, esperada) => {
    expect(especificidad(selector)).toEqual(esperada)
  })

  it('".high-contrast button:disabled" fija el color primario del rótulo, y sólo el del botón', () => {
    const regla = reglaDeColorDelDeshabilitado()
    expect(
      regla,
      'Falta una regla ".high-contrast button:disabled" con `color: var(--color-text-primary) !important` en ' +
        'high-contrast.css: sin ella, el rótulo de un botón deshabilitado con color propio conserva el color que ' +
        'su regla pensó para un fondo que el deshabilitado reemplaza (blanco sobre #f0f0f0, 1,14:1; en oscuro, ' +
        'el primario negro sobre #1a1a1a, 1,21:1).'
    ).toBeDefined()
    // Sólo `button`: un `input:disabled` ya tiene el color primario, y no hay por qué pisarle un `.text-red-500` de error.
    expect(regla?.selectores).toEqual([BOTON_DESHABILITADO])
  })

  it.each(COLOR_PROPIO_EN_CLARO)('"$selector" sigue con un color propio y ".high-contrast button:disabled" le gana por especificidad', ({ selector, color }) => {
    const regla = reglaConSelector(selector)
    expect(regla, `No hay regla "${selector}" en high-contrast.css`).toBeDefined()
    expect(regla?.cuerpo).toMatch(new RegExp(`(?:^|[;\\s])color:\\s*${color}\\s*!important`))
    expect(
      compararEspecificidad(especificidad(BOTON_DESHABILITADO), especificidad(selector)),
      `"${selector}" empata o le gana a "${BOTON_DESHABILITADO}": el color propio del botón volvería a ganar sobre el fondo del deshabilitado.`
    ).toBeGreaterThan(0)
  })

  it('va después de ".high-contrast button:hover" (misma especificidad, gana por orden)', () => {
    const hover = REGLAS_CSS.findIndex(regla => regla.selectores.includes('.high-contrast button:hover'))
    const color = REGLAS_CSS.findIndex(regla => regla.selectores.includes(BOTON_DESHABILITADO) && COLOR_PRIMARIO.test(regla.cuerpo))

    expect(hover).toBeGreaterThanOrEqual(0)
    expect(color, 'No hay regla de color para ".high-contrast button:disabled"').toBeGreaterThanOrEqual(0)
    expect(color).toBeGreaterThan(hover)
  })

  it.each(PAR_FONDO_COLOR_EN_OSCURO)('"$selector" fija fondo y color juntos, y el deshabilitado no la pisa (pierde por especificidad)', ({ selector, fondo }) => {
    const regla = reglaConSelector(selector)
    expect(regla, `No hay regla "${selector}" en high-contrast.css`).toBeDefined()
    expect(regla?.cuerpo).toMatch(new RegExp(`background-color:\\s*${fondo}\\s*!important`))
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*#000000\s*!important/)
    expect(
      compararEspecificidad(especificidad(BOTON_DESHABILITADO), especificidad(selector)),
      `"${BOTON_DESHABILITADO}" empata o le gana a "${selector}": pisaría sólo el color de un botón que fija fondo y color juntos ` +
        '(blanco sobre rojo o verde fluor).'
    ).toBeLessThan(0)
  })

  it('el <span> directo del botón sigue heredando ese color (la regla de #756 le gana a ".high-contrast span")', () => {
    const span = '.high-contrast button > span:where(:not([class*="bg-"]))'
    const regla = reglaConSelector(span)
    expect(regla, `Falta el selector ${span} en high-contrast.css: sin él, el <span> del rótulo no hereda el color del botón.`).toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*inherit\s*!important/)
    expect(compararEspecificidad(especificidad(span), especificidad('.high-contrast span'))).toBeGreaterThan(0)
  })
})

// -----------------------------------------------------------------------
// 11) Dentro de un botón con fondo neón (oscuro), el rótulo y el ícono heredan su negro (#888)
// -----------------------------------------------------------------------
//
// En modo oscuro `.bg-red-*` y `.bg-green-*` pintan el botón de rojo o verde fluor
// con texto negro. Pero a los hijos les llegan reglas que les fuerzan el color
// primario, que en oscuro es BLANCO: 3,41:1 sobre el rojo y 1,37:1 sobre el verde
// (medido en Chromium con la hoja real, en la galería). Son tres:
//  - `.high-contrast button:disabled:hover :is(span, p, div)…` y su par de `svg`
//    (#792), (0,4,2): el rótulo en <span> de un deshabilitado con el mouse encima.
//  - `.high-contrast svg[class*="text-"]`, (0,2,1): el ícono con `text-*`.
//  - `.high-contrast p/div`, (0,1,1): un <p> o <div> del rótulo.
// La regla nueva hace heredar el color del botón, que ya es negro en los cuatro
// estados. Se fijan tres cosas:
//  - EL MOTIVO: que esas reglas sigan forzando el color primario, y que el fondo
//    neón siga yendo junto con el texto negro. Si cambia alguno, la herencia sobra
//    o pasa a ser el bug.
//  - EL SELECTOR ENTERO, con las cinco clases del fluor. Si el CSS pinta de fluor
//    una clase más, la herencia tiene que sumarla: el test lo cuenta desde la hoja.
//  - LA CUENTA: (0,4,2) empata con las reglas de #792 y les gana por ORDEN, así que
//    tiene que quedar DESPUÉS de ellas; a las otras les gana por especificidad.
//    Es el mínimo: sin el `button` serían (0,4,1) y perderían contra el
//    deshabilitado con hover.
// jsdom no aplica hojas de estilo, así que se fija por texto.

const NEONES_EN_OSCURO = [
  { clase: 'bg-red-500', fondo: '#ff4444' },
  { clase: 'bg-red-600', fondo: '#ff4444' },
  { clase: 'bg-green-500', fondo: '#00ff00' },
  { clase: 'bg-green-600', fondo: '#00ff00' },
  { clase: 'bg-green-700', fondo: '#00ff00' },
] as const

const LISTA_DEL_NEON = NEONES_EN_OSCURO.map(({ clase }) => `.${clase}`).join(', ')
const HIJOS_DEL_NEON = `.high-contrast.dark button:is(${LISTA_DEL_NEON}) :is(span, p, div):not([class*="bg-"])`
const ICONO_DEL_NEON = `.high-contrast.dark button:is(${LISTA_DEL_NEON}) svg[class*="text-"]`

// Las reglas que les fuerzan el color primario a los hijos del botón, y la que
// tiene que ganarles en cada caso.
const FORZADORAS_DEL_COLOR_PRIMARIO = [
  { caso: '<span>', forzadora: '.high-contrast span', gana: HIJOS_DEL_NEON },
  { caso: '<p>', forzadora: '.high-contrast p', gana: HIJOS_DEL_NEON },
  { caso: '<div>', forzadora: '.high-contrast div', gana: HIJOS_DEL_NEON },
  { caso: 'span/p/div, deshabilitado con hover', forzadora: '.high-contrast button:disabled:hover :is(span, p, div):not([class*="bg-"])', gana: HIJOS_DEL_NEON },
  { caso: 'ícono con text-*', forzadora: '.high-contrast svg[class*="text-"]', gana: ICONO_DEL_NEON },
  { caso: 'ícono, deshabilitado con hover', forzadora: '.high-contrast button:disabled:hover svg[class*="text-"]', gana: ICONO_DEL_NEON },
] as const

describe('contrato: dentro de un botón con fondo neón (oscuro) el rótulo y el ícono heredan su negro', () => {
  it.each(NEONES_EN_OSCURO)('".high-contrast.dark .$clase" pinta $fondo y texto negro juntos (el motivo de la herencia)', ({ clase, fondo }) => {
    const selector = `.high-contrast.dark .${clase}`
    const regla = reglaConSelector(selector)
    expect(regla, `No hay regla "${selector}" en high-contrast.css`).toBeDefined()
    expect(regla?.cuerpo).toMatch(new RegExp(`background-color:\\s*${fondo}\\s*!important`))
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*#000000\s*!important/)
  })

  it('no hay otra clase que pinte fluor en oscuro fuera de la lista (la herencia las tendría que cubrir)', () => {
    const pintanFluor = REGLAS_CSS
      .filter(regla => /background-color:\s*(?:#ff4444|#00ff00)\s*!important/.test(regla.cuerpo))
      .flatMap(regla => regla.selectores)
    expect([...pintanFluor].sort()).toEqual(NEONES_EN_OSCURO.map(({ clase }) => `.high-contrast.dark .${clase}`).sort())
  })

  it.each(FORZADORAS_DEL_COLOR_PRIMARIO)('$caso: sigue la regla que le fuerza el color primario (el motivo de la herencia)', ({ forzadora }) => {
    const regla = reglaConSelector(forzadora)
    expect(regla, `No hay regla "${forzadora}" en high-contrast.css: si ya no fuerza el color, revisá la herencia del neón`).toBeDefined()
    expect(regla?.cuerpo).toMatch(COLOR_PRIMARIO)
  })

  it.each([
    ['span/p/div sin fondo propio', HIJOS_DEL_NEON],
    ['íconos con text-*', ICONO_DEL_NEON],
  ])('%s: heredan el color del botón', (_caso, selector) => {
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, el <span>, <p>, <div> o ícono con \`text-*\` de un ` +
        'botón danger o success queda en el color primario (blanco) sobre el fluor: 3,41:1 en el rojo, 1,37:1 en el verde.'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*inherit\s*!important/)
  })

  it.each(FORZADORAS_DEL_COLOR_PRIMARIO)('$caso: la herencia del neón le gana a esa regla (por especificidad, o por orden si empatan)', ({ forzadora, gana }) => {
    const indiceDeLaForzadora = REGLAS_CSS.findIndex(regla => regla.selectores.includes(forzadora))
    const indiceDeLaNuestra = REGLAS_CSS.findIndex(regla => regla.selectores.includes(gana))
    expect(indiceDeLaForzadora).toBeGreaterThanOrEqual(0)
    expect(indiceDeLaNuestra).toBeGreaterThanOrEqual(0)

    const comparacion = compararEspecificidad(especificidad(gana), especificidad(forzadora))
    expect(
      comparacion,
      `"${forzadora}" es más específica que "${gana}": el color primario volvería a ganar sobre el fluor.`
    ).toBeGreaterThanOrEqual(0)
    if (comparacion === 0) {
      expect(
        indiceDeLaNuestra,
        `"${gana}" empata en especificidad con "${forzadora}" y va ANTES en la hoja: el color primario volvería a ganar.`
      ).toBeGreaterThan(indiceDeLaForzadora)
    }
  })

  it('es el mínimo: (0,4,2), el de las reglas de #792 con las que empata', () => {
    expect(especificidad(HIJOS_DEL_NEON)).toEqual([0, 4, 2])
    expect(especificidad(ICONO_DEL_NEON)).toEqual([0, 4, 2])
  })
})

// -----------------------------------------------------------------------
// 12) Primario y neón con hijos propios, y lo que no es un botón (#903)
// -----------------------------------------------------------------------
//
// #888 arregló el rótulo y el ícono DENTRO DE UN BOTÓN danger/success en oscuro. Quedaban
// tres casos de la misma familia (medidos en Chromium sobre la galería, `data-caso`):
//  1. Primario (`btn-primary`, `bg-brand-600`, `bg-blue-*`): la hoja invierte su fondo, pero
//     `svg[class*="text-"]` y `p/div` les fuerzan a los hijos el color primario, que es el
//     del fondo que el primario acaba de tomar. Un ícono `text-white`, un <p> o un <div>:
//     1:1 en los DOS modos (negro sobre negro en claro, blanco sobre blanco en oscuro).
//     También un tile `div.bg-brand-600` con un ícono, que no es un botón.
//  2. Neón que NO es botón, en oscuro: un `div.bg-red-600` con <p>/<span> adentro seguía
//     blanco sobre el fluor (3,41:1 el rojo, 1,37:1 el verde): BannerManiobra, el banner de
//     RutaActivaTransportista, las variantes `strong` de Badge con un <span>.
//  3. Claro: el danger (#8b0000) y el success (#006400) llevan texto blanco, y un ícono con
//     `text-*` salía negro: 2,1:1 y 2,82:1.
// Las tres reglas hacen heredar al hijo el color de su contenedor. Se fijan cuatro cosas:
//  - EL MOTIVO: que las reglas que fuerzan el color primario y las que invierten (o pintan)
//    el contenedor sigan ahí. Si cambian, la herencia sobra o pasa a ser el bug.
//  - EL SELECTOR ENTERO, con las listas de clases y las dos exclusiones: lo que pinta su
//    propio fondo (`bg-*`) y el ícono de lucide con "alert" en el nombre, al que
//    `[class*="alert"]` le pone un fondo blanco o negro propio (heredar el color del
//    contenedor da 1:1 sobre esa caja). Y, sólo en claro, el contenedor con `role="alert"`:
//    `.high-contrast [role="alert"]` va DESPUÉS de `.bg-red-600` con la misma (0,2,0) y le
//    pone fondo blanco, así que ahí el texto negro de los hijos es el legible.
//  - LA CUENTA: gana por especificidad, o por orden si empata.
//  - EL MÍNIMO: la especificidad exacta de cada una.
// jsdom no aplica hojas de estilo, así que se fija por texto.

const PRIMARIOS = ['.bg-blue-500', '.bg-blue-600', '.bg-brand-600', '[class*="btn-primary"]'] as const
const LISTA_DEL_PRIMARIO = PRIMARIOS.join(', ')

const HIJO_SIN_FONDO_PROPIO = ':is(span, p, div):not([class*="bg-"], [class*="alert"])'
const ICONO_SIN_CAJA_PROPIA = 'svg[class*="text-"]:where(:not([class*="alert"]))'
const NEON_FUERA_DE_UN_ALERT = `:is(${LISTA_DEL_NEON}):where(:not([role="alert"], [class*="alert"]))`

const HIJOS_DEL_PRIMARIO = `.high-contrast :is(${LISTA_DEL_PRIMARIO}) ${HIJO_SIN_FONDO_PROPIO}`
const ICONO_DEL_PRIMARIO = `.high-contrast :is(${LISTA_DEL_PRIMARIO}) ${ICONO_SIN_CAJA_PROPIA}`
const HIJOS_DEL_NEON_QUE_NO_ES_BOTON = `.high-contrast.dark :is(${LISTA_DEL_NEON}):not(button) ${HIJO_SIN_FONDO_PROPIO}`
const ICONO_DEL_NEON_QUE_NO_ES_BOTON = `.high-contrast.dark :is(${LISTA_DEL_NEON}):not(button) ${ICONO_SIN_CAJA_PROPIA}`
const HIJOS_DEL_NEON_EN_CLARO = `.high-contrast:not(.dark) ${NEON_FUERA_DE_UN_ALERT} ${HIJO_SIN_FONDO_PROPIO}`
const ICONO_DEL_NEON_EN_CLARO = `.high-contrast:not(.dark) ${NEON_FUERA_DE_UN_ALERT} ${ICONO_SIN_CAJA_PROPIA}`

// Las reglas de #792 que dejan el color primario en un botón deshabilitado con el mouse encima.
const HIJOS_DEL_DESHABILITADO_CON_HOVER = '.high-contrast button:disabled:hover :is(span, p, div):not([class*="bg-"])'
const ICONO_DEL_DESHABILITADO_CON_HOVER = '.high-contrast button:disabled:hover svg[class*="text-"]'

const FORZADORAS_DE_HIJOS = ['.high-contrast span', '.high-contrast p', '.high-contrast div'] as const
const FORZADORAS_DE_ICONO = ['.high-contrast svg[class*="text-"]'] as const

const REGLAS_DE_HERENCIA_903 = [
  { caso: 'hijos del primario', selector: HIJOS_DEL_PRIMARIO, cuenta: [0, 3, 1], forzadoras: FORZADORAS_DE_HIJOS },
  { caso: 'ícono del primario', selector: ICONO_DEL_PRIMARIO, cuenta: [0, 3, 1], forzadoras: FORZADORAS_DE_ICONO },
  { caso: 'hijos del neón que no es botón (oscuro)', selector: HIJOS_DEL_NEON_QUE_NO_ES_BOTON, cuenta: [0, 4, 2], forzadoras: FORZADORAS_DE_HIJOS },
  { caso: 'ícono del neón que no es botón (oscuro)', selector: ICONO_DEL_NEON_QUE_NO_ES_BOTON, cuenta: [0, 4, 2], forzadoras: FORZADORAS_DE_ICONO },
  { caso: 'hijos del neón (claro)', selector: HIJOS_DEL_NEON_EN_CLARO, cuenta: [0, 4, 1], forzadoras: FORZADORAS_DE_HIJOS },
  { caso: 'ícono del neón (claro)', selector: ICONO_DEL_NEON_EN_CLARO, cuenta: [0, 4, 1], forzadoras: FORZADORAS_DE_ICONO },
] as const

describe('contrato: el primario y el neón heredan su color a lo que llevan adentro (#903)', () => {
  it.each([
    ['un `:where()` con un `:not()` adentro no suma (el ícono sin caja de alert)', '.a svg[class*="text-"]:where(:not([class*="alert"]))', [0, 2, 1]],
    ['`:not()` con dos argumentos vale lo que el más específico', '.a :is(span, p, div):not([class*="bg-"], [class*="alert"])', [0, 2, 1]],
  ] as const)('la cuenta de especificidad: %s', (_caso, selector, esperada) => {
    expect(especificidad(selector)).toEqual(esperada)
  })

  // --- 1) el primario
  it('la lista del primario son las cuatro clases de la regla que invierte su fondo (si suma una, la herencia la tiene que sumar)', () => {
    const regla = reglaConSelector('.high-contrast .bg-brand-600')
    expect(regla, 'No hay regla ".high-contrast .bg-brand-600" en high-contrast.css').toBeDefined()
    expect([...(regla?.selectores ?? [])].sort()).toEqual(PRIMARIOS.map(clase => `.high-contrast ${clase}`).sort())
  })

  it.each(PRIMARIOS)('"%s" invierte el fondo y el texto del contenedor (el motivo de la herencia)', clase => {
    const regla = reglaConSelector(`.high-contrast ${clase}`)
    expect(regla, `No hay regla ".high-contrast ${clase}" en high-contrast.css`).toBeDefined()
    expect(regla?.cuerpo).toMatch(/background-color:\s*var\(--color-text-primary\)\s*!important/)
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*var\(--color-bg-primary\)\s*!important/)
  })

  // --- 2) y 3) el neón
  it.each([
    ['bg-red-600', '#8b0000'],
    ['bg-green-700', '#006400'],
  ])('".high-contrast .%s" sigue pintando %s con texto blanco (el motivo de la herencia en claro)', (clase, fondo) => {
    const regla = reglaConSelector(`.high-contrast .${clase}`)
    expect(regla, `No hay regla ".high-contrast .${clase}" en high-contrast.css`).toBeDefined()
    expect(regla?.cuerpo).toMatch(new RegExp(`background-color:\\s*${fondo}\\s*!important`))
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*#ffffff\s*!important/)
  })

  it('las listas del neón en claro son las mismas cinco clases que las del oscuro', () => {
    expect(reglaConSelector('.high-contrast .bg-red-600')?.selectores).toEqual(['.high-contrast .bg-red-600', '.high-contrast .bg-red-500'])
    expect(reglaConSelector('.high-contrast .bg-green-700')?.selectores).toEqual([
      '.high-contrast .bg-green-700',
      '.high-contrast .bg-green-600',
      '.high-contrast .bg-green-500',
    ])
  })

  it('el contenedor alert y la clase con "alert" pintan un fondo propio (por eso el ícono de lucide con "alert" y el contenedor quedan afuera)', () => {
    const regla = reglaConSelector('.high-contrast [class*="alert"]')
    expect(regla, 'No hay regla ".high-contrast [class*=\\"alert\\"]" en high-contrast.css').toBeDefined()
    expect(regla?.selectores).toContain('.high-contrast [role="alert"]')
    expect(regla?.cuerpo).toMatch(/background-color:\s*var\(--color-bg-primary\)\s*!important/)
  })

  it('el contenedor alert le gana a ".bg-red-600" en claro (misma especificidad, va después): por eso la herencia del claro lo deja afuera', () => {
    const rojo = '.high-contrast .bg-red-600'
    const alerta = '.high-contrast [role="alert"]'
    expect(compararEspecificidad(especificidad(alerta), especificidad(rojo))).toBe(0)
    const indiceDelRojo = REGLAS_CSS.findIndex(regla => regla.selectores.includes(rojo))
    const indiceDeLaAlerta = REGLAS_CSS.findIndex(regla => regla.selectores.includes(alerta))
    expect(indiceDelRojo).toBeGreaterThanOrEqual(0)
    expect(indiceDeLaAlerta, 'el contenedor alert tiene que ir DESPUÉS de ".bg-red-600" para pisarle el fondo').toBeGreaterThan(indiceDelRojo)
  })

  // --- las reglas nuevas
  it.each(REGLAS_DE_HERENCIA_903)('$caso: hereda el color del contenedor (selector entero)', ({ selector }) => {
    const regla = reglaConSelector(selector)
    expect(
      regla,
      `Falta el selector ${selector} en high-contrast.css: sin él, el ícono con \`text-*\`, el <span>, <p> o <div> de un primario o de ` +
        'un danger/success queda en el color primario sobre un fondo que no es el suyo (1:1 en el primario, 2,1:1 el danger en claro, ' +
        '3,41:1 el danger en oscuro, 1,37:1 el success en oscuro).'
    ).toBeDefined()
    expect(regla?.cuerpo).toMatch(/(?:^|[;\s])color:\s*inherit\s*!important/)
  })

  it.each(REGLAS_DE_HERENCIA_903)('$caso: su especificidad es la mínima $cuenta', ({ selector, cuenta }) => {
    expect(especificidad(selector)).toEqual(cuenta)
  })

  it.each(
    REGLAS_DE_HERENCIA_903.flatMap(({ caso, selector, forzadoras }) =>
      forzadoras.map(forzadora => ({ caso, selector, forzadora }))
    )
  )('$caso: le gana a "$forzadora" (por especificidad, o por orden si empatan)', ({ selector, forzadora }) => {
    const indiceDeLaForzadora = REGLAS_CSS.findIndex(regla => regla.selectores.includes(forzadora))
    const indiceDeLaNuestra = REGLAS_CSS.findIndex(regla => regla.selectores.includes(selector))
    expect(indiceDeLaForzadora, `No hay regla "${forzadora}" en high-contrast.css`).toBeGreaterThanOrEqual(0)
    expect(indiceDeLaNuestra).toBeGreaterThanOrEqual(0)
    expect(reglaConSelector(forzadora)?.cuerpo).toMatch(COLOR_PRIMARIO)

    const comparacion = compararEspecificidad(especificidad(selector), especificidad(forzadora))
    expect(comparacion, `"${forzadora}" es más específica que "${selector}": el color primario volvería a ganar.`).toBeGreaterThanOrEqual(0)
    if (comparacion === 0) {
      expect(
        indiceDeLaNuestra,
        `"${selector}" empata con "${forzadora}" y va ANTES en la hoja: el color primario volvería a ganar.`
      ).toBeGreaterThan(indiceDeLaForzadora)
    }
  })

  it.each([
    ['hijos del primario', HIJOS_DEL_PRIMARIO, HIJOS_DEL_DESHABILITADO_CON_HOVER],
    ['ícono del primario', ICONO_DEL_PRIMARIO, ICONO_DEL_DESHABILITADO_CON_HOVER],
    ['hijos del neón (claro)', HIJOS_DEL_NEON_EN_CLARO, HIJOS_DEL_DESHABILITADO_CON_HOVER],
    ['ícono del neón (claro)', ICONO_DEL_NEON_EN_CLARO, ICONO_DEL_DESHABILITADO_CON_HOVER],
  ])('%s: pierde contra la de #792 (el deshabilitado con hover ya deja el color primario, que es el de su botón)', (_caso, nuestra, deHover) => {
    expect(compararEspecificidad(especificidad(nuestra), especificidad(deHover))).toBeLessThan(0)
  })

  it('la del neón que no es botón (oscuro) va después de las de #792 con las que empata y de la de #888', () => {
    const indiceDeLaNuestra = REGLAS_CSS.findIndex(regla => regla.selectores.includes(HIJOS_DEL_NEON_QUE_NO_ES_BOTON))
    for (const anterior of [HIJOS_DEL_DESHABILITADO_CON_HOVER, ICONO_DEL_DESHABILITADO_CON_HOVER, HIJOS_DEL_NEON, ICONO_DEL_NEON]) {
      const indice = REGLAS_CSS.findIndex(regla => regla.selectores.includes(anterior))
      expect(indice, `No hay regla "${anterior}" en high-contrast.css`).toBeGreaterThanOrEqual(0)
      expect(indiceDeLaNuestra).toBeGreaterThan(indice)
    }
  })

  it('la del neón que no es botón (oscuro) se separa de la de #888 sólo por el `:not(button)` (el botón ya lo cubre aquélla)', () => {
    expect(HIJOS_DEL_NEON_QUE_NO_ES_BOTON).toContain(':not(button)')
    expect(HIJOS_DEL_NEON).toContain('button:is(')
    expect(especificidad(HIJOS_DEL_NEON_QUE_NO_ES_BOTON)).toEqual(especificidad(HIJOS_DEL_NEON))
  })
})

describe('contrato: cableado de alto contraste', () => {
  afterEach(() => {
    // Los tests de comportamiento de abajo togglean la clase de verdad sobre
    // <html>; sin este cleanup, un test que corra despues (en este archivo o
    // en otro, si vitest comparte el mismo documento) heredaria el estado.
    document.documentElement.classList.remove('high-contrast')
  })

  it('main.tsx importa el stylesheet de alto contraste', () => {
    const mainSrc = fs.readFileSync(MAIN_TSX_PATH, 'utf-8')
    // Anclado al inicio de linea (multilinea) y aceptando comillas simples o
    // dobles: un `import "./styles/high-contrast.css"` con comillas dobles,
    // o el mismo import en otra linea del archivo, tienen que seguir dando
    // verde. Antes esto comparaba un string EXACTO con comilla simple.
    expect(
      /^\s*import\s+['"]\.\/styles\/high-contrast\.css['"]/m.test(mainSrc),
      'main.tsx dejo de importar ./styles/high-contrast.css: sin ese import, ninguna regla de alto contraste ' +
        'se aplica en produccion aunque el resto de este contrato pase.'
    ).toBe(true)
  })

  it('ThemeContext.tsx todavia contiene el toggle de "high-contrast" (chequeo textual)', () => {
    // Chequeo liviano y rapido: mira el texto crudo del archivo, sin sacar
    // comentarios ni mirar el segundo argumento de `classList.toggle`. Por
    // eso NO es la unica cobertura de este comportamiento — lo complementa
    // el test de comportamiento de abajo, que renderiza el Provider de
    // verdad y falla si el toggle esta comentado, con el segundo argumento
    // en `false`, o borrado del useEffect.
    const themeContextSrc = fs.readFileSync(THEME_CONTEXT_PATH, 'utf-8')
    expect(
      /classList\.toggle\(\s*['"]high-contrast['"]/.test(themeContextSrc),
      'ThemeContext.tsx dejo de hacer document.documentElement.classList.toggle("high-contrast", ...): sin eso, ' +
        'ninguna regla ".high-contrast ..." de high-contrast.css se activa nunca, aunque los selectores sigan ' +
        'existiendo en el CSS y en src/.'
    ).toBe(true)
  })

  it('ThemeProvider realmente agrega y saca "high-contrast" de <html> al togglear (comportamiento, no regex)', async () => {
    function ConsumidorDeTema() {
      const { highContrast, toggleHighContrast } = useTheme()
      return React.createElement(
        'button',
        { onClick: toggleHighContrast, 'aria-pressed': highContrast },
        'Alternar alto contraste'
      )
    }

    const user = userEvent.setup()
    render(React.createElement(ThemeProvider, null, React.createElement(ConsumidorDeTema)))

    const boton = screen.getByRole('button', { name: 'Alternar alto contraste', pressed: false })
    expect(document.documentElement.classList.contains('high-contrast')).toBe(false)

    await user.click(boton)

    screen.getByRole('button', { name: 'Alternar alto contraste', pressed: true })
    expect(document.documentElement.classList.contains('high-contrast')).toBe(true)
    // Tiene que persistir bajo la clave 'highContrast' (ver ThemeContext.tsx).
    expect(JSON.parse(localStorage.getItem('highContrast') ?? 'null')).toBe(true)

    await user.click(boton)

    screen.getByRole('button', { name: 'Alternar alto contraste', pressed: false })
    expect(document.documentElement.classList.contains('high-contrast')).toBe(false)
    expect(JSON.parse(localStorage.getItem('highContrast') ?? 'null')).toBe(false)
  })

  it('sin preferencia guardada, el estado inicial de highContrast sale de matchMedia("(prefers-contrast: more)")', () => {
    const matchMediaOriginal = window.matchMedia
    const matchMediaMock = vi.fn((query: string) => ({
      matches: query === '(prefers-contrast: more)',
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }))
    window.matchMedia = matchMediaMock as unknown as typeof window.matchMedia

    try {
      function ConsumidorDeTema() {
        const { highContrast } = useTheme()
        return React.createElement('span', { 'aria-label': 'estado' }, highContrast ? 'on' : 'off')
      }
      render(React.createElement(ThemeProvider, null, React.createElement(ConsumidorDeTema)))

      expect(document.documentElement.classList.contains('high-contrast')).toBe(true)
    } finally {
      window.matchMedia = matchMediaOriginal
    }
  })

  it('high-contrast.css todavia tiene reglas para ".high-contrast" (el CSS y ThemeContext tienen que renombrarse juntos)', () => {
    // ".high-contrast" esta excluida de CLASES_CSS a proposito (es una clase
    // de ESTADO, no de componente — ver el docstring de arriba), asi que
    // ningun test del describe de "selectores de clase" la cubre. Sin este chequeo, renombrar la
    // clase del lado del CSS (".high-contrast" -> ".contraste-alto") deja
    // los tests de este archivo en verde con el modo de alto contraste
    // muerto: ThemeContext.tsx seguiria togglando "high-contrast" sobre
    // <html>, pero ninguna regla del CSS arrancaria con esa clase.
    const ocurrencias = (cssCrudo.match(/\.high-contrast\b/g) || []).length
    expect(
      ocurrencias,
      `high-contrast.css tiene ${ocurrencias} ocurrencias de ".high-contrast" (se esperaban mas de 50). Si ` +
        'renombraste la clase de estado, ThemeContext.tsx togglea "high-contrast" sobre <html> pero el CSS ya ' +
        'no tiene ninguna regla que arranque con esa clase: los dos lados tienen que renombrarse en el mismo PR.'
    ).toBeGreaterThan(50)
  })

  it('high-contrast.css todavia tiene reglas para ".reduce-motion"', () => {
    // Mismo caso que ".high-contrast" arriba, pero para la clase de
    // movimiento reducido: si se migra a "@media (prefers-reduced-motion)"
    // sin tocar ThemeContext.tsx, la clase queda muerta sin que nada falle.
    const ocurrencias = (cssCrudo.match(/\.reduce-motion\b/g) || []).length
    expect(
      ocurrencias,
      `high-contrast.css tiene ${ocurrencias} ocurrencias de ".reduce-motion" (se esperaba al menos 1). Si ` +
        'migraste la reduccion de movimiento a un @media query, ThemeContext.tsx todavia togglea la clase ' +
        '"reduce-motion" sobre <html> y ese toggle queda sin efecto: los dos lados tienen que renombrarse/migrarse ' +
        'en el mismo PR.'
    ).toBeGreaterThan(0)
  })
})
