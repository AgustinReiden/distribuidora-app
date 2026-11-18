#!/usr/bin/env node
/**
 * PARIDAD DEL REPARTO DE UN DESCUENTO COMERCIAL (B22 de #1603, H2 de la revisión), lado SQL.
 *
 * El reparto de un descuento sobre toda la boleta está escrito dos veces y tiene que dar lo mismo,
 * al centavo:
 *
 *   · SQL — `_nc_venta_repartir(monto, restos)`, el que usa `crear_nota_credito_venta_impl`.
 *   · TypeScript — `repartirDescuentoNC()` en `src/utils/notaCreditoVenta.ts`, lo que el modal
 *     muestra antes de emitir.
 *
 * Los dos corren los casos de `src/utils/repartoDescuentoNC.espejo.json`. El TS lo corre vitest
 * (`repartoDescuentoNC.espejo.test.ts`); éste corre el SQL y sale con 1 ante cualquier diferencia,
 * y con 2 si no pudo mirar. Un caso con `partes: null` es uno que el server rechaza (22023).
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon: la función es
 * sólo de server).
 *
 *   node scripts/espejo-reparto-descuento-nc.mjs          # compara y falla si difiere
 *   node scripts/espejo-reparto-descuento-nc.mjs --sql    # imprime UNA consulta con la misma
 *                                                         # comparación (sin el caso que se rechaza)
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'repartoDescuentoNC.espejo.json');
const { casos } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;
// Las partes como texto canónico: id:centavos, por id.
const canon = (partes) =>
  Object.entries(partes ?? {})
    .map(([id, m]) => [BigInt(id), Math.round(Number(m) * 100)])
    .filter(([, c]) => c !== 0)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([id, c]) => `${id}:${c}`)
    .join(',');

if (process.argv.includes('--sql')) {
  const filas = casos
    .filter((c) => c.partes != null)
    .map((c) => `(${literal(c.caso)}, ${Number(c.monto)}::numeric, ${literal(JSON.stringify(c.restos))}::jsonb, ${literal(canon(c.partes))})`);
  console.log(
    'SELECT t.caso, t.esperado, s.sql, s.sql IS NOT DISTINCT FROM t.esperado AS ok\n' +
    `  FROM (VALUES\n      ${filas.join(',\n      ')}\n    ) AS t(caso, monto, restos, esperado)\n` +
    '  CROSS JOIN LATERAL (\n' +
    "    SELECT COALESCE(string_agg(r.item_id || ':' || round(r.monto * 100)::bigint, ',' ORDER BY r.item_id), '') AS sql\n" +
    '      FROM public._nc_venta_repartir(t.monto, t.restos) r\n' +
    '  ) s;',
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

// Un gate que no puede mirar es rojo, no verde: una falla de red o de HTTP que no sea el rechazo
// esperado corta con 2.
async function repartir(c) {
  let res;
  try {
    res = await fetch(`${base}/rest/v1/rpc/_nc_venta_repartir`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ p_monto: c.monto, p_restos: c.restos }),
    });
  } catch (e) {
    console.error(`_nc_venta_repartir() no respondió en "${c.caso}": ${e?.message ?? e}`);
    process.exit(2);
  }
  const texto = await res.text();
  if (!res.ok) {
    // PostgREST dice el código (22023); el PostgREST de juguete de los gates locales, sólo el mensaje.
    if (c.partes == null && (texto.includes('22023') || texto.includes('pasa lo que le queda'))) return null;
    if (c.partes == null) return { error: `HTTP ${res.status} ${texto}` };
    console.error(`_nc_venta_repartir() falló en "${c.caso}": HTTP ${res.status}\n${texto}`);
    process.exit(2);
  }
  let filas;
  try {
    filas = JSON.parse(texto);
  } catch (e) {
    console.error(`_nc_venta_repartir() devolvió algo que no es JSON en "${c.caso}": ${e?.message ?? e}`);
    process.exit(2);
  }
  if (!Array.isArray(filas)) {
    console.error(`_nc_venta_repartir() devolvió algo que no es una lista en "${c.caso}": ${texto}`);
    process.exit(2);
  }
  return Object.fromEntries(filas.map((f) => [String(f.item_id), Number(f.monto)]));
}

const rojos = [];
for (const c of casos) {
  const sql = await repartir(c);
  const ok = c.partes == null ? sql === null : sql != null && !sql.error && canon(sql) === canon(c.partes);
  console.log(`${ok ? '✓' : '✗'} ${c.caso}`);
  if (!ok) rojos.push({ caso: c.caso, esperado: c.partes == null ? 'rechazo 22023' : canon(c.partes), sql: sql?.error ?? (sql == null ? 'aceptó' : canon(sql)) });
}

if (rojos.length) {
  console.error('\n❌ El reparto del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) console.error(`  ${r.caso}: esperado = ${r.esperado} · SQL = ${r.sql}`);
  process.exit(1);
}
console.log(`\n✅ ${casos.length} casos: _nc_venta_repartir coincide con repartirDescuentoNC.`);
