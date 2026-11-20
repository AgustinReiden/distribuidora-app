import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { PERFIL_COLUMNAS } from './perfilColumnas'

/**
 * 1601-b5 (#1601, decisión del dueño D53): los emails de los demás usuarios los leen sólo
 * admin y encargado. El cierre es un `REVOKE SELECT` de `perfiles.email` para
 * `authenticated`, y con la tabla concedida columna por columna un `*` o un `email` en el
 * `select` de perfiles hace fallar la consulta ENTERA, para todos los roles (también el
 * login, que lee el perfil propio). Ni `tsc` ni eslint ni los tests que mockean supabase lo
 * ven: este test es esa guarda, en `src/` y en `supabase/functions/`.
 *
 * Desde la migración de cierres de la tarjeta C6 no queda ninguna lectura de `email` por REST:
 * el de otro usuario sale de `emails_de_usuarios()`.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')
const RAIZ = path.resolve(SRC, '..')
const FUNCIONES = path.join(RAIZ, 'supabase', 'functions')

function listarArchivos(dir: string, acc: string[] = []): string[] {
  if (!fs.existsSync(dir)) return acc
  for (const nombre of fs.readdirSync(dir)) {
    const ruta = path.join(dir, nombre)
    if (fs.statSync(ruta).isDirectory()) {
      if (nombre === 'node_modules' || nombre === '__tests__' || nombre === 'tests') continue
      listarArchivos(ruta, acc)
    } else if (/\.(ts|tsx|js|jsx)$/.test(nombre) && !/\.(test|spec)\./.test(nombre)) {
      acc.push(ruta)
    }
  }
  return acc
}

const relativo = (ruta: string) => path.relative(RAIZ, ruta).split(path.sep).join('/')
const linea = (texto: string, idx: number) => texto.slice(0, idx).split('\n').length

/** Las columnas de un embed de perfiles, balanceando paréntesis. */
function* embedsDePerfiles(texto: string): Generator<{ index: number; columnas: string }> {
  for (const m of texto.matchAll(/perfiles(?:!\w+)?\s*\(/g)) {
    let prof = 1
    let i = m.index! + m[0].length
    for (; i < texto.length && prof > 0; i++) {
      if (texto[i] === '(') prof++
      else if (texto[i] === ')') prof--
    }
    yield { index: m.index!, columnas: texto.slice(m.index! + m[0].length, i - 1) }
  }
}

function lecturasConEmail(archivos: Record<string, string>): string[] {
  const hallazgos: string[] = []
  for (const [archivo, texto] of Object.entries(archivos)) {
    for (const m of texto.matchAll(/\.from\(\s*['"`]perfiles['"`]\s*\)/g)) {
      const desde = m.index! + m[0].length
      const siguiente = texto.indexOf('.from(', desde)
      const tramo = texto.slice(desde, siguiente === -1 ? undefined : siguiente)
      const sel = tramo.match(/\.select\(\s*(\)|['"`]([^'"`]*)['"`])/)
      if (!sel) continue
      const columnas = sel[2] ?? '*'
      if (sel[1] === ')' || /(^|,)\s*\*\s*(,|$)/.test(columnas)) {
        hallazgos.push(`${archivo}:${linea(texto, desde + sel.index!)} · select * sobre perfiles`)
      } else if (/\bemail\b/.test(columnas)) {
        hallazgos.push(`${archivo}:${linea(texto, desde + sel.index!)} · select de perfiles con email`)
      }
    }
    for (const e of embedsDePerfiles(texto)) {
      if (/(^|,)\s*\*\s*(,|$)/.test(e.columnas) || /\bemail\b/.test(e.columnas)) {
        hallazgos.push(`${archivo}:${linea(texto, e.index)} · embed de perfiles con * o email`)
      }
    }
  }
  return hallazgos
}

function archivosDelRepo(): Record<string, string> {
  const todos = [...listarArchivos(SRC), ...listarArchivos(FUNCIONES)]
  return Object.fromEntries(todos.map(r => [relativo(r), fs.readFileSync(r, 'utf8')]))
}

describe('perfiles: lecturas por REST sin el email (1601-b5, D53)', () => {
  it('ninguna consulta del front ni de las funciones pide `*` ni `email` sobre perfiles', () => {
    expect(lecturasConEmail(archivosDelRepo())).toEqual([])
  })

  it('el detector ve las formas que rompen', () => {
    expect(lecturasConEmail({
      'a.ts': `supabase.from('perfiles').select('*').eq('id', x)`,
      'b.ts': `supabase.from('perfiles').select('id, nombre, email').in('id', ids)`,
      'c.ts': `supabase.from('perfiles').update(u).eq('id', id).select().single()`,
      'd.ts': `supabase.from('pagos').select('*, usuario:perfiles(id, email)')`,
      'e.ts': `supabase.from('pagos').select('*, usuario:perfiles!pagos_usuario_id_fkey(*)')`,
    })).toHaveLength(5)
    expect(lecturasConEmail({
      'f.ts': `supabase.from('perfiles').select(PERFIL_COLUMNAS).eq('id', x)`,
      'g.ts': `supabase.from('perfiles').select('id, nombre').in('id', ids)`,
      'h.ts': `supabase.from('pagos').select('*, usuario:perfiles(id, nombre)')`,
    })).toEqual([])
  })

  it('PERFIL_COLUMNAS es exactamente lo que la migración le concede a authenticated', () => {
    // El último `GRANT SELECT (...) ON public.perfiles TO authenticated` de migrations/ (hoy, la
    // migración de cierres de la tarjeta C6). Una columna nueva de perfiles que se conceda en una
    // migración nueva va también acá (y al revés).
    const dir = path.join(RAIZ, 'migrations')
    const RE_GRANT = /GRANT SELECT \(([^)]*)\)\s+ON public\.perfiles TO authenticated/g
    const grants = fs.readdirSync(dir)
      .filter(n => n.endsWith('.sql'))
      .sort()
      .flatMap(n => [...fs.readFileSync(path.join(dir, n), 'utf8').matchAll(RE_GRANT)].map(m => m[1]))
    expect(grants.length).toBeGreaterThan(0)
    const concedidas = grants[grants.length - 1].split(',').map(c => c.trim()).sort()
    expect(PERFIL_COLUMNAS.split(',').map(c => c.trim()).sort()).toEqual(concedidas)
  })

  it('PERFIL_COLUMNAS no incluye el email ni repite columnas', () => {
    const columnas = PERFIL_COLUMNAS.split(',').map(c => c.trim())
    expect(columnas).not.toContain('email')
    expect(columnas).not.toContain('*')
    expect(new Set(columnas).size).toBe(columnas.length)
    for (const c of ['id', 'nombre', 'rol', 'activo']) expect(columnas).toContain(c)
  })
})
