/**
 * Extractor del gate de embeds (`scripts/check-embeds.mjs`, #1008 y #1256).
 *
 * Lee los fuentes de `src/` y `supabase/functions/` y devuelve cada consulta de
 * supabase-js —la cadena que arranca en `.from(tabla)`— con sus `select`, sus
 * filtros y sus órdenes, para que el gate los pruebe contra PostgREST. Un
 * `select` es un string: ni `tsc`, ni eslint, ni los tests —que mockean
 * supabase— ven que PostgREST no pueda resolver la relación. Eso rompió "Armar
 * ruta" (PGRST201) y la pantalla de Salvedades (PGRST200).
 *
 * Es lectura de texto, no un parser de TypeScript, pero ya no adivina por
 * cercanía: la versión anterior tomaba el último `.from()` de los 900
 * caracteres previos y cortaba en `;`, que este repo no usa, así que dos
 * consultas seguidas se confundían de tabla. Ahora:
 *
 *  - Un léxico marca qué es código, qué es string/template y qué es
 *    comentario, y empareja paréntesis, corchetes y llaves.
 *  - Cada `.from(...)` se sigue hacia adelante por sus `.metodo(args)`
 *    encadenados (con `?.`, `!`, genéricos, saltos de línea y comentarios en
 *    el medio): un `.select(` pertenece a la tabla del `.from` de SU cadena.
 *  - Una consulta guardada en una variable (`let q = supabase.from(...)`) se
 *    sigue por sus continuaciones (`q = q.eq(...)`, `q.order(...)`), con la
 *    última declaración del nombre que esté en alcance.
 *  - Una función que recibe el builder como PRIMER parámetro y lo filtra
 *    (`construirFiltrosPedidos(query, ...)`) aporta sus filtros a cada
 *    consulta a la que se aplica, sin nombres cableados.
 *  - Lo que no se puede atribuir o resolver va a `omitidos` con su motivo, y
 *    el gate falla: un extractor que se pierde selects da un gate verde que no
 *    mira nada.
 */
import { columnasDeOr, esEmbebido, limpiarSelect, parsearSelect, tieneEmbed } from './embedsPostgrest.mjs'

const CODIGO = 0
const TEXTO = 1
const COMENTARIO = 2

// Después de estas palabras, una `/` abre una regex y no es una división.
const ANTES_DE_REGEX = new Set(['return', 'typeof', 'case', 'do', 'else', 'in', 'of', 'void', 'yield', 'await', 'delete', 'instanceof', 'new', 'throw'])
const RESERVADAS = new Set([
  ...ANTES_DE_REGEX, 'this', 'const', 'let', 'var', 'function', 'if', 'for', 'while', 'switch', 'catch',
  'import', 'export', 'from', 'as', 'type', 'interface', 'class', 'extends', 'super', 'true', 'false',
  'null', 'undefined', 'async', 'try', 'finally', 'break', 'continue', 'default', 'satisfies', 'keyof',
  'enum', 'declare', 'readonly', 'implements', 'static', 'public', 'private', 'protected', 'get', 'set',
])

// Métodos de PostgrestFilterBuilder cuyo primer argumento es una columna.
const FILTROS_COLUMNA = new Set([
  'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'ilike', 'likeAllOf', 'likeAnyOf', 'ilikeAllOf',
  'ilikeAnyOf', 'is', 'isDistinct', 'in', 'contains', 'containedBy', 'overlaps', 'rangeGt', 'rangeGte',
  'rangeLt', 'rangeLte', 'rangeAdjacent', 'textSearch', 'filter', 'not', 'regexMatch', 'regexIMatch',
])
const RELEVANTES = new Set([...FILTROS_COLUMNA, 'select', 'or', 'order', 'limit', 'range', 'match'])
const COMODIN = '\u0001'
const MAX_VARIANTES = 64

const esIdIni = (c) => c != null && /[A-Za-z_$]/.test(c)
const esId = (c) => c != null && /[\w$]/.test(c)
const esBlanco = (c) => c === ' ' || c === '\t' || c === '\n' || c === '\r'

// ───────────────────────────── léxico ─────────────────────────────

/** Marca cada carácter como código, texto (string/template/regex) o comentario. */
function escanear(src) {
  const n = src.length
  const tipo = new Uint8Array(n)
  const pila = [{ tpl: false, llaves: 0, enTpl: false }]
  let ult = -1 // último carácter de código no blanco
  let i = 0
  while (i < n) {
    const top = pila[pila.length - 1]
    const c = src[i]
    if (top.tpl) {
      tipo[i] = TEXTO
      if (c === '\\') {
        if (i + 1 < n) tipo[i + 1] = TEXTO
        i += 2
      } else if (c === '`') {
        pila.pop()
        ult = i
        i++
      } else if (c === '$' && src[i + 1] === '{') {
        tipo[i + 1] = TEXTO
        pila.push({ tpl: false, llaves: 0, enTpl: true })
        ult = -1
        i += 2
      } else i++
      continue
    }
    if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') tipo[i++] = COMENTARIO
      continue
    }
    if (c === '/' && src[i + 1] === '*') {
      const f = src.indexOf('*/', i + 2)
      const fin = f === -1 ? n : f + 2
      while (i < fin) tipo[i++] = COMENTARIO
      continue
    }
    if (c === "'" || c === '"') {
      // Un string de comillas no cruza de línea: si una comilla suelta de un
      // texto JSX abre uno, el daño queda en esa línea.
      let j = i + 1
      while (j < n && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1
      const fin = Math.min(n, j + 1)
      while (i < fin) tipo[i++] = TEXTO
      ult = fin - 1
      continue
    }
    if (c === '`') {
      tipo[i] = TEXTO
      pila.push({ tpl: true })
      i++
      continue
    }
    if (c === '/' && abreRegex(src, ult)) {
      let j = i + 1
      let clase = false
      let ok = false
      while (j < n && src[j] !== '\n') {
        const d = src[j]
        if (d === '\\') {
          j += 2
          continue
        }
        if (d === '[') clase = true
        else if (d === ']') clase = false
        else if (d === '/' && !clase) {
          ok = true
          break
        }
        j++
      }
      if (ok) {
        j++
        while (j < n && /[a-z]/.test(src[j])) j++
        while (i < j) tipo[i++] = TEXTO
        ult = j - 1
        continue
      }
    }
    if (c === '{') top.llaves++
    else if (c === '}') {
      if (top.enTpl && top.llaves === 0) {
        tipo[i] = TEXTO
        pila.pop()
        i++
        continue
      }
      top.llaves--
    }
    if (!esBlanco(c)) ult = i
    i++
  }
  return tipo
}

