#!/usr/bin/env node
/**
 * Gate de embeds de PostgREST (#1008).
 *
 * Extrae de `src/` y `supabase/functions/` cada `.select(...)` de supabase-js
 * que lleva un embed y lo prueba contra prod con `limit=0`. Falla (exit 1) si
 * PostgREST no puede resolver la relación: PGRST200 (no hay FK que matchee el
 * hint), PGRST201 (dos FKs posibles) u otro error de planificación.
 *
 * Por qué existe: el `select` es un string que no ven `tsc`, eslint ni los
 * tests (mockean supabase). Las FKs de aislamiento por sucursal son
 * COMPUESTAS —`(producto_id, sucursal_id)`—, así que un hint por nombre de
 * columna (`productos!producto_id`) no las encuentra, y `migrations/000_baseline.sql`
 * todavía las muestra simples. Tumbó la pantalla de Salvedades; antes, "Armar ruta".
 *
 * Un `42501` (permission denied) cuenta como bien: Postgres chequea permisos al
 * EJECUTAR, después de que PostgREST resolvió las relaciones, así que con la anon
 * key la mayoría de las tablas contestan eso y la relación igual quedó probada.
 *
 * Requiere env: SUPABASE_URL y SUPABASE_ANON_KEY (o, en CI, SUPABASE_SERVICE_ROLE_KEY,
 * que resuelve las mismas relaciones). La anon key es pública: viaja en el bundle.
 * Uso local:  SUPABASE_URL=... SUPABASE_ANON_KEY=... node scripts/check-embeds.mjs
 */
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { constantesDe, extraerSelects } from './lib/embedsSelect.mjs'

const raiz = join(fileURLToPath(new URL('.', import.meta.url)), '..')
const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_ANON_KEY (o SUPABASE_SERVICE_ROLE_KEY) en el entorno.')
  process.exit(2)
}

const IGNORAR_DIR = new Set(['node_modules', '__tests__', 'tests', 'test', '.git', 'dist'])

function archivos(dir) {
  const salida = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (!IGNORAR_DIR.has(e.name)) salida.push(...archivos(join(dir, e.name)))
    } else if (/\.(ts|tsx)$/.test(e.name) && !/\.(test|spec)\./.test(e.name) && !e.name.endsWith('.d.ts')) {
      salida.push(join(dir, e.name))
    }
  }
  return salida
}

const lista = [join(raiz, 'src'), join(raiz, 'supabase', 'functions')].flatMap(archivos)
const fuentes = lista.map((f) => [relative(raiz, f).split(sep).join('/'), readFileSync(f, 'utf8')])

// Constantes de string de TODO el repo: un select suele armarse con una importada.
const constantes = new Map()
for (const [, src] of fuentes) for (const [k, v] of constantesDe(src)) constantes.set(k, v)

// tabla|select -> ubicaciones
const casos = new Map()
const omitidos = []
for (const [archivo, src] of fuentes) {
  const r = extraerSelects(src, constantes)
  for (const e of r.encontrados) {
    const clave = `${e.tabla}|${e.select}`
    if (!casos.has(clave)) casos.set(clave, { tabla: e.tabla, select: e.select, donde: [] })
    casos.get(clave).donde.push(`${archivo}:${e.linea}`)
  }
  for (const o of r.omitidos) omitidos.push(`${archivo}:${o.linea} — ${o.motivo}`)
}

const base = url.replace(/\/$/, '')
let fallas = 0
let sinPermiso = 0
const filas = []
for (const { tabla, select, donde } of casos.values()) {
  const res = await fetch(`${base}/rest/v1/${tabla}?select=${encodeURIComponent(select)}&limit=0`, {
    headers: { apikey: key, Authorization: `Bearer ${key}` },
  })
  let codigo = ''
  let mensaje = ''
  if (!res.ok) {
    try {
      const j = await res.json()
      codigo = j.code ?? ''
      mensaje = j.message ?? ''
    } catch {
      mensaje = await res.text().catch(() => '')
    }
  }
  const permiso = !res.ok && codigo === '42501'
  const ok = res.ok || permiso
  if (permiso) sinPermiso++
  if (!ok) fallas++
  filas.push({ ok, tabla, select, donde, estado: res.status, codigo, mensaje })
}

console.log(`Embeds de PostgREST: ${casos.size} selects distintos con embed en ${fuentes.length} archivos.`)
for (const f of filas.filter((x) => !x.ok)) {
  console.log(`\n✗ ${f.tabla}  → HTTP ${f.estado} ${f.codigo} ${f.mensaje}`)
  console.log(`    select: ${f.select}`)
  for (const d of f.donde) console.log(`    en ${d}`)
}
if (omitidos.length) {
  console.log(`\nNo se pudieron probar (${omitidos.length}):`)
  for (const o of omitidos) console.log(`  ${o}`)
}
console.log(`\n${filas.length - fallas} bien (${sinPermiso} con permission denied: relación resuelta), ${fallas} con error.`)
process.exit(fallas ? 1 : 0)
