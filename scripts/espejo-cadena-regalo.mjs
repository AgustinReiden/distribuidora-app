#!/usr/bin/env node
/**
 * PARIDAD DEL RECORRIDO DE LA CADENA DE SUSTITUCIONES DE REGALO (#1010, #1057), lado SQL.
 *
 * El recorrido está escrito dos veces y tiene que dar lo mismo:
 *
 *   · TypeScript — `pasosDeCadena()`, `raizDeSustitucion()` y `raizDescrita()` en
 *     `src/utils/repartoRegalo.ts`, lo que muestra la pantalla de edición.
 *   · SQL — `regalo_cadena_pasos()`, `regalo_raiz_de_eslabones()` y
 *     `regalo_raiz_descrita()`: los usa `regalo_sustitucion_resuelta()` y por lo
 *     tanto el trigger de pedido_items, o sea lo que se GUARDA.
 *
 * Los dos corren los casos de `src/utils/cadenaSustitucion.espejo.json` contra el
 * mismo resultado, escrito a mano. El TS lo corre vitest
 * (`cadenaSustitucion.espejo.test.ts`); éste corre el SQL y sale con 1 ante
 * cualquier diferencia. Si alguien cambia la regla de un lado sin el otro, uno
 * de los dos se pone rojo.
 *
 * Cada caso trae `cadena` (la clave de la línea de regalo, uuid o null: sin clave no
 * aplica ningún eslabón) y `esperado` (los ids de los eslabones aplicados). Los
 * opcionales `raiz` (número o null) y `raizDescrita` (número) se comparan sólo si
 * el caso los trae.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * las funciones no están expuestas a anon ni a authenticated).
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
const tieneRaiz = (c) => Object.prototype.hasOwnProperty.call(c, 'raiz');
const tieneDescrita = (c) => Object.prototype.hasOwnProperty.call(c, 'raizDescrita');
const cadenaSql = (c) => (c.cadena == null ? 'NULL::uuid' : `${literal(c.cadena)}::uuid`);
const bigintSql = (v) => (v == null ? 'NULL::bigint' : `${Number(v)}::bigint`);

if (process.argv.includes('--sql')) {
  const filas = casos.map((c) =>
    `(${literal(c.caso)}, ${literal(JSON.stringify(c.eslabones))}::jsonb, ${Number(c.producto)}::bigint, ` +
    `${cadenaSql(c)}, ARRAY[${c.esperado.map(Number).join(',')}]::bigint[], ` +
    `${tieneRaiz(c)}, ${bigintSql(c.raiz)}, ${tieneDescrita(c)}, ${bigintSql(c.raizDescrita)})`,
  );
  console.log(
    'WITH r AS (\n' +
    '  SELECT caso, esperado, tiene_raiz, raiz, tiene_descrita, descrita,\n' +
    '         public.regalo_cadena_pasos(eslabones, producto, cadena) AS sql,\n' +
    '         public.regalo_raiz_de_eslabones(eslabones, producto, cadena) AS sql_raiz,\n' +
    '         public.regalo_raiz_descrita(eslabones, producto, cadena) AS sql_descrita\n' +
    `    FROM (VALUES\n      ${filas.join(',\n      ')}\n    ) AS t(caso, eslabones, producto, cadena, esperado, tiene_raiz, raiz, tiene_descrita, descrita)\n` +
    ')\n' +
    'SELECT caso, esperado, sql, raiz, sql_raiz, descrita, sql_descrita,\n' +
    '       (sql IS NOT DISTINCT FROM esperado\n' +
    '        AND (NOT tiene_raiz OR sql_raiz IS NOT DISTINCT FROM raiz)\n' +
    '        AND (NOT tiene_descrita OR sql_descrita IS NOT DISTINCT FROM descrita)) AS ok\n' +
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

// Llama a una función del server con los parámetros del caso. Un gate que no
// puede mirar es rojo, no verde: cualquier falla de HTTP corta con 2.
async function rpc(nombre, c) {
  const res = await fetch(`${base}/rest/v1/rpc/${nombre}`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ p_eslabones: c.eslabones, p_producto_id: c.producto, p_cadena: c.cadena ?? null }),
  });
  if (!res.ok) {
    console.error(`${nombre}() falló en "${c.caso}": HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

// bigint o null del lado SQL -> número o null, para comparar con el fixture.
const numOrNull = (v) => (v == null ? null : Number(v));

const rojos = [];
for (const c of casos) {
  const sql = ((await rpc('regalo_cadena_pasos', c)) ?? []).map(Number);
  const problemas = [];
  const pasosOk = sql.length === c.esperado.length && sql.every((v, i) => v === c.esperado[i]);
  if (!pasosOk) problemas.push({ que: 'pasos', esperado: c.esperado, sql });

  if (tieneRaiz(c)) {
    const sqlRaiz = numOrNull(await rpc('regalo_raiz_de_eslabones', c));
    if (sqlRaiz !== numOrNull(c.raiz)) problemas.push({ que: 'raiz', esperado: numOrNull(c.raiz), sql: sqlRaiz });
  }
  if (tieneDescrita(c)) {
    const sqlDescrita = numOrNull(await rpc('regalo_raiz_descrita', c));
    if (sqlDescrita !== numOrNull(c.raizDescrita)) problemas.push({ que: 'raizDescrita', esperado: numOrNull(c.raizDescrita), sql: sqlDescrita });
  }

  console.log(`${problemas.length === 0 ? '✓' : '✗'} ${c.caso}`);
  if (problemas.length) rojos.push({ caso: c.caso, problemas });
}

if (rojos.length) {
  console.error('\n❌ El recorrido del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}`);
    for (const p of r.problemas) {
      console.error(`    ${p.que}: esperado = ${JSON.stringify(p.esperado)} · SQL = ${JSON.stringify(p.sql)}`);
    }
  }
  process.exit(1);
}
console.log(`\n✅ ${casos.length} casos: el recorrido del SQL coincide con el del TS.`);