function abreRegex(src, ult) {
  if (ult < 0) return true
  const c = src[ult]
  if (esId(c)) {
    let s = ult
    while (s > 0 && esId(src[s - 1])) s--
    return ANTES_DE_REGEX.has(src.slice(s, ult + 1))
  }
  if (c === ')' || c === ']' || c === '}' || c === '<' || c === "'" || c === '"' || c === '`') return false
  if (c === '>') return src[ult - 1] === '='
  return true
}

/** Empareja ( [ { de código; además, la profundidad y la llave que envuelve a cada posición. */
function emparejar(src, tipo) {
  const n = src.length
  const par = new Int32Array(n).fill(-1)
  const prof = new Int32Array(n)
  const llave = new Int32Array(n).fill(-1)
  const pila = []
  const llaves = []
  const cierre = { ')': '(', ']': '[', '}': '{' }
  for (let i = 0; i < n; i++) {
    prof[i] = pila.length
    llave[i] = llaves.length ? llaves[llaves.length - 1] : -1
    if (tipo[i] !== CODIGO) continue
    const c = src[i]
    if (c === '(' || c === '[' || c === '{') {
      pila.push(i)
      if (c === '{') llaves.push(i)
    } else if (c === ')' || c === ']' || c === '}') {
      // Ante un desbalance (JSX raro), se descarta hasta el que corresponde.
      let k = pila.length - 1
      while (k >= 0 && src[pila[k]] !== cierre[c]) k--
      if (k < 0) continue
      while (pila.length > k + 1) {
        const x = pila.pop()
        if (src[x] === '{') llaves.pop()
      }
      const a = pila.pop()
      if (c === '}') llaves.pop()
      par[a] = i
      par[i] = a
    }
  }
  return { par, prof, llave }
}

function prepararArchivo(ruta, src) {
  const tipo = escanear(src)
  const { par, prof, llave } = emparejar(src, tipo)
  const lineas = [0]
  for (let i = 0; i < src.length; i++) if (src[i] === '\n') lineas.push(i + 1)
  return { ruta, src, n: src.length, tipo, par, prof, llave, lineas }
}

function lineaDe(F, pos) {
  let lo = 0
  let hi = F.lineas.length - 1
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (F.lineas[mid] <= pos) lo = mid
    else hi = mid - 1
  }
  return lo + 1
}

/** Primera posición >= i que no es blanco ni comentario. */
function saltar(F, i) {
  while (i < F.n && (esBlanco(F.src[i]) || F.tipo[i] === COMENTARIO)) i++
  return i
}

/** Última posición <= i que no es blanco ni comentario. */
function atras(F, i) {
  while (i >= 0 && (esBlanco(F.src[i]) || F.tipo[i] === COMENTARIO)) i--
  return i
}

function leerNombre(F, i) {
  if (F.tipo[i] !== CODIGO || !esIdIni(F.src[i])) return null
  let j = i + 1
  while (j < F.n && esId(F.src[j])) j++
  return { nombre: F.src.slice(i, j), fin: j }
}

/** Palabra que termina en `i` (inclusive), o ''. */
function palabraAntes(F, i) {
  if (i < 0 || !esId(F.src[i])) return ''
  let s = i
  while (s > 0 && esId(F.src[s - 1])) s--
  return F.src.slice(s, i + 1)
}

/** Salta `<...>` de genéricos; devuelve la posición siguiente o -1. */
function saltarGenericos(F, i) {
  let d = 0
  for (let k = i; k < Math.min(F.n, i + 400); k++) {
    if (F.tipo[k] !== CODIGO) continue
    const c = F.src[k]
    if (c === '<') d++
    else if (c === '>' && F.src[k - 1] !== '=') {
      d--
      if (d === 0) return k + 1
    } else if (c === ';') return -1
  }
  return -1
}

/**
 * Sigue `.metodo(args)` encadenados desde `j`. Devuelve las llamadas y dónde
 * termina la cadena (un acceso a propiedad sin llamada la corta).
 */
function leerCadena(F, j) {
  const { src } = F
  const llamadas = []
  let k = j
  for (;;) {
    let a = saltar(F, k)
    if (src[a] === '!' && src[a + 1] !== '=') a = saltar(F, a + 1)
    if (F.tipo[a] !== CODIGO) break
    if (src[a] === '?' && src[a + 1] === '.') a += 2
    else if (src[a] === '.' && src[a + 1] !== '.') a += 1
    else break
    a = saltar(F, a)
    const nom = leerNombre(F, a)
    if (!nom) break
    let p = saltar(F, nom.fin)
    if (src[p] === '<') {
      const g = saltarGenericos(F, p)
      if (g < 0) break
      p = saltar(F, g)
    }
    if (src[p] !== '(' || F.tipo[p] !== CODIGO || F.par[p] < 0) break
    llamadas.push({ metodo: nom.nombre, pos: a, abre: p, cierra: F.par[p] })
    k = F.par[p] + 1
  }
  return { llamadas, fin: k }
}

/** Argumentos de primer nivel de la llamada que abre en `abre`. */
function argumentos(F, abre, cierra) {
  const args = []
  let ini = abre + 1
  for (let k = abre + 1; k <= cierra; k++) {
    if (k === cierra || (F.tipo[k] === CODIGO && F.src[k] === ',')) {
      const a = saltar(F, ini)
      const b = atras(F, k - 1) + 1
      if (a < b) args.push({ ini: a, fin: b })
      ini = k + 1
      continue
    }
    if (F.tipo[k] === CODIGO && '([{'.includes(F.src[k]) && F.par[k] > k) k = F.par[k]
  }
  return args
}

/**
 * Fin de la expresión que arranca en `ini`: un `;`, una `,` o un cierre de
 * primer nivel, o un salto de línea que no continúa (este repo no usa `;`).
 */
function finExpresion(F, ini) {
  const { src } = F
  let ultimo = -1
  let k = ini
  while (k < F.n) {
    const t = F.tipo[k]
    if (t === COMENTARIO) {
      k++
      continue
    }
    if (t === TEXTO) {
      ultimo = k
      k++
      continue
    }
    const c = src[k]
    if (c === '(' || c === '[' || c === '{') {
      if (F.par[k] < 0) return F.n
      k = F.par[k] + 1
      ultimo = k - 1
      continue
    }
    if (c === ')' || c === ']' || c === '}' || c === ';' || c === ',') return k
    if (c === '\n') {
      const sig = saltar(F, k)
      if (sig >= F.n) return k
      if (continua(F, ultimo, sig)) {
        k = sig
        continue
      }
      return k
    }
    if (!esBlanco(c)) ultimo = k
    k++
  }
  return F.n
}

function continua(F, ultimo, sig) {
  const { src } = F
  if (ultimo >= 0 && F.tipo[ultimo] === CODIGO) {
    if ('=(,?:&|+-*/%<>!.[{'.includes(src[ultimo])) return true
    if (['await', 'return', 'typeof', 'new', 'as', 'in', 'of', 'instanceof'].includes(palabraAntes(F, ultimo))) return true
  }
  const c = src[sig]
  if (c === '.' || c === '?' || c === ':' || c === '&' || c === '|' || c === '+' || c === '*' || c === '%') return true
  if (c === '=' && src[sig + 1] !== '>') return false
  if (/^(as|satisfies|instanceof)\b/.test(src.slice(sig, sig + 11))) return true
  return false
}

