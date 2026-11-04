#!/usr/bin/env node
/**
 * Gate de funciones de fila sobre tablas con SELECT por columna (#1417).
 *
 * Falla (exit 1) ante toda función de public con un único argumento del tipo
 * fila de una tabla que authenticated lee columna por columna (hoy pedido_items
 * y productos). PostgREST la expone como columna (un campo calculado) y le pasa
 * la fila entera; pasarla exige SELECT sobre todas las columnas, y la consulta
 * que la pida da 42501 para todos los roles. Así cayó la lista de Pedidos con
 * `regalo_mueve_stock_foto(pedido_items)` el 03/11 (#1416). La 218 hizo lo
 * mismo con `deuda_previa_detalle(pedidos)` y no falló porque authenticated lee
 * todas las columnas de pedidos: por eso el gate mira la tabla, no la función.
 *
 * Un dato derivado de una tabla así va por RPC o por columna real (CLAUDE.md).
 * El mapa sale de `auditoria_lectura_authenticated()`, el mismo que usa
 * check-embeds.mjs.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Salida: 0 ninguna; 1 alguna; 2 no se pudo mirar.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-funciones-fila.mjs
 */
import { funcionesDeFilaPorColumna } from './lib/embedsPostgrest.mjs'

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.')
  process.exit(2)
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_lectura_authenticated`, {
  method: 'POST',
  headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  body: '{}',
})
const mapa = await res.json().catch(() => null)
if (!res.ok || !mapa?.tablas) {
  console.error(`La RPC auditoria_lectura_authenticated() no respondió (HTTP ${res.status} ${mapa?.code ?? ''} ${mapa?.message ?? ''}).`)
  process.exit(2)
}

const porColumna = Object.entries(mapa.tablas)
  .filter(([, t]) => t.legibles.length && t.legibles.length < t.columnas.length)
  .map(([tabla]) => tabla)
  .sort()
console.log(`Tablas con SELECT por columna para authenticated: ${porColumna.join(', ') || '(ninguna)'}.`)

const hallazgos = funcionesDeFilaPorColumna(mapa)
if (!hallazgos.length) {
  console.log('Ninguna función de un argumento del tipo fila de esas tablas.')
  process.exit(0)
}

console.error(`\n✗ ${hallazgos.length} función(es) de fila sobre una tabla con SELECT por columna:`)
for (const h of hallazgos) {
  console.error(
    `\n✗ ${h.funcion}(${h.tabla})${h.ejecutable ? ' — authenticated la ejecuta' : ''}\n`
    + `    PostgREST la expone como columna y le pasa la fila entera, que authenticated no puede leer (faltan: ${h.faltan.join(', ')}).\n`
    + '    Un dato derivado va por RPC o por columna real; si es de server, que no reciba la fila.',
  )
}
process.exit(1)
