#!/usr/bin/env node
/**
 * PARIDAD DEL TOPE DEL SUSTITUTO DE UN REGALO (#1592, PRM-1), lado SQL.
 *
 * La regla del dueño (16/11) está escrita dos veces y tiene que dar lo mismo:
 *
 *   · TypeScript — `topeSustitutoRegalo()` en `src/utils/regaloOtroEmpaque.ts`, lo
 *     que la pantalla de cambio de regalo sugiere y deja confirmar.
 *   · SQL — `regalo_tope_sustituto()`, con la que `sustituir_regalo_pedido` y
 *     `actualizar_pedido_items` topean a quien no es admin.
 *
 * Los dos corren los casos de `src/utils/topeSustituto.espejo.json` contra el mismo
 * resultado, escrito a mano. El TS lo corre vitest (`topeSustituto.espejo.test.ts`);
 * éste corre el SQL y sale con 1 ante cualquier diferencia.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon: la
 * función no está expuesta a anon ni a authenticated).
 *
 *   node scripts/espejo-tope-sustituto.mjs          # compara y falla si difiere
 *   node scripts/espejo-tope-sustituto.mjs --sql    # imprime UNA consulta que hace la
 *                                                   # misma comparación en Postgres
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'topeSustituto.espejo.json');
const { casos } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;
const numericSql = (v) => (v == null ? 'NULL::numeric' : `${Number(v)}::numeric`);

if (process.argv.includes('--sql')) {
  const filas = casos.map((c) =>
    `(${literal(c.caso)}, ${numericSql(c.corte)}, ${numericSql(c.precio_regalo)}, ${numericSql(c.factor_regalo)}, ` +
    `${numericSql(c.precio_sustituto)}, ${numericSql(c.factor_sustituto)}, ${c.mismo_rubro ? 'true' : 'false'}, ${Number(c.esperado)})`,
  );
  console.log(
    'WITH r AS (\n' +
    '  SELECT caso, esperado, public.regalo_tope_sustituto(corte, pr, fr, ps, fs, mr) AS sql\n' +
    `    FROM (VALUES\n      ${filas.join(',\n      ')}\n    ) AS t(caso, corte, pr, fr, ps, fs, mr, esperado)\n` +
    ')\n' +
    'SELECT caso, esperado, sql, sql = esperado AS ok\n' +
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
  const res = await fetch(`${base}/rest/v1/rpc/regalo_tope_sustituto`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      p_corte: c.corte,
      p_precio_regalo: c.precio_regalo,
      p_factor_regalo: c.factor_regalo,
      p_precio_sustituto: c.precio_sustituto,
      p_factor_sustituto: c.factor_sustituto,
      p_mismo_rubro: c.mismo_rubro,
    }),
  });
  if (!res.ok) {
    console.error(`regalo_tope_sustituto() falló en "${c.caso}": HTTP ${res.status}\n${await res.text()}`);
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
  console.error('\n❌ El tope del sustituto del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}: esperado = ${r.esperado} · SQL = ${r.sql}`);
  }
  process.exit(1);
}
console.log(`\n✅ ${casos.length} casos: el tope del sustituto del SQL coincide con el del TS.`);
