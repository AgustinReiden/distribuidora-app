#!/usr/bin/env node
/**
 * PARIDAD DEL PISO DE PRECIO (#1139), lado SQL.
 *
 * Para quien no es admin, `crear_pedido_completo` y `actualizar_pedido_items`
 * (vía `precio_fuera_de_politica`) rechazan una línea de venta por debajo de
 * `precio_piso_linea()` - 0,01. El piso tiene que ser el de `orquestarPrecios()`
 * (`src/utils/orquestacionPrecios.ts`) o más bajo, nunca más alto: si no, el
 * server rechazaría pedidos honestos.
 *
 * Los dos corren los casos de `src/utils/pisoPrecio.espejo.json`. El TS lo corre
 * vitest (`pisoPrecio.espejo.test.ts`: el front no cobra menos que el piso, e
 * igual en los casos exactos); éste corre el SQL y sale con 1 si el piso no es
 * exactamente `esperado`.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * la función no está expuesta a anon ni a authenticated).
 *
 *   node scripts/espejo-piso-precio.mjs          # compara y falla si difiere
 *   node scripts/espejo-piso-precio.mjs --sql    # imprime UNA consulta que hace
 *                                                # la misma comparación adentro
 *                                                # de Postgres, para correrla a
 *                                                # mano sin credenciales de servicio
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'pisoPrecio.espejo.json');
const { casos } = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => `'${String(s).replace(/'/g, "''")}'`;
const numericSql = (v) => (v == null ? 'NULL::numeric' : `${Number(v)}::numeric`);
const categoria = (c) => c.categorias?.[String(c.producto_id)] ?? null;

if (process.argv.includes('--sql')) {
  const filas = casos.map((c) =>
    `(${literal(c.caso)}, ${literal(JSON.stringify(c.items))}::jsonb, ${literal(JSON.stringify(c.grupos))}::jsonb, ` +
    `${Number(c.producto_id)}::bigint, ${numericSql(c.lista)}, ${literal(JSON.stringify(c.cliente))}::jsonb, ` +
    `${categoria(c) == null ? 'NULL::text' : literal(categoria(c))}, ${numericSql(c.esperado)})`,
  );
  console.log(
    'WITH r AS (\n' +
    '  SELECT caso, esperado, public.precio_piso_linea(items, grupos, producto, lista, cliente, categoria) AS sql\n' +
    `    FROM (VALUES\n      ${filas.join(',\n      ')}\n    ) AS t(caso, items, grupos, producto, lista, cliente, categoria, esperado)\n` +
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
async function piso(c) {
  const res = await fetch(`${base}/rest/v1/rpc/precio_piso_linea`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      p_items: c.items,
      p_grupos: c.grupos,
      p_producto_id: c.producto_id,
      p_lista: c.lista,
      p_cliente: c.cliente,
      p_categoria: categoria(c),
    }),
  });
  if (!res.ok) {
    console.error(`precio_piso_linea() falló en "${c.caso}": HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

const rojos = [];
for (const c of casos) {
  const crudo = await piso(c);
  const sql = crudo == null ? null : Number(crudo);
  const esperado = c.esperado == null ? null : Number(c.esperado);
  const ok = sql === esperado;
  console.log(`${ok ? '✓' : '✗'} ${c.caso}`);
  if (!ok) rojos.push({ caso: c.caso, esperado, sql });
}

if (rojos.length) {
  console.error('\n❌ El piso del SQL no coincide con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}: esperado = ${r.esperado} · SQL = ${r.sql}`);
  }
  process.exit(1);
}
console.log(`\n✅ ${casos.length} casos: el piso del SQL coincide con el del fixture.`);
