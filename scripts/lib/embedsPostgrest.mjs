/**
 * Lo que el gate de embeds (`scripts/check-embeds.mjs`, #1008 y #1256) sabe de
 * PostgREST: cómo lee un `select`, cómo lee un `.or()`, qué parámetros manda
 * supabase-js por cada filtro u orden sobre un recurso embebido, y qué columnas
 * tiene que poder leer `authenticated` para que la consulta no tire 42501.
 *
 * Es todo puro (sin red) para poder testearlo con un mapa de privilegios de
 * mentira: el gate le pasa el mapa de verdad, que sale de la RPC
 * `auditoria_lectura_authenticated()`.
 */

/**
 * supabase-js saca TODOS los espacios del select antes de mandarlo, salvo los
 * que van entre comillas dobles; PostgREST no tolera `( id` ni `peso) )`, así
 * que se prueba lo que realmente viaja.
 */
export function limpiarSelect(s) {
  let comillas = false
  let out = ''
  for (const c of s) {
    if (/\s/.test(c) && !comillas) continue
    if (c === '"') comillas = !comillas
    out += c
  }
  return out
}

const NOMBRE = /"(?:[^"\\]|\\.)*"|[A-Za-z_][\w$]*/y
const CLAVE_JSON = /"(?:[^"\\]|\\.)*"|'[^']*'|[\w$]+/y
const TIPO_CAST = /[\w[\]]+/y
const AGREGADO = /\.(sum|avg|min|max|count)\(\)/y

function leer(p, re) {
  re.lastIndex = p.i
  const m = re.exec(p.s)
  if (!m) return null
  p.i = re.lastIndex
  return m[0]
}

function nombre(p) {
  const n = leer(p, NOMBRE)
  return n == null ? null : n.replace(/^"|"$/g, '')
}

function errorEn(p, que) {
  return new Error(`select no parsea (${que}) en "${p.s.slice(Math.max(0, p.i - 15), p.i)}⟨aquí⟩${p.s.slice(p.i, p.i + 15)}"`)
}

function cast(p) {
  if (!p.s.startsWith('::', p.i)) return
  p.i += 2
  if (leer(p, TIPO_CAST) == null) throw errorEn(p, 'cast sin tipo')
}

function item(p) {
  if (p.s[p.i] === '*') {
    p.i++
    return { tipo: 'estrella' }
  }
  let spread = false
  if (p.s.startsWith('...', p.i)) {
    spread = true
    p.i += 3
  }
  let alias = null
  let n = nombre(p)
  if (n == null) throw errorEn(p, 'se esperaba un nombre')
  if (p.s[p.i] === ':' && p.s[p.i + 1] !== ':') {
    alias = n
    p.i++
    n = nombre(p)
    if (n == null) throw errorEn(p, 'alias sin nombre')
  }
  const hints = []
  let inner = false
  while (p.s[p.i] === '!') {
    p.i++
    const h = nombre(p)
    if (h == null) throw errorEn(p, 'hint vacío')
    if (h === 'inner') inner = true
    else if (h !== 'left') hints.push(h)
  }
  if (p.s[p.i] === '(') {
    // `count()` sin columna es el agregado, no un embed de una tabla "count".
    if (n === 'count' && p.s[p.i + 1] === ')' && !hints.length && !spread) {
      p.i += 2
      cast(p)
      return { tipo: 'conteo', alias }
    }
    p.i++
    const hijos = p.s[p.i] === ')' ? [] : lista(p)
    if (p.s[p.i] !== ')') throw errorEn(p, 'falta ")"')
    p.i++
    return { tipo: 'embed', alias, nombre: n, hints, inner, spread, hijos }
  }
  if (spread || hints.length) throw errorEn(p, 'spread o hint sin "(...)"')
  // `col->a->>b`: se pide la columna base.
  while (p.s.startsWith('->', p.i)) {
    p.i += p.s[p.i + 2] === '>' ? 3 : 2
    if (leer(p, CLAVE_JSON) == null) throw errorEn(p, 'clave JSON vacía')
  }
  const ag = leer(p, AGREGADO)
  cast(p)
  return { tipo: 'columna', alias, columna: n, agregado: ag ? ag.slice(1, -2) : null }
}

function lista(p) {
  const nodos = []
  for (;;) {
    nodos.push(item(p))
    if (p.s[p.i] !== ',') return nodos
    p.i++
  }
}

/**
 * Árbol de un select ya limpio: `*`, `col`, `alias:col`, `col::cast`,
 * `col->a->>b`, `col.sum()`, `count()`, `alias:rel!hint!inner(...)`,
 * `...rel(...)` y `rel(count)`. Tira Error si no lo entiende.
 */
