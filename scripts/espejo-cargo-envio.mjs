#!/usr/bin/env node
/**
 * PARIDAD DEL CARGO DE ENVÍO (#1220), lado SQL.
 *
 * El server decide el cargo al crear (`cargo_envio_pedido_puro`, que usa
 * `pedido_cargo_envio`), lo desglosa en neto/IVA (`cargo_envio_desglose`) y lo
 * reconsidera al editar (`cargo_tras_edicion`). El front anticipa las tres con
 * `cargoEnvioPedido`, `cargoDesglose` y `cargoTrasEdicion`
 * (`src/utils/montoMinimo.ts`) para avisar antes de confirmar: si difieren, el
 * total que ve el preventista no es el que guarda la base.
 *
 * Los dos corren los casos de `src/utils/cargoEnvio.espejo.json`. El TS lo
 * corre vitest (`cargoEnvio.espejo.test.ts`); éste corre el SQL y sale con 1 si
 * algo no es exactamente `esperado`, y con 2 si no pudo mirar.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * las funciones no están expuestas a anon ni a authenticated).
 *
 *   node scripts/espejo-cargo-envio.mjs          # compara y falla si difiere
 *   node scripts/espejo-cargo-envio.mjs --sql    # imprime UNA consulta que hace
 *                                                # la misma comparación adentro
 *                                                # de Postgres, para correrla a mano
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'cargoEnvio.espejo.json');
const {
  cargo_envio_pedido: pedido,
  desglose,
  tras_edicion: edicion,
} = JSON.parse(readFileSync(FIXTURE, 'utf8'));

const literal = (s) => (s == null ? 'NULL::text' : `'${String(s).replace(/'/g, "''")}'`);
const json = (v) => `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
const num = (n) => `${Number(n)}::numeric`;
const regla = (r) => `${literal(r.modo)}, ${num(r.monto_minimo)}, ${num(r.monto_envio_gratis)}, ${num(r.cargo_envio)}`;

if (process.argv.includes('--sql')) {
  const filas = [
    ...pedido.map((c) =>
      `(${literal('cargo_envio_pedido: ' + c.caso)}, to_jsonb(public.cargo_envio_pedido_puro(${num(c.total)}, ${regla(c.regla)})), ${json(c.esperado)})`),
    ...desglose.map((c) =>
      `(${literal('desglose: ' + c.caso)}, (SELECT jsonb_build_object('neto', d.neto, 'iva', d.iva) FROM public.cargo_envio_desglose(${num(c.cargo)}, ${literal(c.tipo_factura)}) d), ${json(c.esperado)})`),
    ...edicion.map((c) =>
      `(${literal('tras_edicion: ' + c.caso)}, (SELECT jsonb_build_object('cargo', x.cargo, 'estado', x.estado, 'requiere_decision', x.requiere_decision) FROM public.cargo_tras_edicion(${literal(c.estado)}, ${num(c.cargo_actual)}, ${num(c.total_viejo)}, ${num(c.total_nuevo)}, ${regla(c.regla)}, ${c.es_preventista}, ${literal(c.decision)}) x), ${json(c.esperado)})`),
  ];
  // Los numeric se comparan por valor: en jsonb, 500.00 = 500.
  console.log(
    'SELECT caso, sql, esperado, COALESCE(sql = esperado, false) AS ok\n' +
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

// Un gate que no puede mirar es rojo, no verde: cualquier falla de HTTP, o un
// fetch que tira (DNS, red), corta con 2.
async function rpc(nombre, cuerpo, caso) {
  let res;
  try {
    res = await fetch(`${base}/rest/v1/rpc/${nombre}`, { method: 'POST', headers, body: JSON.stringify(cuerpo) });
  } catch (e) {
    console.error(`${nombre}() no respondió en "${caso}": ${e?.message ?? e}`);
    process.exit(2);
  }
  if (!res.ok) {
    console.error(`${nombre}() falló en "${caso}": HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  try {
    return await res.json();
  } catch (e) {
    console.error(`${nombre}() devolvió algo que no es JSON en "${caso}": ${e?.message ?? e}`);
    process.exit(2);
  }
}

// Una función con OUT params vuelve como objeto (o como arreglo de uno).
const fila = (r) => (Array.isArray(r) ? r[0] : r);
const conRegla = (r) => ({
  p_modo: r.modo,
  p_monto_minimo: r.monto_minimo,
  p_monto_envio_gratis: r.monto_envio_gratis,
});

const rojos = [];
const anotar = (caso, ok, sql, esperado) => {
  console.log(`${ok ? '✓' : '✗'} ${caso}`);
  if (!ok) rojos.push({ caso, sql, esperado });
};

for (const c of pedido) {
  const sql = await rpc('cargo_envio_pedido_puro',
    { p_total: c.total, ...conRegla(c.regla), p_cargo: c.regla.cargo_envio }, c.caso);
  anotar(`cargo_envio_pedido: ${c.caso}`, sql != null && Number(sql) === Number(c.esperado), sql, c.esperado);
}
for (const c of desglose) {
  const sql = fila(await rpc('cargo_envio_desglose', { p_cargo: c.cargo, p_tipo_factura: c.tipo_factura }, c.caso));
  const ok = sql != null && Number(sql.neto) === Number(c.esperado.neto) && Number(sql.iva) === Number(c.esperado.iva);
  anotar(`desglose: ${c.caso}`, ok, sql, c.esperado);
}
for (const c of edicion) {
  const sql = fila(await rpc('cargo_tras_edicion', {
    p_estado: c.estado,
    p_cargo_actual: c.cargo_actual,
    p_total_viejo: c.total_viejo,
    p_total_nuevo: c.total_nuevo,
    ...conRegla(c.regla),
    p_cargo_vigente: c.regla.cargo_envio,
    p_es_preventista: c.es_preventista,
    p_decision: c.decision,
  }, c.caso));
  const ok = sql != null
    && Number(sql.cargo) === Number(c.esperado.cargo)
    && sql.estado === c.esperado.estado
    && sql.requiere_decision === c.esperado.requiere_decision;
  anotar(`tras_edicion: ${c.caso}`, ok, sql, c.esperado);
}

if (rojos.length) {
  console.error('\n❌ Las puras del cargo de envío del SQL no coinciden con el fixture que también corre el TS:');
  for (const r of rojos) {
    console.error(`  ${r.caso}: esperado = ${JSON.stringify(r.esperado)} · SQL = ${JSON.stringify(r.sql)}`);
  }
  process.exit(1);
}
const n = pedido.length + desglose.length + edicion.length;
console.log(`\n✅ ${n} casos: las puras del cargo de envío del SQL coinciden con el fixture.`);
