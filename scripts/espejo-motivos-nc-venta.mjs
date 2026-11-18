#!/usr/bin/env node
/**
 * PARIDAD DE LOS MOTIVOS DE UNA NOTA DE CRÉDITO DE VENTA (B16 v3 de #1603), lado SQL.
 *
 * El server tiene una sola lista, `nc_venta_motivos()` (la usan el CHECK de
 * `notas_credito_venta`, la RPC que la crea y lo que decide qué le descuenta al
 * vendedor). El front la espeja en `src/constants/motivosNCVenta.espejo.json`; el TS
 * lo vigila `motivosNCVenta.espejo.test.ts` (vitest) y este script la compara contra
 * la base. Sale con 1 si difiere, y con 2 si no pudo mirar.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon).
 *
 *   node scripts/espejo-motivos-nc-venta.mjs          # compara y falla si difiere
 *   node scripts/espejo-motivos-nc-venta.mjs --sql    # imprime UNA consulta que devuelve
 *                                                     # las diferencias, para correrla a mano
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'constants', 'motivosNCVenta.espejo.json');
const { motivos } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;
const tupla = 'motivo, descuenta_vendedor, descuenta_unidades, mercaderia';

if (process.argv.includes('--sql')) {
  const valores = motivos
    .map((m) => `(${literal(m.motivo)}::text, ${m.descuenta_vendedor}, ${m.descuenta_unidades}, ${literal(m.mercaderia)}::text)`)
    .join(',\n    ');
  console.log(
    `WITH espejo(${tupla}) AS (VALUES\n` +
    `    ${valores}\n  )\n` +
    `SELECT 'solo en nc_venta_motivos()' AS lado, s.* FROM public.nc_venta_motivos() s\n` +
    `  WHERE NOT EXISTS (SELECT 1 FROM espejo e WHERE (e.${tupla.replace(/, /g, ', e.')}) = (s.${tupla.replace(/, /g, ', s.')}))\n` +
    'UNION ALL\n' +
    `SELECT 'solo en el espejo', e.* FROM espejo e\n` +
    `  WHERE NOT EXISTS (SELECT 1 FROM public.nc_venta_motivos() s WHERE (e.${tupla.replace(/, /g, ', e.')}) = (s.${tupla.replace(/, /g, ', s.')}));`,
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

// Un gate que no puede mirar es rojo, no verde: cualquier falla de HTTP, o un
// fetch que tira (DNS, red), corta con 2.
let res;
try {
  res = await fetch(`${base}/rest/v1/rpc/nc_venta_motivos`, { method: 'POST', headers, body: '{}' });
} catch (e) {
  console.error(`nc_venta_motivos() no respondió: ${e?.message ?? e}`);
  process.exit(2);
}
if (!res.ok) {
  console.error(`nc_venta_motivos() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}
let sql;
try {
  sql = await res.json();
} catch (e) {
  console.error(`nc_venta_motivos() devolvió algo que no es JSON: ${e?.message ?? e}`);
  process.exit(2);
}
if (!Array.isArray(sql)) {
  console.error(`nc_venta_motivos() devolvió algo que no es una lista: ${JSON.stringify(sql)}`);
  process.exit(2);
}

const clave = (m) => `${m.motivo}|${m.descuenta_vendedor}|${m.descuenta_unidades}|${m.mercaderia}`;
const enSql = new Map(sql.map((m) => [clave(m), m]));
const enEspejo = new Map(motivos.map((m) => [clave(m), m]));
const desc = (m) =>
  `${m.motivo} (descuenta_vendedor=${m.descuenta_vendedor}, descuenta_unidades=${m.descuenta_unidades}, mercaderia=${m.mercaderia})`;

for (const m of motivos) console.log(`${enSql.has(clave(m)) ? '✓' : '✗'} ${desc(m)}`);

const faltan = motivos.filter((m) => !enSql.has(clave(m)));
const sobran = sql.filter((m) => !enEspejo.has(clave(m)));
if (faltan.length || sobran.length) {
  console.error('\n❌ nc_venta_motivos() no coincide con src/constants/motivosNCVenta.espejo.json:');
  for (const m of faltan) console.error(`  en el espejo y no en nc_venta_motivos(): ${desc(m)}`);
  for (const m of sobran) console.error(`  en nc_venta_motivos() y no en el espejo: ${desc(m)}`);
  process.exit(1);
}
console.log(`\n✅ ${motivos.length} motivos: nc_venta_motivos() coincide con el espejo.`);
