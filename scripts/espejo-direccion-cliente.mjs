#!/usr/bin/env node
/**
 * PARIDAD DE LA DIRECCIÓN DEL DUPLICADO DE CLIENTE (1596-b7, #1596), lado SQL.
 *
 * La clave (calle y altura) y la unidad dentro de la puerta están escritas dos veces y
 * tienen que dar lo mismo:
 *
 *   · TypeScript — `claveDireccionConAltura`, `unidadDireccion` y
 *     `otraUnidadMismaPuerta` en `src/utils/duplicadoCliente.ts`.
 *   · SQL — `clave_direccion_cliente`, `unidad_direccion_cliente` y
 *     `_otra_unidad_misma_puerta`, con las que `verificar_duplicado_cliente` decide.
 *
 * Los dos corren los casos de `src/utils/direccionCliente.espejo.json` contra el mismo
 * resultado, escrito a mano. El TS lo corre vitest (`duplicadoCliente.test.ts`); éste
 * corre el SQL y sale con 1 ante cualquier diferencia.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role: las dos
 * funciones nuevas no están expuestas a anon ni a authenticated).
 *
 *   node scripts/espejo-direccion-cliente.mjs          # compara y falla si difiere
 *   node scripts/espejo-direccion-cliente.mjs --sql    # imprime UNA consulta que hace
 *                                                      # la misma comparación en Postgres
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'direccionCliente.espejo.json');
const { casos, pares } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const texto = (s) => (s == null ? 'NULL::text' : `'${String(s).replace(/'/g, "''")}'`);

if (process.argv.includes('--sql')) {
  const filasCasos = casos.map((c) => `(${texto(c.direccion)}, ${texto(c.clave)}, ${texto(c.unidad)})`);
  const filasPares = pares.map((p) => `(${texto(p.a)}, ${texto(p.b)}, ${p.chocan ? 'true' : 'false'})`);
  console.log(
    'SELECT \'caso\' AS que, d AS entrada, (public.clave_direccion_cliente(d) IS NOT DISTINCT FROM clave\n' +
    '        AND public.unidad_direccion_cliente(d) IS NOT DISTINCT FROM unidad) AS ok\n' +
    `  FROM (VALUES\n    ${filasCasos.join(',\n    ')}\n  ) AS t(d, clave, unidad)\n` +
    'UNION ALL\n' +
    'SELECT \'par\', a || \' | \' || b,\n' +
    '       (public.clave_direccion_cliente(a) IS NOT NULL\n' +
    '        AND public.clave_direccion_cliente(a) = public.clave_direccion_cliente(b)\n' +
    '        AND NOT public._otra_unidad_misma_puerta(a, b)) = chocan\n' +
    '       AND public._otra_unidad_misma_puerta(a, b) = public._otra_unidad_misma_puerta(b, a)\n' +
    `  FROM (VALUES\n    ${filasPares.join(',\n    ')}\n  ) AS p(a, b, chocan);`,
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
async function rpc(fn, body) {
  const res = await fetch(`${base}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!res.ok) {
    console.error(`${fn}() falló: HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

const rojos = [];
for (const c of casos) {
  const clave = await rpc('clave_direccion_cliente', { p_direccion: c.direccion });
  const unidad = await rpc('unidad_direccion_cliente', { p_direccion: c.direccion });
  const ok = clave === c.clave && unidad === c.unidad;
  console.log(`${ok ? '✓' : '✗'} ${c.direccion}`);
  if (!ok) rojos.push(`${c.direccion}: esperado ${c.clave} / ${c.unidad} · SQL ${clave} / ${unidad}`);
}
for (const p of pares) {
  const ca = await rpc('clave_direccion_cliente', { p_direccion: p.a });
  const cb = await rpc('clave_direccion_cliente', { p_direccion: p.b });
  const otra = await rpc('_otra_unidad_misma_puerta', { p_a: p.a, p_b: p.b });
  const chocan = ca != null && ca === cb && !otra;
  const ok = chocan === p.chocan;
  console.log(`${ok ? '✓' : '✗'} ${p.a} | ${p.b}`);
  if (!ok) rojos.push(`${p.a} | ${p.b}: esperado chocan=${p.chocan} · SQL ${chocan}`);
}

if (rojos.length) {
  console.error('\n❌ La dirección del duplicado del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) console.error(`  ${r}`);
  process.exit(1);
}
console.log(`\n✅ ${casos.length} direcciones y ${pares.length} pares: el SQL coincide con el TS.`);