/** Recorta blancos y comentarios al final de [a, b). */
function recortar(F, a, b) {
  return [saltar(F, a), atras(F, b - 1) + 1]
}

/** `?` de un ternario de primer nivel en [a, b), con su `:`. */
function ternario(F, a, b) {
  const { src } = F
  for (let k = a; k < b; k++) {
    if (F.tipo[k] !== CODIGO) continue
    const c = src[k]
    if ('([{'.includes(c) && F.par[k] > k) {
      k = F.par[k]
      continue
    }
    if (c !== '?' || src[k + 1] === '.' || src[k + 1] === '?' || src[k - 1] === '?') continue
    let d = 0
    for (let m = k + 1; m < b; m++) {
      if (F.tipo[m] !== CODIGO) continue
      const e = src[m]
      if ('([{'.includes(e) && F.par[m] > m) {
        m = F.par[m]
        continue
      }
      if (e === '?' && src[m + 1] !== '.' && src[m + 1] !== '?' && src[m - 1] !== '?') d++
      else if (e === ':') {
        if (d === 0) return { si: [k + 1, m], no: [m + 1, b] }
        d--
      }
    }
    return null
  }
  return null
}

/** Partes de [a, b) separadas por `+` de primer nivel. */
function partirSuma(F, a, b) {
  const partes = []
  let ini = a
  for (let k = a; k < b; k++) {
    if (F.tipo[k] !== CODIGO) continue
    const c = F.src[k]
    if ('([{'.includes(c) && F.par[k] > k) {
      k = F.par[k]
      continue
    }
    if (c === '+' && F.src[k + 1] !== '+' && F.src[k + 1] !== '=' && F.src[k - 1] !== '+') {
      partes.push([ini, k])
      ini = k + 1
    }
  }
  partes.push([ini, b])
  return partes
}

// ─────────────────────── declaraciones y funciones ───────────────────────

/** Posición del `=` de una declaración después de `k` (salteando el tipo), o -1. */
function buscarIgual(F, k) {
  const { src } = F
  k = saltar(F, k)
  if (src[k] === '=' && src[k + 1] !== '=' && src[k + 1] !== '>') return k
  if (src[k] !== ':' && src[k] !== '!') return -1
  let d = 0
  for (let m = k + 1; m < Math.min(F.n, k + 500); m++) {
    if (F.tipo[m] !== CODIGO) continue
    const c = src[m]
    if ('([{'.includes(c)) {
      if (F.par[m] < 0) return -1
      m = F.par[m]
      continue
    }
    if (c === '<') d++
    else if (c === '>' && src[m - 1] !== '=') d--
    else if (c === '=' && d <= 0 && src[m + 1] !== '=' && src[m + 1] !== '>' && !'=!<>'.includes(src[m - 1])) return m
    else if (c === ';' || c === ')' || c === '}' || c === ']') return -1
  }
  return -1
}

/** Fin del alcance de algo declarado en `pos`: la llave que lo envuelve, o el archivo. */
function finDeBloque(F, pos) {
  const l = F.llave[pos]
  return l < 0 || F.par[l] < 0 ? F.n : F.par[l]
}

function nombresDeParametros(F, abre, cierra) {
  const out = []
  for (const a of argumentos(F, abre, cierra)) {
    const m = /^(?:\.\.\.)?\s*([A-Za-z_$][\w$]*)/.exec(F.src.slice(a.ini, a.fin))
    if (m && m[1] !== 'this') out.push({ nombre: m[1], pos: a.ini })
  }
  return out
}

/** Cuerpo de una función a partir de `k` (después de sus parámetros y tipo de retorno). */
function cuerpoDesde(F, k, flecha) {
  const { src } = F
  let a = saltar(F, k)
  if (flecha) {
    if (src[a] === '{' && F.par[a] > a) return [a, F.par[a]]
    return [a, finExpresion(F, a)]
  }
  let d = 0
  for (let m = a; m < Math.min(F.n, a + 500); m++) {
    if (F.tipo[m] !== CODIGO) continue
    const c = src[m]
    if (c === '<') d++
    else if (c === '>' && src[m - 1] !== '=') d--
    else if (c === '{' && d === 0) return F.par[m] > m ? [m, F.par[m]] : null
    else if ((c === '(' || c === '[' || c === '{') && F.par[m] > m) m = F.par[m]
    else if (c === ';') return null
  }
  return null
}

/** Si el `(` de una flecha es el valor de `const NOMBRE = (async)? (<T>)? (`, NOMBRE. */
function nombreDeFlecha(F, abre) {
  let p = atras(F, abre - 1)
  if (F.src[p] === '>') {
    let d = 0
    for (let m = p; m >= Math.max(0, p - 300); m--) {
      if (F.tipo[m] !== CODIGO) continue
      if (F.src[m] === '>') d++
      else if (F.src[m] === '<' && --d === 0) {
        p = atras(F, m - 1)
        break
      }
    }
  }
  if (palabraAntes(F, p) === 'async') p = atras(F, p - 5)
  if (F.src[p] !== '=' || '=!<>'.includes(F.src[p - 1])) return null
  const q = atras(F, p - 1)
  const nombre = palabraAntes(F, q)
  return nombre && esIdIni(nombre[0]) ? nombre : null
}

/**
 * Declaraciones del archivo (`const/let/var x = ...` y parámetros de
 * funciones) y funciones con nombre. El primer parámetro de una función con
 * nombre es el candidato a builder de un helper.
 */
