#!/usr/bin/env node
/**
 * Gate de embeds de PostgREST (#1008, #1256).
 *
 * Extrae de `src/` y `supabase/functions/` cada consulta de supabase-js (la
 * cadena que arranca en `.from(tabla)`, sus continuaciones por variable y los
 * helpers que la filtran) y la prueba contra prod con `limit=0`:
 *
 *  1. Cada select con embed, con los filtros y órdenes sobre recursos
 *     embebidos en el MISMO request (`rel.col=is.null`, `rel.or=(...)`,
 *     `rel.order=col`, `order=rel(col)`). Falla (exit 1) si PostgREST no puede
 *     resolver: PGRST200 (no hay FK que matchee el hint), PGRST201 (dos FKs
 *     posibles), PGRST108 (el filtro apunta a algo que no está embebido),
 *     42703 (columna que no existe, o un `order=rel(col)` con `col` fuera del
 *     select del embed), etc.
 *  2. Lo que el extractor no pudo atribuir o resolver también falla: un
 *     omitido es un punto ciego, no un aviso. Las excepciones revisadas a mano
 *     viven en `LISTA_BLANCA` (scripts/lib/embedsRepo.mjs), con su motivo.
 *  3. Con la service_role, lee de `auditoria_lectura_authenticated()` qué
 *     columnas puede leer `authenticated` y exige que toda consulta de `src/`
 *     pida sólo esas (un `*` sólo si las puede leer todas).
 *
 * Por qué existe: el `select` es un string que no ven `tsc`, eslint ni los
 * tests (mockean supabase). Las FKs de aislamiento por sucursal son
 * COMPUESTAS, así que un hint por nombre de columna no las encuentra. Tumbó la
 * pantalla de Salvedades; antes, "Armar ruta".
 *
 * Un `42501` (permission denied) cuenta como resuelto: Postgres chequea
 * permisos al EJECUTAR, después de que PostgREST resolvió relaciones y
 * columnas, así que con la anon key casi todo contesta eso y la relación igual
 * quedó probada. Justamente por eso la parte 3 es aparte: CI corre con la
 * service_role, que se saltea grants y RLS, y un embed a algo que
 * `authenticated` no puede leer (la trampa `productos(*)`, #974) pasaba verde.
 *
 * Env: SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY (integridad.yml), o
 * SUPABASE_ANON_KEY para correr sin la parte 3. El paso de los PRs (ci.yml)
 * sólo tiene la anon key: declara EMBEDS_GRANTS=omitir, y los grants los
 * verifica integridad.yml con la service_role.
 * Salida: 0 todo bien; 1 alguna falla; 2 sin fallas pero los grants no se
 * verificaron (sin service_role y sin declararlo, o la RPC no está): no se
 * saltea en silencio.
 * Uso local:  SUPABASE_URL=... SUPABASE_ANON_KEY=... node scripts/check-embeds.mjs
 */
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { analizarRepo } from './lib/embedsSelect.mjs'
import { aplicarListaBlanca, leerFuentes } from './lib/embedsRepo.mjs'
import { esEmbebido, huerfanos, pruebasDe, queryString, verificarGrants } from './lib/embedsPostgrest.mjs'

const raiz = join(fileURLToPath(new URL('.', import.meta.url)), '..')
const url = process.env.SUPABASE_URL
const servicio = process.env.SUPABASE_SERVICE_ROLE_KEY
const key = servicio || process.env.SUPABASE_ANON_KEY
// Sólo vale sin service_role: con ella, una RPC que no responde sigue siendo rojo.
const omitirGrants = !servicio && process.env.EMBEDS_GRANTS === 'omitir'

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (o SUPABASE_ANON_KEY) en el entorno.')
  process.exit(2)
}
const base = url.replace(/\/$/, '')
const headers = { apikey: key, Authorization: `Bearer ${key}` }

const fuentes = leerFuentes(raiz)
const { consultas, omitidos } = analizarRepo(fuentes)
const { vigentes, sinUso } = aplicarListaBlanca(omitidos)
const fallas = []

// ── 1. Omitidos ──
for (const o of vigentes) fallas.push(`No se pudo leer ${o.archivo}:${o.linea} — ${o.motivo}`)
for (const e of sinUso) fallas.push(`Lista blanca sin uso (la consulta cambió: revisala): ${e.archivo} ${e.firma}`)

