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
 *      ser huerfanos genuinos (0 coincidencias), igual que "modal", "overlay",
 *      "tag" y "btn-primary".
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
// transition, animate, fill, stroke, sr). Verificado a mano sobre el corpus
// actual (~59500 palabras, ~900 pasan el filtro): "border" y "shadow" siguen
// dando >0 coincidencias (135 y 13 tokens respectivamente), "bg-" y "text-"
// tambien (273 y 201), y "alert"/"error"/"success"/"warning"/"modal"/
// "overlay"/"tag"/"btn-primary" dan 0 — son huerfanos genuinos, no un
// artefacto de busqueda por substring sobre texto libre.
const UTILIDAD_TAILWIND_RE =
  /^(?:[a-z][a-z0-9-]*:)*-?(bg|text|border|rounded|p|px|py|m|w|h|flex|grid|gap|items|justify|font|shadow|opacity|z|ring|outline|cursor|overflow|transition|animate|fill|stroke|sr)(-[a-z0-9./[\]%()#]+)*$/

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
  // Ningun token con pinta de utilidad Tailwind de src/ contiene "btn-primary".
  'btn-primary',
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
      'bg-gray-100',
      'bg-gray-200',
      'bg-gray-300',
      'bg-gray-50',
      'bg-green-500',
      'bg-green-600',
      'bg-red-500',
      'bg-red-600',
      'bg-white',
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
