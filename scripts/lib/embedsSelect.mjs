/**
 * Extrae de un fuente TypeScript los `.select(...)` de supabase-js que llevan
 * un embed (`tabla:otra!hint(cols)`), junto con la tabla sobre la que corren.
 *
 * Lo usa `scripts/check-embeds.mjs` (#1008): un `select` es un string, y ni
 * `tsc`, ni eslint, ni los tests —que mockean supabase— ven que PostgREST no
 * pueda resolver la relación. Eso rompió "Armar ruta" (PGRST201) y la pantalla
 * de Salvedades (PGRST200, hints por nombre de columna contra FKs compuestas).
 *
 * Es lectura de texto, no un parser de TypeScript: cubre los tres modos en que
 * este repo escribe un select —literal, template con `${CONSTANTE}` y una
 * constante pasada por nombre— y lo que no entiende lo devuelve en `omitidos`
 * para que el gate lo muestre en vez de ignorarlo en silencio.
 */

const IDENT = /[A-Za-z_$][\w$]*/y

/** Lee un literal ('..', "..", `..`) que empieza en `i`; `resolver` rinde cada `${expr}`. */
function leerLiteral(src, i, resolver) {
  const q = src[i]
  let out = ''
  let j = i + 1
  while (j < src.length) {
    const c = src[j]
    if (c === '\\') {
      out += src[j + 1] ?? ''
      j += 2
      continue
    }
    if (c === q) return { valor: out, fin: j + 1 }
    if (q === '`' && c === '$' && src[j + 1] === '{') {
      let prof = 1
      let k = j + 2
      while (k < src.length && prof > 0) {
        if (src[k] === '{') prof++
        else if (src[k] === '}') prof--
        k++
      }
      out += resolver(src.slice(j + 2, k - 1).trim())
      j = k
      continue
    }
    out += c
    j++
  }
  return null
}

/**
 * Constantes de string de un fuente: `const NOMBRE = 'literal'` o con template,
 * con o sin `as const` / `export`. Las que arman el string con `join`,
 * concatenación u otra cosa no entran: se resuelven como "columnas cualquiera".
 */
export function constantesDe(src) {
  const mapa = new Map()
  const re = /(?:^|\n)\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*(?::\s*[^=\n]+)?=\s*(?=['"`])/g
  let m
  while ((m = re.exec(src))) {
    const inicio = m.index + m[0].length
    const lit = leerLiteral(src, inicio, () => '\u0000')
    if (!lit) continue
    // Sólo cuenta si el literal es TODA la expresión (`as const`, `;` o fin de línea).
    const resto = src.slice(lit.fin, lit.fin + 40)
    if (!/^\s*(as const)?\s*(;|\n|$)/.test(resto)) continue
    mapa.set(m[1], src.slice(inicio, lit.fin))
  }
  return mapa
}

/** Devuelve el valor de una constante (con sus `${}` resueltos) o null. */
function resolverConstante(nombre, constantes, prof = 0) {
  const crudo = constantes.get(nombre)
  if (crudo == null || prof > 5) return null
  const lit = leerLiteral(crudo, 0, (expr) => {
    const r = /^[A-Za-z_$][\w$]*$/.test(expr) ? resolverConstante(expr, constantes, prof + 1) : null
    return r ?? 'id'
  })
  return lit ? lit.valor : null
}


/**
 * @param {string} src contenido del archivo
 * @param {Map<string,string>} constantes constantes de string de todo el repo
 * @returns {{ encontrados: {tabla:string, select:string, linea:number}[], omitidos: {motivo:string, linea:number}[] }}
 */
export function extraerSelects(src, constantes) {
  const encontrados = []
  const omitidos = []
  const re = /\.select\(\s*/g
  let m
  while ((m = re.exec(src))) {
    const linea = src.slice(0, m.index).split('\n').length
    const i = m.index + m[0].length
    let selects = []
    if (/['"`]/.test(src[i] ?? '')) {
      const lit = leerLiteral(src, i, (expr) => resolverExpr(expr, constantes))
      if (lit) selects = [lit.valor]
    } else {
      IDENT.lastIndex = i
      const id = IDENT.exec(src)
      if (id && /^\s*[,)]/.test(src.slice(IDENT.lastIndex, IDENT.lastIndex + 10))) {
        selects = candidatos(src, id[0], m.index, constantes)
        if (!selects.length) {
          omitidos.push({ motivo: `select(${id[0]}): constante no resuelta`, linea })
          continue
        }
      }
    }
    // supabase-js saca TODOS los espacios del select antes de mandarlo; PostgREST
    // no tolera `( id` ni `peso) )`, así que se prueba lo que realmente viaja.
    // Sin `(` no hay embed ni relación que resolver (también cubre `.select()` pelado).
    selects = selects.map((s) => s.replace(/\s+/g, '')).filter((s) => s.includes('('))
    if (!selects.length) continue

    // Tabla: el último `.from('x')` antes del select, sin cruzar de sentencia.
    const ventana = src.slice(Math.max(0, m.index - 900), m.index)
    const froms = [...ventana.matchAll(/\.from\(\s*(?:'([^']+)'|"([^"]+)"|`([^`]+)`)\s*\)/g)]
    const ultimo = froms[froms.length - 1]
    if (!ultimo) {
      omitidos.push({ motivo: 'sin .from("tabla") literal cerca', linea })
      continue
    }
    const despues = ventana.slice(ultimo.index + ultimo[0].length)
    if (/;\s*\n/.test(despues)) {
      omitidos.push({ motivo: 'sin .from("tabla") literal en la misma sentencia', linea })
      continue
    }
    for (const select of selects) {
      encontrados.push({ tabla: ultimo[1] ?? ultimo[2] ?? ultimo[3], select, linea })
    }
  }
  return { encontrados, omitidos }
}

/** `${expr}` dentro de un template: la constante si la conocemos, si no una columna cualquiera. */
function resolverExpr(expr, constantes) {
  const r = /^[A-Za-z_$][\w$]*$/.test(expr) ? resolverConstante(expr, constantes) : null
  return r ?? 'id'
}

/**
 * Valores posibles de `select(ID)`: la constante global, o —si ID es una local
 * como `const selectStr = hayBusqueda ? A : B`— cada literal o constante de la
 * expresión (las dos ramas del ternario).
 */
function candidatos(src, id, hasta, constantes) {
  const directa = resolverConstante(id, constantes)
  if (directa != null) return [directa]
  const escapado = id.replace(/\$/g, '\\$')
  const decl = [...src.slice(0, hasta).matchAll(new RegExp(`(?:const|let)\\s+${escapado}\\s*(?::[^=]+)?=\\s*`, 'g'))].pop()
  if (!decl) return []
  const ini = decl.index + decl[0].length
  const fin = src.slice(ini).search(/;|\n\s*\n|\n\s*(?:const|let|return|if)\b/)
  const expr = src.slice(ini, fin === -1 ? ini + 600 : ini + fin)
  const out = []
  let j = 0
  while (j < expr.length) {
    if (/['"`]/.test(expr[j])) {
      const lit = leerLiteral(expr, j, (e) => resolverExpr(e, constantes))
      if (!lit) break
      out.push(lit.valor)
      j = lit.fin
      continue
    }
    IDENT.lastIndex = j
    const t = IDENT.exec(expr)
    if (t) {
      const r = expr[j - 1] === '.' ? null : resolverConstante(t[0], constantes)
      if (r != null) out.push(r)
      j = IDENT.lastIndex
      continue
    }
    j++
  }
  return out
}
