import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * #1135 · Por REST se escribe sólo lo que el front escribe.
 *
 * Desde la migración `*_rest_escribe_solo_lo_que_usa.sql`, `authenticated`
 * tiene INSERT/UPDATE/DELETE sólo sobre la lista de `scripts/grants-rest.json`
 * («escrituras») y `anon` no tiene nada. Un `.insert`/`.update`/`.upsert`/
 * `.delete` de PostgREST sobre una tabla que no está ahí falla en runtime con
 * 42501, y no lo ven ni `tsc` ni eslint ni los tests que mockean supabase. Este
 * test es esa guarda, y la de su contracara: que nadie conceda de más.
 *
 *  1. Toda escritura `.from('t')…insert|update|upsert|delete(` de src/ (sin
 *     tests) está en `escrituras[t]` (cualquier nivel); upsert pide INSERT y
 *     UPDATE.
 *  2. Un `.from(<variable>)` con escritura falla: no se sabe sobre qué tabla.
 *  3. Cada privilegio del JSON tiene un uso: lo escribe el front, o la tabla
 *     está en `por_invoker` (la escribe un trigger INVOKER como authenticated).
 *  4. El JSON es lo que las migraciones conceden: la lista blanca del barrido
 *     más los GRANT de escritura a authenticated de las migraciones
 *     posteriores, menos sus REVOKE. Y lo que el front escribe está concedido.
 *  5. Ninguna migración posterior al barrido concede nada a anon (tampoco por
 *     ALTER DEFAULT PRIVILEGES).
 *  6. (#1151) Las secuencias en las que authenticated tiene USAGE son las de
 *     `secuencias` del JSON: las migraciones posteriores al barrido las dejan
 *     así (`REVOKE ALL ON ALL SEQUENCES` vacía el conjunto, `GRANT USAGE ON
 *     SEQUENCE` lo llena), y ninguna le concede otra cosa que USAGE.
 *
 * Una migración todavía sin número (`XXX_…`) cuenta como posterior a todas:
 * va a recibir el número más alto al aplicarse.
 *
 * El nivel (tabla o columnas) contra prod lo mira scripts/check-grants-tablas.mjs.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')
const RAIZ = path.resolve(SRC, '..')
const MIGRACIONES = path.join(RAIZ, 'migrations')
const SLUG_BARRIDO = '_rest_escribe_solo_lo_que_usa.sql'

type Privilegio = 'INSERT' | 'UPDATE' | 'DELETE'
interface GrantsRest {
  escrituras: Record<string, Partial<Record<Privilegio, 'tabla' | string[]>>>
  por_invoker: Record<string, string>
  secuencias: string[]
}
const GRANTS = JSON.parse(fs.readFileSync(path.join(RAIZ, 'scripts', 'grants-rest.json'), 'utf8')) as GrantsRest

const ESCRITURAS = new Set(['insert', 'update', 'upsert', 'delete'])
const PRIVS_DE: Record<string, Privilegio[]> = {
  insert: ['INSERT'],
  update: ['UPDATE'],
  upsert: ['INSERT', 'UPDATE'],
  delete: ['DELETE'],
}
// `.from(` que no son de supabase-js.
const RECEPTORES_AJENOS = new Set(['Array', 'Buffer', 'storage', 'Object', 'Uint8Array'])

function listarArchivos(dir: string, acc: string[] = []): string[] {
  for (const nombre of fs.readdirSync(dir)) {
    const ruta = path.join(dir, nombre)
    if (fs.statSync(ruta).isDirectory()) {
      if (nombre === 'node_modules' || nombre === '__tests__') continue
      listarArchivos(ruta, acc)
    } else if (/\.(ts|tsx|js|jsx)$/.test(nombre) && !/\.(test|spec)\./.test(nombre)) {
      acc.push(ruta)
    }
  }
  return acc
}

const relativo = (ruta: string) => path.relative(RAIZ, ruta).split(path.sep).join('/')
const linea = (texto: string, idx: number) => texto.slice(0, idx).split('\n').length

/** Índice justo después del paréntesis que cierra el que abre en `abre`. */
function cerrarParentesis(texto: string, abre: number): number {
  let prof = 0
  for (let i = abre; i < texto.length; i++) {
    if (texto[i] === '(') prof++
    else if (texto[i] === ')') {
      prof--
      if (prof === 0) return i + 1
    }
  }
  return texto.length
}

/** Los métodos encadenados a partir de `desde`: `.a(…)\n  .b(…)?.c(…)` → [a, b, c]. */
function cadena(texto: string, desde: number): string[] {
  const metodos: string[] = []
  let i = desde
  for (;;) {
    const m = /^\s*\??\.\s*([A-Za-z_$][\w$]*)\s*/.exec(texto.slice(i, i + 200))
    if (!m) break
    metodos.push(m[1])
    i += m[0].length
    if (texto[i] === '(') i = cerrarParentesis(texto, i)
  }
  return metodos
}

interface Escritura {
  index: number
  tabla: string | null // null: la tabla llega por variable
  metodo: string
}

/** Toda escritura PostgREST de `texto`, con su tabla (o null si llega por variable). */
function escrituras(texto: string): Escritura[] {
  const hallazgos: Escritura[] = []
  for (const m of texto.matchAll(/([A-Za-z_$][\w$]*)?\s*\.from\(/g)) {
    if (m[1] && RECEPTORES_AJENOS.has(m[1])) continue
    const abre = m.index! + m[0].length - 1
    const cierra = cerrarParentesis(texto, abre)
    const argumento = texto.slice(abre + 1, cierra - 1).trim()
    const literal = /^(['"`])([\w]+)\1$/.exec(argumento)
    for (const metodo of cadena(texto, cierra).filter((x) => ESCRITURAS.has(x))) {
      hallazgos.push({ index: m.index!, tabla: literal ? literal[2] : null, metodo })
    }
  }
  return hallazgos
}

/** (tabla.PRIV) que escribe el front, con dónde. */
function escriturasDelFront(): Map<string, string[]> {
  const usos = new Map<string, string[]>()
  for (const archivo of listarArchivos(SRC)) {
    const texto = fs.readFileSync(archivo, 'utf8')
    for (const e of escrituras(texto)) {
      const donde = `${relativo(archivo)}:${linea(texto, e.index)}`
      for (const priv of PRIVS_DE[e.metodo]) {
        const clave = `${e.tabla ?? '<variable>'}.${priv}`
        usos.set(clave, [...(usos.get(clave) ?? []), `${donde} (.${e.metodo})`])
      }
    }
  }
  return usos
}

// ------------------------------------------------------------ migraciones ---

const sinComentarios = (sql: string) => sql.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ')

/** Separa por comas de primer nivel (no las de una lista de columnas). */
function partirPorComas(s: string): string[] {
  const partes: string[] = []
  let prof = 0
  let actual = ''
  for (const ch of s) {
    if (ch === '(') prof++
    if (ch === ')') prof--
    if (ch === ',' && prof === 0) {
      partes.push(actual.trim())
      actual = ''
    } else actual += ch
  }
  if (actual.trim()) partes.push(actual.trim())
  return partes
}

const nombreTabla = (t: string) => t.trim().replace(/"/g, '').replace(/^public\./i, '').toLowerCase()

interface Sentencia {
  tipo: 'GRANT' | 'REVOKE'
  privilegios: string[] // INSERT, UPDATE, DELETE, ALL, SELECT, ...
  objetos: string[] | 'ALL TABLES' | null // null: no es de tablas (función, secuencia, esquema)
  secuencias: string[] | 'ALL SEQUENCES' | null // null: no es de secuencias
  roles: string[]
  porDefecto: boolean
}

/** Los GRANT / REVOKE (también los de ALTER DEFAULT PRIVILEGES) de un SQL. */
function sentenciasDePermisos(sql: string): Sentencia[] {
  const res: Sentencia[] = []
  const limpio = sinComentarios(sql)
  const re = /(ALTER\s+DEFAULT\s+PRIVILEGES[\s\S]*?\s)?\b(GRANT|REVOKE)\s+([\s\S]+?)\s+ON\s+([\s\S]+?)\s+(TO|FROM)\s+([\s\S]+?);/gi
  for (const m of limpio.matchAll(re)) {
    const porDefecto = Boolean(m[1])
    const tipo = m[2].toUpperCase() as 'GRANT' | 'REVOKE'
    const privilegios = partirPorComas(m[3].replace(/^GRANT\s+OPTION\s+FOR\s+/i, ''))
      .map((p) => p.replace(/\(.*\)/s, '').trim().toUpperCase().replace(/\s+PRIVILEGES$/, ''))
    const destino = m[4].trim()
    let objetos: Sentencia['objetos'] = null
    let secuencias: Sentencia['secuencias'] = null
    if (/^SEQUENCE\s+/i.test(destino)) {
      secuencias = partirPorComas(destino.replace(/^SEQUENCE\s+/i, '')).map(nombreTabla)
    } else if (/^ALL\s+SEQUENCES\b/i.test(destino) || (porDefecto && /^SEQUENCES\b/i.test(destino))) {
      secuencias = 'ALL SEQUENCES'
    }
    if (/^(FUNCTION|FUNCTIONS|ROUTINE|ROUTINES|PROCEDURE|SEQUENCE|SEQUENCES|SCHEMA|TYPE|TYPES|DOMAIN|LANGUAGE|DATABASE)\b/i.test(destino)
        || /^ALL\s+(FUNCTIONS|SEQUENCES|ROUTINES|PROCEDURES)\b/i.test(destino)) {
      objetos = null
    } else if (/^ALL\s+TABLES\b/i.test(destino) || (porDefecto && /^TABLES\b/i.test(destino))) {
      objetos = 'ALL TABLES'
    } else {
      objetos = partirPorComas(destino.replace(/^TABLE\s+/i, '')).map(nombreTabla)
    }
    const roles = partirPorComas(m[6].replace(/\s+(CASCADE|RESTRICT|WITH\s+GRANT\s+OPTION)\s*$/i, ''))
      .map((r) => r.trim().replace(/"/g, '').toLowerCase())
    res.push({ tipo, privilegios, objetos, secuencias, roles, porDefecto })
  }
  return res
}

/** Las (tabla, priv) de la lista blanca embebida en la migración del barrido. */
function listaBlancaDelBarrido(sql: string): Set<string> {
  const m = /INSERT\s+INTO\s+_grants_rest_lista\s*\(tabla,\s*priv\)\s*VALUES([\s\S]*?);/i.exec(sinComentarios(sql))
  if (!m) throw new Error('no encontré la lista blanca (_grants_rest_lista) en la migración del barrido')
  return new Set([...m[1].matchAll(/\(\s*'(\w+)'\s*,\s*'(\w+)'\s*\)/g)].map((x) => `${x[1]}.${x[2]}`))
}

const numeroDe = (archivo: string) => {
  const m = /^(\d+)[a-z]?_/.exec(archivo)
  return m ? Number(m[1]) : null
}

function barridoYPosteriores(): { barrido: string; posteriores: string[] } {
  const archivos = fs.readdirSync(MIGRACIONES).filter((a) => a.endsWith('.sql')).sort()
  const barrido = archivos.find((a) => a.endsWith(SLUG_BARRIDO))
  if (!barrido) throw new Error(`no está la migración *${SLUG_BARRIDO}`)
  // Mientras no tiene número (XXX_), no hay posteriores. Una posterior sin
  // número todavía (XXX_) va a recibir el más alto: cuenta (#1151).
  const n = numeroDe(barrido) ?? Infinity
  const posteriores = archivos.filter((a) => a !== barrido && (numeroDe(a) ?? Infinity) > n)
  return { barrido, posteriores }
}

const PRIVS_ESCRITURA: Privilegio[] = ['INSERT', 'UPDATE', 'DELETE']

/** Lo que las migraciones dejan concedido a authenticated (escritura), y los GRANT prohibidos. */
function concedidoPorMigraciones(): { concedido: Set<string>; problemas: string[] } {
  const { barrido, posteriores } = barridoYPosteriores()
  const concedido = listaBlancaDelBarrido(fs.readFileSync(path.join(MIGRACIONES, barrido), 'utf8'))
  const problemas: string[] = []
  for (const archivo of posteriores) {
    for (const s of sentenciasDePermisos(fs.readFileSync(path.join(MIGRACIONES, archivo), 'utf8'))) {
      if (s.tipo === 'GRANT' && s.roles.some((r) => r === 'anon' || r === 'public')) {
        problemas.push(`${archivo}: GRANT ${s.privilegios.join(', ')} a ${s.roles.join(', ')} — anon no recibe nada`)
        continue
      }
      if (s.objetos === null || !s.roles.includes('authenticated')) continue
      const privs = s.privilegios.includes('ALL') ? PRIVS_ESCRITURA : s.privilegios.filter((p): p is Privilegio => PRIVS_ESCRITURA.includes(p as Privilegio))
      if (privs.length === 0) continue
      if (s.objetos === 'ALL TABLES') {
        if (s.tipo === 'GRANT') {
          problemas.push(`${archivo}: GRANT ${privs.join(', ')} ON ALL TABLES${s.porDefecto ? ' (default)' : ''} a authenticated`)
        }
        continue
      }
      for (const t of s.objetos) {
        for (const p of privs) {
          if (s.tipo === 'GRANT') concedido.add(`${t}.${p}`)
          else concedido.delete(`${t}.${p}`)
        }
      }
    }
  }
  return { concedido, problemas }
}

/**
 * #1151 · Las secuencias con USAGE para authenticated que deja una serie de
 * sentencias, partiendo de `inicial` (null: sin barrer, o sea todas, como dejó
 * el baseline). `REVOKE … ON ALL SEQUENCES` vacía el conjunto; `GRANT USAGE ON
 * SEQUENCE a, b` lo llena; un GRANT de otra cosa que USAGE es un problema, y
 * también un GRANT por defecto (una secuencia nueva nace sin nada).
 */
function secuenciasDe(
  sentencias: Sentencia[],
  inicial: Set<string> | null,
  origen = '',
): { secuencias: Set<string> | null; problemas: string[] } {
  let secuencias = inicial === null ? null : new Set(inicial)
  const problemas: string[] = []
  for (const s of sentencias) {
    if (s.secuencias === null || !s.roles.includes('authenticated')) continue
    const todos = s.privilegios.includes('ALL')
    if (s.tipo === 'GRANT') {
      const otros = s.privilegios.filter((p) => p !== 'USAGE')
      if (otros.length > 0) {
        problemas.push(`${origen}GRANT ${otros.join(', ')} sobre secuencias a authenticated — alcanza USAGE`)
      }
      if (s.porDefecto) {
        problemas.push(`${origen}GRANT por defecto sobre secuencias a authenticated — una secuencia nueva nace sin nada`)
        continue
      }
      if (s.secuencias === 'ALL SEQUENCES') {
        problemas.push(`${origen}GRANT ON ALL SEQUENCES a authenticated — se concede USAGE secuencia por secuencia`)
        continue
      }
      if (secuencias !== null && (todos || s.privilegios.includes('USAGE'))) {
        for (const q of s.secuencias) secuencias.add(q)
      }
    } else {
      if (s.porDefecto || !(todos || s.privilegios.includes('USAGE'))) continue
      if (s.secuencias === 'ALL SEQUENCES') secuencias = new Set()
      else if (secuencias !== null) for (const q of s.secuencias) secuencias.delete(q)
    }
  }
  return { secuencias, problemas }
}

function secuenciasPorMigraciones(): { secuencias: Set<string> | null; problemas: string[] } {
  const { posteriores } = barridoYPosteriores()
  let secuencias: Set<string> | null = null
  const problemas: string[] = []
  for (const archivo of posteriores) {
    const sql = fs.readFileSync(path.join(MIGRACIONES, archivo), 'utf8')
    const r = secuenciasDe(sentenciasDePermisos(sql), secuencias, `${archivo}: `)
    secuencias = r.secuencias
    problemas.push(...r.problemas)
  }
  return { secuencias, problemas }
}

const clavesDelJson = () =>
  new Set(Object.entries(GRANTS.escrituras).flatMap(([t, privs]) => Object.keys(privs).map((p) => `${t}.${p}`)))

describe('escrituras REST concedidas (#1135)', () => {
  it('el detector de escrituras muerde: literales, por variable y upsert', () => {
    const casos: Array<[string, Array<Pick<Escritura, 'tabla' | 'metodo'>>]> = [
      ["await supabase.from('pagos').update({ monto: 1 }).eq('id', 1)", [{ tabla: 'pagos', metodo: 'update' }]],
      ["supabase\n  .from('pedido_items')\n  .select('id')\n  .delete()", [{ tabla: 'pedido_items', metodo: 'delete' }]],
      ['supabase.from("marcas").insert([{ nombre: 1 }]).select()', [{ tabla: 'marcas', metodo: 'insert' }]],
      ['supabase.from(`promocion_reglas`).upsert(filas)', [{ tabla: 'promocion_reglas', metodo: 'upsert' }]],
      ['supabase.from(tabla).delete().neq("id", 0)', [{ tabla: null, metodo: 'delete' }]],
      ["supabase.from('pedidos').select('*, cliente:clientes(*)').eq('id', 1)", []],
      ["supabase.from(tabla).select('id', { count: 'exact', head: true })", []],
      ['Array.from(ids).map((x) => x)', []],
      ["supabase.storage.from('fotos').remove([ruta])", []],
    ]
    for (const [codigo, esperado] of casos) {
      expect(escrituras(codigo).map(({ tabla, metodo }) => ({ tabla, metodo })), codigo).toEqual(esperado)
    }
  })

  it('el lector de GRANT / REVOKE de migraciones entiende columnas, ALL, TABLE y default privileges', () => {
    const s = sentenciasDePermisos(`
      -- GRANT INSERT ON public.comentada TO authenticated;
      GRANT UPDATE (leida, leida_at), SELECT ON public.notificaciones TO authenticated;
      GRANT ALL ON TABLE public.x, public.y TO authenticated, anon;
      REVOKE DELETE ON public.pagos FROM authenticated;
      GRANT EXECUTE ON FUNCTION public.f(bigint) TO authenticated;
      ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT INSERT ON TABLES TO authenticated;
    `)
    expect(s.map(({ tipo, privilegios, objetos, roles, porDefecto }) => ({ tipo, privilegios, objetos, roles, porDefecto }))).toEqual([
      { tipo: 'GRANT', privilegios: ['UPDATE', 'SELECT'], objetos: ['notificaciones'], roles: ['authenticated'], porDefecto: false },
      { tipo: 'GRANT', privilegios: ['ALL'], objetos: ['x', 'y'], roles: ['authenticated', 'anon'], porDefecto: false },
      { tipo: 'REVOKE', privilegios: ['DELETE'], objetos: ['pagos'], roles: ['authenticated'], porDefecto: false },
      { tipo: 'GRANT', privilegios: ['EXECUTE'], objetos: null, roles: ['authenticated'], porDefecto: false },
      { tipo: 'GRANT', privilegios: ['INSERT'], objetos: 'ALL TABLES', roles: ['authenticated'], porDefecto: true },
    ])
  })

  it('toda escritura REST del front está concedida en scripts/grants-rest.json', () => {
    const json = clavesDelJson()
    const faltan = [...escriturasDelFront()]
      .filter(([clave]) => !clave.startsWith('<variable>.') && !json.has(clave))
      .map(([clave, donde]) => `${clave} ← ${donde.join(', ')}`)
    expect(faltan, 'concedé el privilegio exacto en una migración y sumalo a scripts/grants-rest.json').toEqual([])
  })

  it('ninguna escritura REST del front llega con la tabla por variable', () => {
    const porVariable = [...escriturasDelFront()]
      .filter(([clave]) => clave.startsWith('<variable>.'))
      .flatMap(([, donde]) => donde)
    expect(porVariable, 'usá la tabla como literal: si no, este contrato no puede saber qué concede').toEqual([])
  })

  it('cada escritura del JSON la usa el front o un trigger INVOKER (por_invoker)', () => {
    const front = escriturasDelFront()
    const sinUso = [...clavesDelJson()].filter((clave) => {
      const tabla = clave.split('.')[0]
      return !front.has(clave) && !(tabla in GRANTS.por_invoker)
    })
    expect(sinUso, 'un privilegio que nadie usa se revoca (y se saca del JSON)').toEqual([])
    for (const tabla of Object.keys(GRANTS.por_invoker)) {
      expect(GRANTS.escrituras[tabla], `por_invoker.${tabla} sin escrituras`).toBeDefined()
    }
  })

  it('el JSON es lo que conceden las migraciones (barrido + GRANT/REVOKE posteriores), y nada a anon', () => {
    const { concedido, problemas } = concedidoPorMigraciones()
    expect(problemas, 'migraciones posteriores al barrido que conceden de más').toEqual([])
    expect([...clavesDelJson()].sort(), 'scripts/grants-rest.json ≠ lo que dejan concedido las migraciones').toEqual(
      [...concedido].sort(),
    )
    const faltan = [...escriturasDelFront().keys()].filter((c) => !c.startsWith('<variable>.') && !concedido.has(c))
    expect(faltan, 'el front escribe algo que ninguna migración le concede a authenticated').toEqual([])
  })

  it('el lector de secuencias entiende ON SEQUENCE, ALL SEQUENCES y default privileges, y muerde (#1151)', () => {
    const barrido = sentenciasDePermisos(`
      REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM authenticated;
      GRANT USAGE ON SEQUENCE public.a_id_seq, public.b_id_seq TO authenticated;
      ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM authenticated;
      GRANT EXECUTE ON FUNCTION public.f() TO service_role;
    `)
    expect(barrido.map((s) => s.secuencias)).toEqual(['ALL SEQUENCES', ['a_id_seq', 'b_id_seq'], 'ALL SEQUENCES', null])
    const base = secuenciasDe(barrido, null)
    expect(base.problemas).toEqual([])
    expect([...(base.secuencias ?? [])].sort()).toEqual(['a_id_seq', 'b_id_seq'])

    // Una migración posterior que concede una secuencia fuera del JSON, o algo
    // que no es USAGE, cambia el conjunto o es un problema.
    const despues = secuenciasDe(
      sentenciasDePermisos(`
        GRANT USAGE ON SEQUENCE public.c_id_seq TO authenticated;
        GRANT UPDATE ON SEQUENCE public.a_id_seq TO authenticated;
        REVOKE USAGE ON SEQUENCE public.b_id_seq FROM authenticated;
        ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT USAGE ON SEQUENCES TO authenticated;
      `),
      base.secuencias,
    )
    expect([...(despues.secuencias ?? [])].sort()).toEqual(['a_id_seq', 'c_id_seq'])
    expect(despues.problemas).toHaveLength(2)

    // Sin un REVOKE ON ALL SEQUENCES no hay barrido: el conjunto queda abierto.
    const sinBarrido = secuenciasDe(sentenciasDePermisos('GRANT USAGE ON SEQUENCE public.a_id_seq TO authenticated;'), null)
    expect(sinBarrido.secuencias).toBeNull()
  })

  it('las secuencias con USAGE para authenticated son las de scripts/grants-rest.json (#1151)', () => {
    const { secuencias, problemas } = secuenciasPorMigraciones()
    expect(problemas, 'migraciones posteriores al barrido que conceden de más sobre secuencias').toEqual([])
    expect(secuencias, 'ninguna migración barre las secuencias de authenticated (REVOKE ALL ON ALL SEQUENCES)').not.toBeNull()
    expect([...(secuencias ?? [])].sort(), 'scripts/grants-rest.json («secuencias») ≠ lo que dejan las migraciones').toEqual(
      [...GRANTS.secuencias].sort(),
    )
  })
})