export function parsearSelect(s) {
  if (s === '') return []
  const p = { s, i: 0 }
  const nodos = lista(p)
  if (p.i !== s.length) throw errorEn(p, 'sobra texto')
  return nodos
}

export function tieneEmbed(nodos) {
  return nodos.some((n) => n.tipo === 'embed')
}

/** El nodo embebido al que apunta `ruta` (por alias o por nombre, como lo acepta PostgREST). */
export function buscarRuta(nodos, ruta) {
  let actuales = nodos
  let nodo = null
  for (const seg of ruta) {
    nodo = actuales.find((n) => n.tipo === 'embed' && (n.alias === seg || n.nombre === seg)) ?? null
    if (!nodo) return null
    actuales = nodo.hijos
  }
  return nodo
}

const OPERADORES = new Set([
  'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'ilike', 'match', 'imatch', 'in', 'is',
  'isdistinct', 'fts', 'plfts', 'phfts', 'wfts', 'cs', 'cd', 'ov', 'sl', 'sr', 'nxr', 'nxl',
  'adj', 'not',
])

/** Parte por comas de primer nivel: ni dentro de `(...)` ni entre comillas dobles. */
function partirTope(s) {
  const partes = []
  let prof = 0
  let comillas = false
  let ini = 0
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (c === '\\') {
      i++
      continue
    }
    if (c === '"') comillas = !comillas
    if (comillas) continue
    if (c === '(') prof++
    else if (c === ')') prof--
    else if (c === ',' && prof === 0) {
      partes.push(s.slice(ini, i))
      ini = i + 1
    }
  }
  partes.push(s.slice(ini))
  return partes.filter((x) => x !== '')
}

/**
 * Columnas de un `.or('a.eq.1,and(b.is.null,c.gt.2)')`. La columna es todo lo
 * que hay antes del primer operador (`rel.col.eq.x` da `rel.col`): el valor
 * puede traer puntos, comas entre paréntesis o un `${...}` interpolado y no
 * importa. Tira Error si un elemento no tiene operador.
 */
export function columnasDeOr(s) {
  const cols = []
  for (const e of partirTope(limpiarSelect(s))) {
    const m = /^(?:not\.)?(and|or)\((.*)\)$/s.exec(e)
    if (m) {
      cols.push(...columnasDeOr(m[2]))
      continue
    }
    const t = e.split('.')
    const i = t.findIndex((x, k) => k > 0 && OPERADORES.has(x))
    if (i < 1) throw new Error(`condición de .or() sin operador: "${e}"`)
    cols.push(t.slice(0, i).join('.'))
  }
  return [...new Set(cols)]
}

/** `col->>a::text` → `col`: el privilegio es sobre la columna base. */
export function columnaBase(c) {
  return c.replace(/->.*$/, '').replace(/::.*$/, '')
}

/** ¿El filtro mira un recurso embebido? */
export function esEmbebido(f) {
  if (f.ruta?.length) return true
  return f.tipo === 'or' && (f.columnas ?? []).some((c) => c.includes('.'))
}

/** Rutas de embed que el filtro necesita en el select para resolver. */
function rutasDe(f) {
  if (f.ruta?.length) return [f.ruta]
  return (f.columnas ?? []).filter((c) => c.includes('.')).map((c) => c.split('.').slice(0, -1))
}

/**
 * Parámetros con los que se prueba el filtro, armados como los manda
 * supabase-js pero con valores inocuos: `is.null` sirve para cualquier tipo
 * (un `eq.x` sobre un bigint daría 22P02 y taparía lo que se quiere ver).
 */
function parametrosDe(f) {
  const r = f.ruta?.join('.')
  switch (f.tipo) {
    case 'filtro':
      return f.columnas.map((c) => [`${r}.${c}`, 'is.null'])
    case 'or':
      return [[r ? `${r}.or` : 'or', `(${f.columnas.map((c) => `${c}.is.null`).join(',')})`]]
    case 'orden':
      return [[`${r}.order`, f.columnas.join(',')]]
    case 'ordenRel':
      return [['order', `${r}(${f.columnas[0]})`]]
    case 'limite':
      return [[`${r}.limit`, '0']]
    default:
      return []
  }
}

/**
 * Las pruebas de una consulta: una por variante de select que tenga embed, con
 * los filtros embebidos que aplican a esa variante, todos en el mismo request.
 *
 * Una consulta con varias variantes (un ternario que elige el select) puede
 * tener un filtro cuya rama va sólo con una de ellas: el `.or(..., {
 * referencedTable: 'clientes' })` de la búsqueda va sólo con el select que
 * embebe clientes. Leer esa correlación excede a una lectura de texto, así que
 * el filtro se prueba contra cada variante que tiene su embed, se informa en
 * `noAplicados` contra las que no, y si no lo tiene NINGUNA queda en
 * `sinVariante` (ver `huerfanos`, que mira el grupo entero).
 */