function declarar(F) {
  const { src } = F
  const ligaduras = []
  const funciones = []

  // El lookahead evita que `as const\nconst B` lea `const` como nombre y se coma la declaración de B.
  const reDecl = /\b(const|let|var)\s+(?!(?:const|let|var|enum)\b)([A-Za-z_$][\w$]*)/g
  let m
  while ((m = reDecl.exec(src))) {
    if (F.tipo[m.index] !== CODIGO || (m.index > 0 && esId(src[m.index - 1]))) continue
    const pos = m.index + m[0].length - m[2].length
    const igual = buscarIgual(F, pos + m[2].length)
    const rhs = igual < 0 ? null : recortar(F, igual + 1, finExpresion(F, saltar(F, igual + 1)))
    ligaduras.push({ nombre: m[2], pos, fin: finDeBloque(F, pos), tipo: 'decl', rhs })
  }

  const nueva = (nombre, abre, cierra, cuerpo) => {
    const fn = nombre ? { id: `${F.ruta}#${nombre}@${abre}`, nombre, ruta: F.ruta, cuerpo } : null
    if (fn) funciones.push(fn)
    const params = nombresDeParametros(F, abre, cierra)
    params.forEach((p, i) => {
      ligaduras.push({ nombre: p.nombre, pos: p.pos, fin: cuerpo ? cuerpo[1] : F.n, tipo: 'param', fn: i === 0 && fn ? fn.id : null })
    })
  }

  const reFn = /\bfunction\b\s*\*?\s*([A-Za-z_$][\w$]*)?\s*/g
  while ((m = reFn.exec(src))) {
    if (F.tipo[m.index] !== CODIGO) continue
    let p = m.index + m[0].length
    if (src[p] === '<') {
      const g = saltarGenericos(F, p)
      if (g < 0) continue
      p = saltar(F, g)
    }
    if (src[p] !== '(' || F.par[p] < 0) continue
    nueva(m[1] ?? null, p, F.par[p], cuerpoDesde(F, F.par[p] + 1, false))
  }

  // Flechas `(a, b) =>` y `(a): T =>`.
  for (let i = 0; i < F.n; i++) {
    if (F.tipo[i] !== CODIGO || src[i] !== '(' || F.par[i] < 0) continue
    const c = F.par[i]
    let q = saltar(F, c + 1)
    let flecha = -1
    if (src[q] === '=' && src[q + 1] === '>') flecha = q
    else if (src[q] === ':') {
      let d = 0
      for (let k = q + 1; k < Math.min(F.n, q + 300); k++) {
        if (F.tipo[k] !== CODIGO) continue
        const e = src[k]
        if (e === '=' && src[k + 1] === '>') {
          if (d === 0) flecha = k
          break
        }
        if (e === '<') d++
        else if (e === '>') d--
        else if (e === '(' && d === 0) break
        else if ((e === '[' || e === '{' || e === '(') && F.par[k] > k) k = F.par[k]
        else if (d === 0 && (e === ';' || e === ')' || e === ']' || e === '}' || e === ',' || e === '=')) break
      }
    }
    if (flecha < 0) continue
    nueva(nombreDeFlecha(F, i), i, c, cuerpoDesde(F, flecha + 2, true))
  }

  // Flechas de un solo parámetro sin paréntesis: `x => ...`.
  const reFlecha = /=>/g
  while ((m = reFlecha.exec(src))) {
    if (F.tipo[m.index] !== CODIGO) continue
    const r = atras(F, m.index - 1)
    const w = palabraAntes(F, r)
    if (!w || !esIdIni(w[0]) || RESERVADAS.has(w)) continue
    const antes = src[atras(F, r - w.length)]
    if (antes === ':' || antes === ')' || antes === '>' || esId(antes)) continue
    const cuerpo = cuerpoDesde(F, m.index + 2, true)
    ligaduras.push({ nombre: w, pos: r - w.length + 1, fin: cuerpo ? cuerpo[1] : F.n, tipo: 'param', fn: null })
  }

  F.ligaduras = new Map()
  for (const l of ligaduras.sort((a, b) => a.pos - b.pos)) {
    if (!F.ligaduras.has(l.nombre)) F.ligaduras.set(l.nombre, [])
    F.ligaduras.get(l.nombre).push(l)
  }
  F.funciones = funciones
}

