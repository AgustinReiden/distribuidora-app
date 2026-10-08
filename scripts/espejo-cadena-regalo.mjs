#!/usr/bin/env node
/**
 * PARIDAD DEL RECORRIDO DE LA CADENA DE SUSTITUCIONES DE REGALO (#1010), lado SQL.
 *
 * El recorrido está escrito dos veces y tiene que dar lo mismo:
 *
 *   · TypeScript — `pasosDeCadena()` en `src/utils/repartoRegalo.ts`, lo que
 *     muestra la pantalla de edición.
 *   · SQL — `regalo_cadena_pasos()`, el que usa `regalo_sustitucion_resuelta()`
 *     y por lo tanto el trigger de pedido_items: lo que se GUARDA.
 *
 * Los dos corren los casos de `src/utils/cadenaSustitucion.espejo.json` contra el
 * mismo `esperado`, escrito a mano. El TS lo corre vitest
 * (`cadenaSustitucion.espejo.test.ts`); éste corre el SQL y sale con 1 ante
 * cualquier diferencia. Si alguien cambia la regla de un lado sin el otro, uno
 * de los dos se pone rojo.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * la función no está expuesta a anon ni a authenticated).
 *
 *   node scripts/espejo-cadena-regalo.mjs          # compara y falla si difiere
 *   node scripts/espejo-cadena-regalo.mjs --sql    # imprime UNA consulta que hace
 *                                                  # la misma comparación adentro
 *                                                  # de Postgres, para correrla a
 *                                                  # mano sin credenciales de servicio
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'cadenaSustitucion.espejo.json');
const { casos } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;

if (process.argv.includes('--sql')) {
  const filas = casos.map((c) =>
    `(${literal(c.caso)}, ${literal(JSON.stringify(c.eslabones))}::jsonb, ${Number(c.producto)}::bigint, ` +
    `ARRAY[${c.esperado.map(Number).join(',')}]::bigint[])`,
  );
  console.log(
    'SELECT caso, esperado, public.regalo_cadena_pasos(eslabones, producto) AS sql,\n' +
    '       public.regalo_cadena_pasos(eslabones, producto) IS NOT DISTINCT FROM esperado AS ok\n' +
    `  FROM (VALUES\n    ${filas.join(',\n    ')}\n  ) AS t(caso, eslabones, producto, esperado);`,
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

const rojos = [];
for (const c of casos) {
  const res = await fetch(`${base}/rest/v1/rpc/regalo_cadena_pasos`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ p_eslabones: c.eslabones, p_producto_id: c.producto }),
  });
  if (!res.ok) {
    // Un gate que no puede mirar es rojo, no verde.
    console.error(`regalo_cadena_pasos() falló en "${c.caso}": HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  const sql = ((await res.json()) ?? []).map(Number);
  const ok = sql.length === c.esperado.length && sql.every((v, i) => v === c.esperado[i]);
  console.log(`${ok ? '✓' : '✗'} ${c.caso}`);
  if (!ok) rojos.push({ caso: c.caso, esperado: c.esperado, sql });
}

if (rojos.length) {
  console.error('\n❌ El recorrido del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}\n    esperado = ${JSON.stringify(r.esperado)}\n    SQL      = ${JSON.stringify(r.sql)}`);
  }
  process.exit(1);
}
console.log(`\n✅ ${casos.length} casos: el recorrido del SQL coincide con el del TS.`);
