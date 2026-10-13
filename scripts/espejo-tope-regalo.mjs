#!/usr/bin/env node
/**
 * PARIDAD DEL TOPE DE REGALO DE UNA PROMO (#1123), lado SQL.
 *
 * La fórmula del regalo de una promo está escrita dos veces y tiene que dar lo
 * mismo:
 *
 *   · TypeScript — `resolverPromociones()` en `src/utils/promociones.ts`, lo que
 *     el front le regala al pedido.
 *   · SQL — `regalo_tope_promo()`, con la que `crear_pedido_completo` y
 *     `actualizar_pedido_items` (vía `regalo_fuera_de_promo`) limitan el regalo
 *     de quien no es admin.
 *
 * Los dos corren los casos de `src/utils/topeRegalo.espejo.json` contra el mismo
 * resultado, escrito a mano. El TS lo corre vitest (`topeRegalo.espejo.test.ts`);
 * éste corre el SQL y sale con 1 ante cualquier diferencia.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * la función no está expuesta a anon ni a authenticated).
 *
 *   node scripts/espejo-tope-regalo.mjs          # compara y falla si difiere
 *   node scripts/espejo-tope-regalo.mjs --sql    # imprime UNA consulta que hace
 *                                                # la misma comparación adentro
 *                                                # de Postgres, para correrla a
 *                                                # mano sin credenciales de servicio
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'topeRegalo.espejo.json');
const { casos } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;
const numericSql = (v) => (v == null ? 'NULL::numeric' : `${Number(v)}::numeric`);

if (process.argv.includes('--sql')) {
  const filas = casos.map((c) =>
    `(${literal(c.caso)}, ${literal(JSON.stringify(c.items))}::jsonb, ${literal(JSON.stringify(c.productos))}::jsonb, ` +
    `${numericSql(c.compra)}, ${numericSql(c.bonif)}, ${Number(c.esperado)})`,
  );
  console.log(
    'WITH r AS (\n' +
    '  SELECT caso, esperado, public.regalo_tope_promo(items, productos, compra, bonif) AS sql\n' +
    `    FROM (VALUES\n      ${filas.join(',\n      ')}\n    ) AS t(caso, items, productos, compra, bonif, esperado)\n` +
    ')\n' +
    'SELECT caso, esperado, sql, sql IS NOT DISTINCT FROM esperado AS ok\n' +
    '  FROM r;',
  );
  process.exit(0);
}

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}
const base = url.replace(/\/$/, '');
const headers = { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' };

// Un gate que no puede mirar es rojo, no verde: cualquier falla de HTTP corta con 2.
async function tope(c) {
  const res = await fetch(`${base}/rest/v1/rpc/regalo_tope_promo`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      p_items: c.items,
      p_productos: c.productos,
      p_compra: c.compra ?? null,
      p_bonif: c.bonif ?? null,
    }),
  });
  if (!res.ok) {
    console.error(`regalo_tope_promo() falló en "${c.caso}": HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

const rojos = [];
for (const c of casos) {
  const sql = Number(await tope(c));
  const ok = sql === Number(c.esperado);
  console.log(`${ok ? '✓' : '✗'} ${c.caso}`);
  if (!ok) rojos.push({ caso: c.caso, esperado: c.esperado, sql });
}

if (rojos.length) {
  console.error('\n❌ El tope del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}: esperado = ${r.esperado} · SQL = ${r.sql}`);
  }
  process.exit(1);
}
console.log(`\n✅ ${casos.length} casos: el tope del SQL coincide con el del TS.`);