export function pruebasDe(consulta) {
  const pruebas = []
  const noAplicados = []
  const embebidos = consulta.filtros.filter(esEmbebido)
  const aplicado = new Set()
  const errores = []
  for (const v of consulta.variantes) {
    let nodos
    try {
      nodos = parsearSelect(v)
    } catch (e) {
      errores.push({ select: v, mensaje: e.message })
      continue
    }
    const aplican = []
    for (const f of embebidos) {
      if (rutasDe(f).every((r) => buscarRuta(nodos, r))) {
        aplican.push(f)
        aplicado.add(f)
      } else noAplicados.push({ filtro: f, select: v })
    }
    if (!tieneEmbed(nodos) && !aplican.length) continue
    const params = []
    const ordenes = []
    for (const f of aplican) {
      for (const [k, val] of parametrosDe(f)) {
        if (k === 'order') ordenes.push(val)
        else if (!params.some(([a, b]) => a === k && b === val)) params.push([k, val])
      }
    }
    if (ordenes.length) params.push(['order', [...new Set(ordenes)].join(',')])
    pruebas.push({ select: v, params, filtros: aplican })
  }
  const sinVariante = embebidos.filter((f) => !aplicado.has(f))
  return { pruebas, noAplicados, sinVariante, errores }
}

/**
 * Filtros embebidos que no aplican a ninguna variante de ninguna consulta de
 * su grupo: en runtime serían PGRST108 ("no es un recurso embebido"). El
 * grupo son las consultas a las que el extractor vio aplicarse el filtro
 * juntas (las ramas de un ternario guardado en una variable), porque el
 * filtro de un helper puede ir sólo con una de ellas.
 */
export function huerfanos(consultas) {
  const aplicados = new Set()
  const candidatos = new Map()
  const clave = (f) => `${f.archivo}:${f.linea}|${f.firma}|${f.grupo}`
  for (const c of consultas) {
    const { sinVariante } = pruebasDe(c)
    for (const f of c.filtros.filter(esEmbebido)) {
      const k = clave(f)
      if (!sinVariante.includes(f)) aplicados.add(k)
      else if (!candidatos.has(k)) candidatos.set(k, { ...f, consulta: `${c.archivo}:${c.linea}`, tabla: c.tabla })
    }
  }
  return [...candidatos].filter(([k]) => !aplicados.has(k)).map(([, f]) => f)
}

/** Query string de una prueba (`select=...&rel.col=is.null&limit=0`). */
export function queryString(prueba) {
  const q = new URLSearchParams()
  q.append('select', prueba.select)
  for (const [k, v] of prueba.params) q.append(k, v)
  q.append('limit', '0')
  return q.toString()
}

/**
 * La tabla destino de un embed: `rel` es nombre de tabla en todo el repo hoy;
 * si no, PostgREST también acepta el nombre de una FK o la columna FK.
 */
export function resolverDestino(nodo, padre, mapa) {
  if (mapa.tablas[nodo.nombre]) return nodo.nombre
  for (const fk of mapa.fks) {
    if (fk.nombre !== nodo.nombre) continue
    if (fk.tabla === padre) return fk.ref_tabla
    if (fk.ref_tabla === padre) return fk.tabla
  }
  for (const fk of mapa.fks) {
    if (fk.tabla === padre && fk.columnas[0] === nodo.nombre) return fk.ref_tabla
  }
  return null
}

function revisarColumna(t, tabla, col, donde, errores) {
  const c = columnaBase(col)
  if (!t.columnas.includes(c)) {
    // `count` pelado (`rel(count)`) es el conteo, no una columna.
    if (c === 'count') {
      if (!t.legibles.length) errores.push({ ...donde, tabla, columna: 'count', motivo: 'count sin ninguna columna legible' })
      return
    }
    // Un campo calculado (`deuda_previa(pedidos)`) se pide como columna, pero lo
    // que authenticated necesita es EXECUTE sobre la función, no SELECT.
    if (Object.hasOwn(t.calculadas ?? {}, c)) {
      if (!t.calculadas[c]) errores.push({ ...donde, tabla, columna: c, motivo: 'authenticated no puede ejecutar este campo calculado' })
      return
    }
    errores.push({ ...donde, tabla, columna: c, motivo: 'no existe en la tabla' })
  } else if (!t.legibles.includes(c)) {
    errores.push({ ...donde, tabla, columna: c, motivo: 'authenticated no la puede leer' })
  }
}

