#!/usr/bin/env node
/**
 * PARIDAD DE LAS FORMAS DE PAGO (#1249), lado SQL.
 *
 * El server tiene una sola lista de formas de pago, `formas_pago()` (la usan el
 * CHECK de `pagos` y las RPCs que registran o cambian un pago). El front la
 * espeja en `src/constants/formasPago.espejo.json`; el TS lo vigila
 * `formasPago.espejo.test.ts` (vitest) y este script la compara contra prod.
 * Sale con 1 si difiere, y con 2 si no pudo mirar.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon).
 *
 *   node scripts/espejo-formas-pago.mjs          # compara y falla si difiere
 *   node scripts/espejo-formas-pago.mjs --sql    # imprime UNA consulta que devuelve
 *                                                # las diferencias, para correrla a mano
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'constants', 'formasPago.espejo.json');
const { formas } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;

if (process.argv.includes('--sql')) {
  const valores = formas
    .map((f) => `(${literal(f.forma)}::text, ${f.se_registra}, ${f.dineraria})`)
    .join(',\n    ');
  console.log(
    'WITH espejo(forma, se_registra, dineraria) AS (VALUES\n' +
    `    ${valores}\n  )\n` +
    "SELECT 'solo en formas_pago()' AS lado, s.forma, s.se_registra, s.dineraria\n" +
    '  FROM public.formas_pago() s\n' +
    '  WHERE NOT EXISTS (SELECT 1 FROM espejo e WHERE (e.forma, e.se_registra, e.dineraria) = (s.forma, s.se_registra, s.dineraria))\n' +
    'UNION ALL\n' +
    "SELECT 'solo en el espejo', e.forma, e.se_registra, e.dineraria\n" +
    '  FROM espejo e\n' +
    '  WHERE NOT EXISTS (SELECT 1 FROM public.formas_pago() s WHERE (e.forma, e.se_registra, e.dineraria) = (s.forma, s.se_registra, s.dineraria));',
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
  res = await fetch(`${base}/rest/v1/rpc/formas_pago`, { method: 'POST', headers, body: '{}' });
} catch (e) {
  console.error(`formas_pago() no respondió: ${e?.message ?? e}`);
  process.exit(2);
}
if (!res.ok) {
  console.error(`formas_pago() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}
let sql;
try {
  sql = await res.json();
} catch (e) {
  console.error(`formas_pago() devolvió algo que no es JSON: ${e?.message ?? e}`);
  process.exit(2);
}
if (!Array.isArray(sql)) {
  console.error(`formas_pago() devolvió algo que no es una lista: ${JSON.stringify(sql)}`);
  process.exit(2);
}

const clave = (f) => `${f.forma}|${f.se_registra}|${f.dineraria}`;
const enSql = new Map(sql.map((f) => [clave(f), f]));
const enEspejo = new Map(formas.map((f) => [clave(f), f]));
const desc = (f) => `${f.forma} (se_registra=${f.se_registra}, dineraria=${f.dineraria})`;

for (const f of formas) console.log(`${enSql.has(clave(f)) ? '✓' : '✗'} ${desc(f)}`);

const faltan = formas.filter((f) => !enSql.has(clave(f)));
const sobran = sql.filter((f) => !enEspejo.has(clave(f)));
if (faltan.length || sobran.length) {
  console.error('\n❌ formas_pago() no coincide con src/constants/formasPago.espejo.json:');
  for (const f of faltan) console.error(`  en el espejo y no en formas_pago(): ${desc(f)}`);
  for (const f of sobran) console.error(`  en formas_pago() y no en el espejo: ${desc(f)}`);
  process.exit(1);
}
console.log(`\n✅ ${formas.length} formas: formas_pago() coincide con el espejo.`);
