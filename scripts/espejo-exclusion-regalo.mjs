#!/usr/bin/env node
/**
 * PARIDAD DE LA EXCLUSIÓN ENTRE PROMOS EXCLUYENTES (#1136), lado SQL.
 *
 * La exclusión está escrita dos veces y tiene que dar lo mismo:
 *
 *   · TypeScript — `resolverPromociones()` en `src/utils/promociones.ts`, que
 *     regala una sola promo por grupo de excluyentes que comparten productos del
 *     pedido (el usuario puede quitar promos a mano).
 *   · SQL — `regalo_excluyentes_en_conflicto()`, con la que
 *     `regalo_fuera_de_promo` rechaza el regalo de dos excluyentes que comparten
 *     el producto de una línea de venta.
 *
 * Los dos corren los casos de `src/utils/exclusionRegalo.espejo.json` contra el
 * mismo `conflicto`, escrito a mano. El TS lo corre vitest
 * (`exclusionRegalo.espejo.test.ts`); éste corre el SQL y sale con 1 ante
 * cualquier diferencia. Al SQL se le pasan los `items` completos (con los
 * regalos, que tiene que ignorar) y sólo las promos de `regalan`.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * la función no está expuesta a anon ni a authenticated).
 *
 *   node scripts/espejo-exclusion-regalo.mjs          # compara y falla si difiere
 *   node scripts/espejo-exclusion-regalo.mjs --sql    # imprime UNA consulta que
 *                                                     # hace la misma comparación
 *                                                     # adentro de Postgres, para
 *                                                     # correrla a mano sin
 *                                                     # credenciales de servicio
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'exclusionRegalo.espejo.json');
const { casos } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

// Lo que regalo_fuera_de_promo le arma a la función: las promos con regalo.
const promosDe = (c) =>
  c.promos
    .filter((p) => c.regalan.includes(p.id))
    .map((p) => ({ id: p.id, excluyente: p.modo === 'excluyente', productos: p.productos }));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;
const jsonbSql = (v) => (v == null ? 'NULL::jsonb' : `${literal(JSON.stringify(v))}::jsonb`);

if (process.argv.includes('--sql')) {
  const filas = casos.map((c) =>
    `(${literal(c.caso)}, ${jsonbSql(c.items)}, ${jsonbSql(promosDe(c))}, ${jsonbSql(c.conflicto)})`,
  );
  console.log(
    'WITH r AS (\n' +
    '  SELECT caso, esperado, public.regalo_excluyentes_en_conflicto(items, promos) AS sql\n' +
    `    FROM (VALUES\n      ${filas.join(',\n      ')}\n    ) AS t(caso, items, promos, esperado)\n` +
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
async function conflicto(c) {
  const res = await fetch(`${base}/rest/v1/rpc/regalo_excluyentes_en_conflicto`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ p_items: c.items, p_promos: promosDe(c) }),
  });
  if (!res.ok) {
    console.error(`regalo_excluyentes_en_conflicto() falló en "${c.caso}": HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

const mismo = (a, b) => JSON.stringify(a == null ? null : a.map(Number)) === JSON.stringify(b == null ? null : b.map(Number));

const rojos = [];
for (const c of casos) {
  const sql = await conflicto(c);
  const ok = mismo(sql, c.conflicto);
  console.log(`${ok ? '✓' : '✗'} ${c.caso}`);
  if (!ok) rojos.push({ caso: c.caso, esperado: c.conflicto, sql });
}

if (rojos.length) {
  console.error('\n❌ La exclusión del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}: esperado = ${JSON.stringify(r.esperado)} · SQL = ${JSON.stringify(r.sql)}`);
  }
  process.exit(1);
}
console.log(`\n✅ ${casos.length} casos: la exclusión del SQL coincide con la del TS.`);