function revisarNodos(nodos, tabla, mapa, donde, errores) {
  const t = mapa.tablas[tabla]
  if (!t) {
    errores.push({ ...donde, tabla, columna: null, motivo: 'la tabla no está en el mapa de lectura (no es de public, o no existe)' })
    return
  }
  for (const n of nodos) {
    if (n.tipo === 'estrella') {
      const faltan = t.columnas.filter((c) => !t.legibles.includes(c))
      if (faltan.length) {
        errores.push({ ...donde, tabla, columna: '*', motivo: `el * incluye columnas que authenticated no puede leer (${faltan.join(', ')})` })
      }
    } else if (n.tipo === 'columna') {
      revisarColumna(t, tabla, n.columna, donde, errores)
    } else if (n.tipo === 'conteo') {
      if (!t.legibles.length) errores.push({ ...donde, tabla, columna: 'count()', motivo: 'count sin ninguna columna legible' })
    } else if (n.tipo === 'embed') {
      const destino = resolverDestino(n, tabla, mapa)
      if (!destino) {
        errores.push({ ...donde, tabla, columna: n.nombre, motivo: `no se puede resolver a qué tabla apunta el embed "${n.nombre}"` })
        continue
      }
      revisarNodos(n.hijos, destino, mapa, donde, errores)
    }
  }
}

/** Tabla sobre la que corre el filtro: la raíz, o la del embed al que apunta. */
function tablaDeRuta(consulta, ruta, mapa) {
  if (!ruta.length) return consulta.tabla
  for (const v of consulta.variantes) {
    let nodos
    try {
      nodos = parsearSelect(v)
    } catch {
      continue
    }
    let tabla = consulta.tabla
    let actuales = nodos
    let ok = true
    for (const seg of ruta) {
      const n = actuales.find((x) => x.tipo === 'embed' && (x.alias === seg || x.nombre === seg))
      const destino = n && resolverDestino(n, tabla, mapa)
      if (!destino) {
        ok = false
        break
      }
      tabla = destino
      actuales = n.hijos
    }
    if (ok) return tabla
  }
  return null
}

/**
 * Lo que `authenticated` no puede leer en las consultas de `src/` (las de
 * `supabase/functions/` corren con service_role). `mapa` tiene la forma que
 * devuelve `auditoria_lectura_authenticated()`:
 * `{ tablas: { t: { columnas, legibles, calculadas: { nombre: ejecuta } } }, fks: [{ nombre, tabla, columnas, ref_tabla, ref_columnas }] }`.
 * `calculadas` (desde la 403): los campos calculados de PostgREST, que se piden
 * como columnas pero necesitan EXECUTE sobre la función, no SELECT.
 *
 * Por qué: el gate corre en CI con la service_role, que se saltea grants y
 * RLS. Un `*` sobre `productos` (que se concede columna por columna, #974)
 * pasa verde ahí y en la app falla la consulta entera, para todos los roles.
 */
export function verificarGrants(consultas, mapa) {
  const errores = []
  for (const c of consultas) {
    if (!c.archivo.startsWith('src/') || !c.tabla) continue
    for (const s of c.selects) {
      for (const v of s.valores ?? []) {
        let nodos
        try {
          nodos = parsearSelect(v)
        } catch {
          continue // lo informa el chequeo de parseo
        }
        revisarNodos(nodos, c.tabla, mapa, { archivo: s.archivo, linea: s.linea }, errores)
      }
    }
    for (const f of c.filtros) {
      if (!f.columnas) continue
      const tabla = tablaDeRuta(c, f.ruta ?? [], mapa)
      const t = tabla && mapa.tablas[tabla]
      if (!t) continue // lo informa la prueba del filtro (huérfano) o el select
      for (const col of f.columnas) {
        if (col.includes('.')) {
          // Columna de otro recurso dentro de un .or() de primer nivel.
          const partes = col.split('.')
          const tt = tablaDeRuta(c, partes.slice(0, -1), mapa)
          if (tt && mapa.tablas[tt]) revisarColumna(mapa.tablas[tt], tt, partes.at(-1), { archivo: f.archivo, linea: f.linea }, errores)
          continue
        }
        revisarColumna(t, tabla, col, { archivo: f.archivo, linea: f.linea }, errores)
      }
    }
  }
  // Una misma constante de select se usa en muchos lugares: un error por lugar.
  const vistos = new Set()
  return errores.filter((e) => {
    const k = `${e.archivo}:${e.linea}|${e.tabla}|${e.columna}|${e.motivo}`
    if (vistos.has(k)) return false
    vistos.add(k)
    return true
  })
}
