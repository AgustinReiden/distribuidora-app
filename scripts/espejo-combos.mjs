#!/usr/bin/env node
/**
 * PARIDAD DE LOS COMBOS (#1191), lado SQL.
 *
 * El front arma los combos (`src/utils/combos.ts`) y el server los valida en
 * `combo_fuera_de_regla` recalculando tres puras: `_combo_total`,
 * `_combo_prorrateo` y `_combo_cantidad`. Tienen que dar lo mismo que
 * `totalDelCombo`, `prorratearTotal` y `cantidadDeCombos` al centavo: si no, el
 * server rechaza pedidos honestos.
 *
 * Los dos corren los casos de `src/utils/combos.espejo.json`. El TS lo corre
 * vitest (`combos.espejo.test.ts`); éste corre el SQL y sale con 1 si algo no
 * es exactamente `esperado`.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * las funciones no están expuestas a anon ni a authenticated).
 *
 *   node scripts/espejo-combos.mjs          # compara y falla si difiere
 *   node scripts/espejo-combos.mjs --sql    # imprime UNA consulta que hace la
 *                                           # misma comparación adentro de
 *                                           # Postgres, para correrla a mano
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'combos.espejo.json');
const { prorrateo, total, cantidad } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;
const json = (v) => `${literal(JSON.stringify(v))}::jsonb`;

if (process.argv.includes('--sql')) {
  const filas = [
    ...prorrateo.map((c) =>
      `(${literal('prorrateo: ' + c.caso)}, public._combo_prorrateo(${Number(c.total)}::numeric, ${json(c.lineas)}), ${c.esperado == null ? "'null'::jsonb" : json(c.esperado)})`),
    ...total.map((c) =>
      `(${literal('total: ' + c.caso)}, to_jsonb(public._combo_total(${Number(c.precio)}::numeric, ${Number(c.k)}, ${json(c.lineas)})), ${json(c.esperado)})`),
    ...cantidad.map((c) =>
      `(${literal('cantidad: ' + c.caso)}, to_jsonb(public._combo_cantidad(${json(c.componentes)}, ${json(c.lineas)})), ${c.esperado == null ? "'null'::jsonb" : json(c.esperado)})`),
  ];
  console.log(
    'SELECT caso, sql, esperado, COALESCE(sql, \'null\'::jsonb) = esperado AS ok\n' +
    `  FROM (VALUES\n    ${filas.join(',\n    ')}\n  ) AS t(caso, sql, esperado);`,
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
async function rpc(nombre, cuerpo, caso) {
  const res = await fetch(`${base}/rest/v1/rpc/${nombre}`, { method: 'POST', headers, body: JSON.stringify(cuerpo) });
  if (!res.ok) {
    console.error(`${nombre}() falló en "${caso}": HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

// Los numeric llegan como número de JSON: se comparan por valor.
const igualMapa = (a, b) =>
  a != null && b != null
  && Object.keys(a).length === Object.keys(b).length
  && Object.keys(b).every((k) => Number(a[k]) === Number(b[k]));

const rojos = [];
const anotar = (caso, ok, sql, esperado) => {
  console.log(`${ok ? '✓' : '✗'} ${caso}`);
  if (!ok) rojos.push({ caso, sql, esperado });
};

for (const c of prorrateo) {
  const sql = await rpc('_combo_prorrateo', { p_total: c.total, p_lineas: c.lineas }, c.caso);
  // esperado null: el total no se puede repartir exacto y el SQL devuelve NULL.
  const ok = c.esperado == null ? sql == null : igualMapa(sql, c.esperado);
  anotar(`prorrateo: ${c.caso}`, ok, sql, c.esperado);
}
for (const c of total) {
  const sql = await rpc('_combo_total', { p_precio: c.precio, p_k: c.k, p_lineas: c.lineas }, c.caso);
  anotar(`total: ${c.caso}`, sql != null && Number(sql) === Number(c.esperado), sql, c.esperado);
}
for (const c of cantidad) {
  const sql = await rpc('_combo_cantidad', { p_componentes: c.componentes, p_lineas: c.lineas }, c.caso);
  const ok = c.esperado == null ? sql == null : Number(sql) === Number(c.esperado);
  anotar(`cantidad: ${c.caso}`, ok, sql, c.esperado);
}

if (rojos.length) {
  console.error('\n❌ Las puras de combos del SQL no coinciden con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}: esperado = ${JSON.stringify(r.esperado)} · SQL = ${JSON.stringify(r.sql)}`);
  }
  process.exit(1);
}
const n = prorrateo.length + total.length + cantidad.length;
console.log(`\n✅ ${n} casos: las puras de combos del SQL coinciden con el fixture.`);