// ── 2. Pruebas contra PostgREST ──
const casos = new Map() // tabla?query -> { tabla, prueba, donde }
const noAplicados = []
for (const c of consultas) {
  const r = pruebasDe(c)
  for (const e of r.errores) fallas.push(`Select que no parsea en ${c.archivo}:${c.linea} — ${e.mensaje}\n    select: ${e.select}`)
  for (const n of r.noAplicados) noAplicados.push(`${n.filtro.firma} (${n.filtro.archivo}:${n.filtro.linea}) no va con la variante de ${c.archivo}:${c.linea} sin ese embed`)
  for (const p of r.pruebas) {
    const qs = queryString(p)
    const clave = `${c.tabla}?${qs}`
    if (!casos.has(clave)) casos.set(clave, { tabla: c.tabla, prueba: p, qs, donde: new Set() })
    const caso = casos.get(clave)
    for (const s of c.selects) if (s.valores?.includes(p.select)) caso.donde.add(`${s.archivo}:${s.linea}`)
    for (const f of p.filtros) caso.donde.add(`${f.archivo}:${f.linea}`)
  }
}
for (const h of huerfanos(consultas)) {
  fallas.push(`Filtro sobre "${h.ruta.join('.')}", que ninguna variante del select de ${h.consulta} (${h.tabla}) embebe: ${h.firma} en ${h.archivo}:${h.linea}`)
}

let sinPermiso = 0
let errores = 0
for (const caso of casos.values()) {
  const res = await fetch(`${base}/rest/v1/${caso.tabla}?${caso.qs}`, { headers })
  if (res.ok) continue
  let codigo = ''
  let mensaje = ''
  try {
    const j = await res.json()
    codigo = j.code ?? ''
    mensaje = j.message ?? ''
  } catch {
    mensaje = await res.text().catch(() => '')
  }
  if (codigo === '42501') {
    sinPermiso++
    continue
  }
  errores++
  const filtros = caso.prueba.params.map(([k, v]) => `${k}=${v}`).join('&')
  fallas.push(
    `${caso.tabla} → HTTP ${res.status} ${codigo} ${mensaje}\n    select: ${caso.prueba.select}`
    + (filtros ? `\n    filtros: ${filtros}` : '')
    + [...caso.donde].map((d) => `\n    en ${d}`).join(''),
  )
}

// ── 3. Grants de authenticated ──
let grantsVerificados = false
let avisoGrants = ''
if (!servicio) {
  avisoGrants = 'sin SUPABASE_SERVICE_ROLE_KEY (con la anon key no se puede leer el mapa de privilegios)'
} else {
  const res = await fetch(`${base}/rest/v1/rpc/auditoria_lectura_authenticated`, {
    method: 'POST',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: '{}',
  })
  const cuerpo = await res.json().catch(() => null)
  if (!res.ok || !cuerpo?.tablas || !Array.isArray(cuerpo.fks)) {
    avisoGrants = `la RPC auditoria_lectura_authenticated() no respondió (HTTP ${res.status} ${cuerpo?.code ?? ''} ${cuerpo?.message ?? ''})`.trim()
  } else {
    grantsVerificados = true
    for (const e of verificarGrants(consultas, cuerpo)) {
      fallas.push(`Grants: ${e.tabla}${e.columna ? `.${e.columna}` : ''} — ${e.motivo} — ${e.archivo}:${e.linea}`)
    }
  }
}

// ── Salida ──
const embebidos = consultas.flatMap((c) => c.filtros.filter(esEmbebido).map((f) => ({ c, f })))
console.log(`Embeds de PostgREST: ${consultas.length} consultas en ${fuentes.length} archivos; ${casos.size} pruebas distintas con embed.`)
console.log(`Filtros y órdenes sobre embeds: ${embebidos.length}.`)
for (const { c, f } of embebidos) {
  // Un filtro que no es de la cadena propia (variable o helper) dice a qué consulta se aplicó.
  const deOtro = f.archivo !== c.archivo || f.grupo !== c.id ? ` (consulta en ${c.archivo}:${c.linea})` : ''
  console.log(`  ${c.tabla} · ${f.ruta.join('.') || '(or)'} · ${f.firma.slice(0, 70)} — ${f.archivo}:${f.linea}${deOtro}`)
}
if (noAplicados.length) {
  console.log(`\nFiltros que no van con alguna variante del select (se prueban con las que sí los tienen): ${noAplicados.length}`)
  for (const n of noAplicados) console.log(`  ${n}`)
}
if (fallas.length) {
  console.log(`\n✗ ${fallas.length} falla(s):`)
  for (const f of fallas) console.log(`\n✗ ${f}`)
}
console.log(`\n${casos.size - errores} pruebas bien (${sinPermiso} con permission denied: relación resuelta), ${errores} con error.`)
if (grantsVerificados) console.log('Grants de authenticated: verificados.')
else if (omitirGrants) console.log('Grants de authenticated: no se miran en este paso (EMBEDS_GRANTS=omitir); los verifica integridad.yml con la service_role.')
else console.log(`Grants de authenticated: NO VERIFICADOS — ${avisoGrants}.`)
process.exit(fallas.length ? 1 : grantsVerificados || omitirGrants ? 0 : 2)