/** `import { A, B as C } from './x'` y `export { A } from './x'`. */
function leerImports(F) {
  F.imports = new Map()
  F.reexports = []
  const re = /\b(import|export)\s+(?:type\s+)?(?:[A-Za-z_$][\w$]*\s*,\s*)?(\{[^}]*\}|\*)\s*from\s*['"]([^'"]+)['"]/g
  let m
  while ((m = re.exec(F.src))) {
    if (F.tipo[m.index] !== CODIGO) continue
    const nombres = new Map()
    if (m[2] !== '*') {
      for (const parte of m[2].slice(1, -1).split(',')) {
        const x = /^\s*(?:type\s+)?([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?\s*$/.exec(parte)
        if (x) nombres.set(x[2] ?? x[1], x[1])
      }
    }
    if (m[1] === 'import') for (const [local, orig] of nombres) F.imports.set(local, { modulo: m[3], nombre: orig })
    else F.reexports.push({ modulo: m[3], nombres: m[2] === '*' ? null : nombres })
  }
}

// ───────────────────────────── el repo ─────────────────────────────

function dirname(ruta) {
  const i = ruta.lastIndexOf('/')
  return i < 0 ? '' : ruta.slice(0, i)
}

function normalizar(ruta) {
  const out = []
  for (const p of ruta.split('/')) {
    if (p === '..') out.pop()
    else if (p !== '.' && p !== '') out.push(p)
  }
  return out.join('/')
}

function crearContexto(fuentes) {
  const archivos = new Map()
  for (const [ruta, src] of fuentes) {
    const F = prepararArchivo(ruta, src)
    declarar(F)
    leerImports(F)
    archivos.set(ruta, F)
  }
  // Constantes de módulo de todo el repo, por nombre: el último recurso para
  // resolver un nombre que no es local ni se pudo seguir por su import.
  const globales = new Map()
  const funciones = new Map()
  for (const F of archivos.values()) {
    for (const [nombre, ls] of F.ligaduras) {
      for (const l of ls) {
        if (l.tipo === 'decl' && l.rhs && l.fin === F.n) {
          if (!globales.has(nombre)) globales.set(nombre, [])
          globales.get(nombre).push({ F, l })
        }
      }
    }
    for (const fn of F.funciones) {
      if (!funciones.has(fn.nombre)) funciones.set(fn.nombre, [])
      funciones.get(fn.nombre).push(fn)
    }
  }
  return { archivos, globales, funciones, memoValores: new Map(), memoOrigenes: new Map() }
}

function moduloDe(ctx, F, spec) {
  let base
  if (spec.startsWith('.')) base = normalizar(`${dirname(F.ruta)}/${spec}`)
  else if (spec.startsWith('@/')) base = `src/${spec.slice(2)}`
  else return null
  const sinJs = base.replace(/\.(m?js|jsx)$/, '')
  for (const c of [base, `${sinJs}.ts`, `${sinJs}.tsx`, `${sinJs}/index.ts`, `${sinJs}/index.tsx`]) {
    if (ctx.archivos.has(c)) return ctx.archivos.get(c)
  }
  return null
}

/** La ligadura de `nombre` visible en `pos`, o null. */
function ligadura(F, nombre, pos) {
  const ls = F.ligaduras.get(nombre)
  if (!ls) return null
  for (let i = ls.length - 1; i >= 0; i--) {
    const l = ls[i]
    if (l.pos >= pos || pos > l.fin) continue
    if (l.tipo === 'asig' && !l.constructora) continue
    if (l.rhs && pos >= l.rhs[0] && pos < l.rhs[1]) continue
    return l
  }
  // Una constante de módulo declarada más abajo igual es visible desde una función.
  for (let i = ls.length - 1; i >= 0; i--) if (ls[i].tipo === 'decl' && ls[i].fin === F.n) return ls[i]
  return null
}

// ─────────────────────── valores de strings ───────────────────────

function producto(a, b) {
  const out = []
  for (const x of a) for (const y of b) if (out.length < MAX_VARIANTES) out.push(x + y)
  return out
}

/**
 * Valores posibles de la expresión en [a, b) como string: literal, template
 * con `${...}`, constante (local, importada o única en el repo), ternario o
 * suma. null si no se puede saber. Con `comodin`, un `${...}` que no se
 * resuelve vale `COMODIN` (sirve para el valor de un `.or()`, no para un select).
 */
function valores(ctx, F, a, b, comodin = false, prof = 0) {
  ;[a, b] = recortar(F, a, b)
  if (prof > 15 || a >= b) return null
  const clave = `${F.ruta}|${a}|${b}|${comodin}`
  if (ctx.memoValores.has(clave)) return ctx.memoValores.get(clave)
  ctx.memoValores.set(clave, null)
  const r = valoresSinMemo(ctx, F, a, b, comodin, prof)
  ctx.memoValores.set(clave, r)
  return r
}

function valoresSinMemo(ctx, F, a, b, comodin, prof) {
  const { src } = F
  const suf = /\s+(?:as\s+const|as\s+[\w$.]+(?:<[^>]*>)?(?:\[\])?|satisfies\s+[\w$.]+(?:<[^>]*>)?)\s*$/.exec(src.slice(a, b))
  if (suf && F.tipo[a + suf.index + 1] === CODIGO) return valores(ctx, F, a, a + suf.index, comodin, prof + 1)
  if (src[a] === '(' && F.par[a] === b - 1) return valores(ctx, F, a + 1, b - 1, comodin, prof + 1)
  const t = ternario(F, a, b)
  if (t) {
    const si = valores(ctx, F, t.si[0], t.si[1], comodin, prof + 1)
    const no = valores(ctx, F, t.no[0], t.no[1], comodin, prof + 1)
    return si && no ? [...new Set([...si, ...no])] : null
  }
  const sumandos = partirSuma(F, a, b)
  if (sumandos.length > 1) {
    let acc = ['']
    for (const [x, y] of sumandos) {
      const v = valores(ctx, F, x, y, comodin, prof + 1)
      if (!v) return null
      acc = producto(acc, v)
    }
    return acc
  }
  if (src[a] === "'" || src[a] === '"' || src[a] === '`') {
    const lit = literal(ctx, F, a, comodin, prof)
    return lit && lit.fin === b ? lit.valores : null
  }
  const nom = leerNombre(F, a)
  if (nom && nom.fin === b) return valoresDeNombre(ctx, F, nom.nombre, a, comodin, prof)
  return null
}

function literal(ctx, F, a, comodin, prof) {
  const { src } = F
  const q = src[a]
  let partes = ['']
  let j = a + 1
  while (j < F.n) {
    const c = src[j]
    if (c === '\\') {
      partes = partes.map((p) => p + (src[j + 1] ?? ''))
      j += 2
      continue
    }
    if (c === q) return { valores: partes, fin: j + 1 }
    if (q === '`' && c === '$' && src[j + 1] === '{') {
      let d = 0
      let k = j + 2
      for (; k < F.n; k++) {
        if (F.tipo[k] === CODIGO) {
          if (src[k] === '{') d++
          else if (src[k] === '}') d--
        } else if (F.tipo[k] === TEXTO && src[k] === '}' && d === 0) break
      }
      const v = valores(ctx, F, j + 2, k, comodin, prof + 1) ?? (comodin ? [COMODIN] : null)
      if (!v) return null
      partes = producto(partes, v)
      j = k + 1
      continue
    }
    partes = partes.map((p) => p + c)
    j++
  }
  return null
}

function valoresDeNombre(ctx, F, nombre, pos, comodin, prof) {
  const l = ligadura(F, nombre, pos)
  if (l?.tipo === 'param') {
    // `columna: 'cliente_id' | 'pedido_id'`: el tipo del parámetro ya dice los valores.
    const lit = `(?:'[^'\\n]*'|"[^"\\n]*")`
    const m = new RegExp(`^${nombre.replace(/\$/g, '\\$')}\\??\\s*:\\s*(${lit}(?:\\s*\\|\\s*${lit})*)\\s*(?:[,)=]|$)`).exec(F.src.slice(l.pos, l.pos + 400))
    return m ? m[1].split('|').map((x) => x.trim().slice(1, -1)) : null
  }
  if (l) return l.tipo === 'decl' && l.rhs ? valores(ctx, F, l.rhs[0], l.rhs[1], comodin, prof + 1) : null
  const imp = F.imports.get(nombre)
  if (imp) {
    const G = moduloDe(ctx, F, imp.modulo)
    if (G) return valoresExportados(ctx, G, imp.nombre, comodin, prof + 1, 0)
  }
  const defs = ctx.globales.get(nombre) ?? []
  const vs = defs.map((d) => valores(ctx, d.F, d.l.rhs[0], d.l.rhs[1], comodin, prof + 1))
  if (!vs.length || vs.some((v) => !v)) return null
  // Dos constantes con el mismo nombre y distinto valor: no se elige una al azar.
  return vs.every((v) => JSON.stringify(v) === JSON.stringify(vs[0])) ? vs[0] : null
}

function valoresExportados(ctx, G, nombre, comodin, prof, saltos) {
  const l = ligadura(G, nombre, G.n)
  if (l && l.tipo === 'decl' && l.rhs) return valores(ctx, G, l.rhs[0], l.rhs[1], comodin, prof + 1)
  if (saltos > 5) return null
  for (const re of G.reexports) {
    const orig = re.nombres ? re.nombres.get(nombre) : nombre
    if (!orig) continue
    const H = moduloDe(ctx, G, re.modulo)
    const v = H && valoresExportados(ctx, H, orig, comodin, prof, saltos + 1)
    if (v) return v
  }
  return null
}

// ─────────────────────── cadenas y orígenes ───────────────────────

/** Dónde arranca el receptor de `.from` (`supabase`, `this.sb`, `getClient()`). */
function inicioReceptor(F, r) {
  const { src } = F
  let k = r
  let ini = r
  for (let g = 0; g < 50 && k >= 0; g++) {
    const c = src[k]
    if ((c === ')' || c === ']') && F.par[k] >= 0) {
      ini = F.par[k]
      k = atras(F, ini - 1)
      if (k >= 0 && esId(src[k]) && F.tipo[k] === CODIGO) continue
      return ini
    }
    if (esId(c)) {
      let s = k
      while (s > 0 && esId(src[s - 1])) s--
      ini = s
      let antes = atras(F, s - 1)
      if (src[antes] === '!') antes = atras(F, antes - 1)
      if (antes >= 0 && src[antes] === '.' && src[antes - 1] !== '.') {
        k = atras(F, src[antes - 1] === '?' ? antes - 2 : antes - 1)
        continue
      }
      return ini
    }
    return ini
  }
  return ini
}

/** Las cadenas que arrancan en `.from(...)`; cada una es una consulta. */
function cadenasFrom(ctx, F) {
  const { src } = F
  const out = []
  const re = /(\?\.|\.)\s*from\s*\(/g
  let m
  while ((m = re.exec(src))) {
    if (F.tipo[m.index] !== CODIGO) continue
    const r = atras(F, m.index - 1)
    if (r < 0) continue
    // `Array.from`, `Buffer.from`, `Object.from`…: receptor con mayúscula.
    const w = palabraAntes(F, r)
    if (w && /^[A-Z]/.test(w)) continue
    const { llamadas } = leerCadena(F, m.index)
    if (!llamadas.length || llamadas[0].metodo !== 'from') continue
    const args = argumentos(F, llamadas[0].abre, llamadas[0].cierra)
    const v = args[0] ? valores(ctx, F, args[0].ini, args[0].fin) : null
    out.push({
      id: `${F.ruta}@${m.index}`,
      F,
      ini: inicioReceptor(F, r),
      pos: llamadas[0].pos,
      tabla: v && v.length === 1 ? v[0] : null,
      tablaTexto: args[0] ? src.slice(args[0].ini, args[0].fin) : '',
      llamadas: llamadas.slice(1).map((ll) => ({ F, ll })),
    })
  }
  return out
}

/** Orígenes de la expresión [a, b): ids de consulta, `param:<fn>` o `?`. */
function origenesExpr(ctx, F, a, b, prof) {
  ;[a, b] = recortar(F, a, b)
  const desconocido = new Set(['?'])
  if (prof > 15 || a >= b) return desconocido
  const { src } = F
  if (src.startsWith('await', a) && !esId(src[a + 5])) return origenesExpr(ctx, F, a + 5, b, prof + 1)
  if (src[a] === '(' && F.par[a] > a && F.par[a] < b) {
    // `(x as Y)` o `(supabase.from(...))`: se mira adentro.
    return origenesExpr(ctx, F, a + 1, F.par[a], prof + 1)
  }
  const t = ternario(F, a, b)
  if (t) return new Set([...origenesExpr(ctx, F, t.si[0], t.si[1], prof + 1), ...origenesExpr(ctx, F, t.no[0], t.no[1], prof + 1)])
  const cad = F.cadenas.find((c) => c.ini === a)
  if (cad) return new Set([cad.id])
  const nom = leerNombre(F, a)
  if (!nom || RESERVADAS.has(nom.nombre)) return desconocido
  let p = saltar(F, nom.fin)
  if (src[p] === '<') {
    const g = saltarGenericos(F, p)
    if (g > 0) p = saltar(F, g)
  }
  if (src[p] === '(' && F.par[p] > p) {
    if (!ctx.funciones.has(nom.nombre)) return desconocido
    const args = argumentos(F, p, F.par[p])
    return args[0] ? origenesExpr(ctx, F, args[0].ini, args[0].fin, prof + 1) : desconocido
  }
  if (p >= b || src[p] === '.' || src[p] === '?' || src[p] === '!' || palabraAntes(F, p + 1) === 'as' || src.startsWith('as ', p)) {
    return origenesDeNombre(ctx, F, nom.nombre, a, prof + 1)
  }
  return desconocido
}

function origenesDeNombre(ctx, F, nombre, pos, prof) {
  const l = ligadura(F, nombre, pos)
  if (!l) return new Set(['?'])
  if (l.tipo === 'param') return new Set([l.fn ? `param:${l.fn}` : '?'])
  if (!l.rhs) return new Set(['?'])
  const clave = `${F.ruta}|${l.pos}|${l.tipo}`
  if (ctx.memoOrigenes.has(clave)) return ctx.memoOrigenes.get(clave)
  ctx.memoOrigenes.set(clave, new Set(['?']))
  const r = origenesExpr(ctx, F, l.rhs[0], l.rhs[1], prof + 1)
  ctx.memoOrigenes.set(clave, r)
  return r
}

/**
 * Reasignaciones `q = supabase.from(...)` que vuelven a apuntar la variable a
 * otra consulta. `q = q.eq(...)` o `q = helper(q, ...)` no: siguen siendo la
 * misma consulta.
 */
function asignaciones(F) {
  const re = /(?<![\w$])([A-Za-z_$][\w$]*)[ \t]*=(?![=>])/g
  let m
  while ((m = re.exec(F.src))) {
    const i = m.index
    if (F.tipo[i] !== CODIGO || (i > 0 && esId(F.src[i - 1]))) continue
    const antes = atras(F, i - 1)
    if (F.src[antes] === '.' || ['const', 'let', 'var', 'type'].includes(palabraAntes(F, antes))) continue
    const igual = i + m[0].length - 1
    const ini = saltar(F, igual + 1)
    const rhs = recortar(F, ini, finExpresion(F, ini))
    const cad = F.cadenas.find((c) => c.ini === rhs[0] || (F.src.startsWith('await', rhs[0]) && c.ini === saltar(F, rhs[0] + 5)))
    if (!cad && !ternario(F, rhs[0], rhs[1])) continue
    const decl = ligadura(F, m[1], i)
    const l = { nombre: m[1], pos: i, fin: decl ? decl.fin : F.n, tipo: 'asig', rhs, constructora: true }
    if (!cad) {
      // Ternario: es constructora si alguna rama arranca con una cadena .from.
      const t = ternario(F, rhs[0], rhs[1])
      const ramas = [recortar(F, ...t.si)[0], recortar(F, ...t.no)[0]]
      if (!F.cadenas.some((c) => ramas.includes(c.ini))) continue
    }
    if (!F.ligaduras.has(m[1])) F.ligaduras.set(m[1], [])
    const ls = F.ligaduras.get(m[1])
    ls.push(l)
    ls.sort((x, y) => x.pos - y.pos)
  }
}

// ─────────────────────── qué dice cada llamada ───────────────────────

function firma(F, ll) {
  const args = F.src.slice(ll.abre + 1, ll.cierra).replace(/\s+/g, ' ').trim()
  return `${ll.metodo}(${args.length > 120 ? `${args.slice(0, 117)}...` : args})`
}

/** `{ referencedTable: 'x' }` / `foreignTable`: la ruta, null si no hay, o `false` si no es literal. */
function rutaDeOpciones(ctx, F, arg) {
  if (!arg) return null
  const texto = F.src.slice(arg.ini, arg.fin)
  const m = /\b(?:referencedTable|foreignTable)\s*:\s*/.exec(texto)
  if (!m) return null
  const a = arg.ini + m.index + m[0].length
  const v = valores(ctx, F, a, finExpresion(F, a))
  return v && v.length === 1 ? v[0].split('.') : false
}

/**
 * Lo que aporta una llamada de la cadena: un select (con sus variantes ya
 * limpias), un filtro/orden (con la ruta del embed si mira uno) o nada.
 */
function describir(ctx, F, ll) {
  const args = argumentos(F, ll.abre, ll.cierra)
  const base = { archivo: F.ruta, linea: lineaDe(F, ll.pos), metodo: ll.metodo, firma: firma(F, ll) }
  const m = ll.metodo
  if (m === 'select') {
    if (!args.length) return { ...base, tipo: 'select', valores: ['*'] }
    const v = valores(ctx, F, args[0].ini, args[0].fin)
    return { ...base, tipo: 'select', valores: v ? [...new Set(v.map(limpiarSelect))] : null }
  }
  if (FILTROS_COLUMNA.has(m)) {
    const v = args[0] ? valores(ctx, F, args[0].ini, args[0].fin) : null
    if (!v) return { ...base, tipo: 'filtro', ruta: [], columnas: null }
    // Cada variante puede apuntar a otra ruta; en este repo no pasa, se toma la primera forma.
    const partes = v[0].split('.')
    return { ...base, tipo: 'filtro', ruta: partes.slice(0, -1), columnas: [...new Set(v.map((x) => x.split('.').at(-1)))] }
  }
  if (m === 'match') {
    if (!args[0] || F.src[args[0].ini] !== '{') return { ...base, tipo: 'otro' }
    const claves = [...F.src.slice(args[0].ini, args[0].fin).matchAll(/[{,]\s*(?:'([^']+)'|"([^"]+)"|([A-Za-z_$][\w$]*))\s*:/g)]
      .map((x) => x[1] ?? x[2] ?? x[3])
    return claves.filter((c) => c.includes('.')).map((c) => ({
      ...base, tipo: 'filtro', ruta: c.split('.').slice(0, -1), columnas: [c.split('.').at(-1)],
    }))
  }
  if (m === 'or') {
    const ruta = rutaDeOpciones(ctx, F, args[1])
    if (ruta === false) return { ...base, tipo: 'or', ruta: [], columnas: null, problema: 'referencedTable no literal' }
    const v = args[0] ? valores(ctx, F, args[0].ini, args[0].fin, true) : null
    let columnas = null
    let problema = null
    if (v) {
      try {
        columnas = [...new Set(v.flatMap(columnasDeOr))]
        if (columnas.some((c) => c.includes(COMODIN))) {
          columnas = null
          problema = 'columna interpolada en el .or()'
        }
      } catch (e) {
        problema = e.message
      }
    } else problema = 'el string del .or() no se puede leer'
    return { ...base, tipo: 'or', ruta: ruta ?? [], columnas, problema: ruta || columnas?.some((c) => c.includes('.')) ? problema : null }
  }
  if (m === 'order') {
    const ruta = rutaDeOpciones(ctx, F, args[1])
    const v = args[0] ? valores(ctx, F, args[0].ini, args[0].fin) : null
    if (ruta === false) return { ...base, tipo: 'orden', ruta: [], columnas: v, problema: 'referencedTable no literal' }
    if (ruta) return { ...base, tipo: 'orden', ruta, columnas: v, problema: v ? null : 'columna del .order() no literal' }
    const rel = v && v.length === 1 && /^([A-Za-z_][\w]*)\(([A-Za-z_][\w]*)\)$/.exec(v[0])
    if (rel) return { ...base, tipo: 'ordenRel', ruta: [rel[1]], columnas: [rel[2]] }
    return { ...base, tipo: 'orden', ruta: [], columnas: v }
  }
  if (m === 'limit' || m === 'range') {
    const ruta = rutaDeOpciones(ctx, F, args[m === 'limit' ? 1 : 2])
    if (ruta === false) return { ...base, tipo: 'limite', ruta: [], problema: 'referencedTable no literal' }
    if (ruta) return { ...base, tipo: 'limite', ruta }
  }
  return { ...base, tipo: 'otro' }
}

/** ¿Una llamada, vista sola, toca un embed (select con embed o filtro embebido)? */
function tocaEmbed(d) {
  if (d.tipo === 'select') {
    return (d.valores ?? []).some((v) => {
      try {
        return tieneEmbed(parsearSelect(v))
      } catch {
        return v.includes('(')
      }
    })
  }
  return esEmbebido(d) || !!d.problema
}

// ───────────────────────────── análisis ─────────────────────────────

/**
 * Analiza los fuentes (`[ruta, contenido][]`, rutas posix relativas a la raíz).
 *
 * @returns {{
 *   consultas: { id: string, archivo: string, linea: number, tabla: string|null,
 *     selects: { archivo: string, linea: number, valores: string[]|null }[],
 *     variantes: string[], filtros: object[] }[],
 *   omitidos: { archivo: string, linea: number, motivo: string, firma: string }[]
 * }}
 */
export function analizarRepo(fuentes) {
  const ctx = crearContexto(fuentes)
  const consultas = []
  const porOrigen = new Map()
  const sitiosHelper = []
  const consumidas = new Set()
  const omitidos = []
  // Cada llamada atribuida lleva su GRUPO: las consultas a las que se aplicó
  // juntas. `const base = x ? supabase.from(a).select(A) : supabase.from(a).select(B)`
  // seguido de `helper(base)` le aplica el helper a las dos, y un filtro del
  // helper que sólo tiene sentido con una de ellas no es huérfano.
  const agregar = (origenes, items) => {
    const grupo = [...origenes].filter((o) => o !== '?' && !o.startsWith('param:')).sort()
    for (const o of origenes) {
      if (!porOrigen.has(o)) porOrigen.set(o, [])
      porOrigen.get(o).push(...items.map((x) => ({ ...x, grupo })))
    }
  }

  for (const F of ctx.archivos.values()) {
    F.cadenas = cadenasFrom(ctx, F)
    for (const c of F.cadenas) {
      consultas.push(c)
      consumidas.add(`${F.ruta}@${c.pos}`)
      for (const { ll } of c.llamadas) consumidas.add(`${F.ruta}@${ll.pos}`)
    }
  }
  for (const F of ctx.archivos.values()) asignaciones(F)

  for (const F of ctx.archivos.values()) {
    const { src } = F
    const re = /[A-Za-z_$][\w$]*/g
    let m
    while ((m = re.exec(src))) {
      const i = m.index
      if (F.tipo[i] !== CODIGO || (i > 0 && esId(src[i - 1])) || RESERVADAS.has(m[0])) continue
      const antes = atras(F, i - 1)
      if (src[antes] === '.' && src[antes - 1] !== '.') continue
      let p = saltar(F, i + m[0].length)
      if (src[p] === '<' && ctx.funciones.has(m[0])) {
        const g = saltarGenericos(F, p)
        if (g > 0) p = saltar(F, g)
      }
      if (src[p] === '(' && F.par[p] > p) {
        // Llamada a una función con nombre del repo: posible helper que filtra
        // el builder que le pasan como primer argumento.
        if (!ctx.funciones.has(m[0]) || palabraAntes(F, antes) === 'function') continue
        const args = argumentos(F, p, F.par[p])
        if (!args.length) continue
        const origenes = origenesExpr(ctx, F, args[0].ini, args[0].fin, 0)
        const cont = leerCadena(F, F.par[p] + 1).llamadas
        sitiosHelper.push({ nombre: m[0], F, pos: i, origenes })
        if (cont.length) {
          const items = cont.map((ll) => ({ F, ll }))
          agregar(origenes, items)
          if (!origenes.has('?')) for (const ll of cont) consumidas.add(`${F.ruta}@${ll.pos}`)
        }
        continue
      }
      const { llamadas } = leerCadena(F, i + m[0].length)
      const corte = llamadas.findIndex((ll) => ll.metodo === 'from')
      const propias = corte < 0 ? llamadas : llamadas.slice(0, corte)
      if (!propias.some((ll) => RELEVANTES.has(ll.metodo))) continue
      const origenes = origenesDeNombre(ctx, F, m[0], i, 0)
      const items = propias.map((ll) => ({ F, ll }))
      agregar(origenes, items)
      if (!origenes.has('?')) for (const ll of propias) consumidas.add(`${F.ruta}@${ll.pos}`)
    }
  }

  // Llamadas que un helper le aplica a su primer parámetro, con las de los
  // helpers que llama a su vez sobre el mismo parámetro.
  const memo = new Map()
  const sitiosPorParam = new Map()
  for (const s of sitiosHelper) {
    for (const o of s.origenes) {
      if (!o.startsWith('param:')) continue
      if (!sitiosPorParam.has(o)) sitiosPorParam.set(o, [])
      sitiosPorParam.get(o).push(s)
    }
  }
  const llamadasDe = (fn) => {
    if (memo.has(fn.id)) return memo.get(fn.id)
    memo.set(fn.id, [])
    const out = [...(porOrigen.get(`param:${fn.id}`) ?? [])]
    for (const s of sitiosPorParam.get(`param:${fn.id}`) ?? []) {
      for (const g of ctx.funciones.get(s.nombre)) out.push(...llamadasDe(g))
    }
    memo.set(fn.id, out)
    return out
  }
  for (const s of sitiosHelper) {
    const delHelper = ctx.funciones.get(s.nombre).flatMap(llamadasDe)
    if (!delHelper.length) continue
    const destino = new Set([...s.origenes].filter((o) => !o.startsWith('param:')))
    if ([...destino].some((o) => o !== '?')) agregar(destino, delHelper)
    if (s.origenes.has('?')) {
      const embebidas = delHelper.map(({ F, ll }) => describir(ctx, F, ll)).flat().filter(tocaEmbed)
      if (embebidas.length) {
        omitidos.push({
          archivo: s.F.ruta,
          linea: lineaDe(s.F, s.pos),
          motivo: `${s.nombre}() aplica filtros sobre embeds a un builder que no se puede atribuir a una consulta`,
          firma: `${s.nombre}(${s.F.src.slice(s.pos + s.nombre.length).match(/^\s*\(([^,)]*)/)?.[1]?.trim() ?? ''}`,
        })
      }
    }
  }

  const salida = []
  for (const c of consultas) {
    const todas = [...c.llamadas.map((x) => ({ ...x, grupo: [c.id] })), ...(porOrigen.get(c.id) ?? [])]
    const vistas = new Set()
    const descripciones = []
    for (const { F, ll, grupo } of todas) {
      const k = `${F.ruta}@${ll.pos}`
      if (vistas.has(k)) continue
      vistas.add(k)
      descripciones.push(...[describir(ctx, F, ll)].flat().map((d) => ({ ...d, grupo: grupo.join(',') })))
    }
    const selects = descripciones.filter((d) => d.tipo === 'select')
    const filtros = descripciones.filter((d) => d.tipo !== 'select' && d.tipo !== 'otro')
    const linea = selects[0]?.linea ?? lineaDe(c.F, c.pos)
    const relevante = selects.length > 0 || filtros.some(tocaEmbed)
    if (!relevante) continue
    if (c.tabla == null) {
      omitidos.push({ archivo: c.F.ruta, linea, motivo: `tabla no resuelta en .from(${c.tablaTexto})`, firma: `from(${c.tablaTexto})` })
      continue
    }
    for (const s of selects) {
      if (!s.valores) omitidos.push({ archivo: s.archivo, linea: s.linea, motivo: `select no resuelto: ${s.firma}`, firma: s.firma })
    }
    for (const f of filtros) {
      // Una columna que no se puede leer puede ser `rel.col` (un filtro embebido
      // que no se probaría) o una columna sin grant: las dos cosas quedan ciegas.
      if (!f.problema && (f.tipo === 'filtro' || f.tipo === 'orden') && !f.columnas) f.problema = 'columna no resuelta'
      if (f.problema) omitidos.push({ archivo: f.archivo, linea: f.linea, motivo: `${f.problema}: ${f.firma}`, firma: f.firma })
    }
    salida.push({
      id: c.id,
      archivo: c.F.ruta,
      linea,
      tabla: c.tabla,
      selects: selects.map(({ archivo, linea: l, valores: v }) => ({ archivo, linea: l, valores: v })),
      variantes: [...new Set(selects.flatMap((s) => s.valores ?? []))],
      filtros: filtros.filter((f) => !f.problema),
    })
  }

  // Lo que quedó suelto: un select con embed o un filtro embebido que no está
  // en ninguna cadena atribuida a una consulta.
  const reSuelta = new RegExp(`(\\?\\.|\\.)\\s*(${[...RELEVANTES].join('|')})\\s*\\(`, 'g')
  for (const F of ctx.archivos.values()) {
    let m
    while ((m = reSuelta.exec(F.src))) {
      if (F.tipo[m.index] !== CODIGO) continue
      const pos = saltar(F, m.index + m[1].length)
      if (consumidas.has(`${F.ruta}@${pos}`)) continue
      const abre = F.src.indexOf('(', pos)
      if (F.par[abre] < 0) continue
      const ll = { metodo: m[2], pos, abre, cierra: F.par[abre] }
      const ds = [describir(ctx, F, ll)].flat()
      if (!ds.some(tocaEmbed)) continue
      omitidos.push({ archivo: F.ruta, linea: lineaDe(F, pos), motivo: `.${m[2]}() sobre un embed fuera de una consulta atribuible`, firma: firma(F, ll) })
    }
  }

  return { consultas: salida, omitidos }
}
