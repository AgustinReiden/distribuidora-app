#!/usr/bin/env node
/**
 * PostgREST de juguete para correr los gates `check-*.mjs` contra una base LOCAL.
 *
 * Los gates llaman a un RPC `auditoria_*` por `POST {SUPABASE_URL}/rest/v1/rpc/<función>`
 * con la service_role key. Apuntando SUPABASE_URL a este servidor, el mismo script
 * corre sin cambios contra la base de Docker: el servidor ejecuta
 * `SELECT <función>(args)` como service_role dentro de una transacción de sólo
 * lectura que se deshace, y devuelve el JSON como lo haría PostgREST.
 *
 * Por qué existe (#1563 b9, #1601 b7): los gates de SQL corrían sólo en el cron de
 * las 08:00 contra prod, así que un PR que abría una función se mergeaba antes de
 * que nada se pusiera rojo. Con esto corren sobre la base local de cada PR, sin
 * secrets (ver .github/workflows/sql-local.yml).
 *
 * Lo que NO es: no sirve GET (los embeds necesitan PostgREST de verdad: check-embeds
 * sigue corriendo en ci.yml y en integridad.yml), ni escribe. La transacción es
 * READ ONLY: un RPC que escribe falla, que es lo que hay que saber de un gate.
 *
 * Uso:  GATE_DB_CONTENEDOR=<contenedor> node scripts/ci/rpc-local.mjs [puerto]
 *       (o GATE_DB_URL con la URL de conexión) y en otra terminal
 *       SUPABASE_URL=http://127.0.0.1:<puerto> SUPABASE_SERVICE_ROLE_KEY=local node scripts/check-…mjs
 * El puerto por defecto es 54499.
 */
import { createServer } from 'node:http';
import { destino, esLocal, psql } from '../lib/pg.mjs';

const PUERTO = Number(process.argv[2] ?? process.env.RPC_LOCAL_PUERTO ?? 54499);
// A propósito no se mira SUPABASE_DB_URL: es la de prod.
const d = destino({ GATE_DB_CONTENEDOR: process.env.GATE_DB_CONTENEDOR, GATE_DB_URL: process.env.GATE_DB_URL });
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR o GATE_DB_URL: no hay base a la que llamar.');
  process.exit(2);
}
if (!esLocal(d)) {
  console.error('Esta base no es local (contenedor de docker, o una URL a localhost): el servidor local se niega.');
  process.exit(2);
}

const NOMBRE = /^[a-z_][a-z0-9_]*$/;
const lit = (s) => `'${String(s).replaceAll("'", "''")}'`;
const J = "current_setting('rpc.args')::jsonb";

/** Cómo se pasa un argumento según su tipo, leyendo el valor del JSON de la llamada. */
function argumento(nombre, tipo) {
  const k = lit(nombre);
  if (tipo === 'jsonb' || tipo === 'json') return `(${J}->${k})::${tipo}`;
  if (tipo.endsWith('[]')) return `ARRAY(SELECT jsonb_array_elements_text(${J}->${k}))::${tipo}`;
  return `(${J}->>${k})::${tipo}`;
}

function llamar(nombreFn, cuerpo) {
  if (!NOMBRE.test(nombreFn)) throw Object.assign(new Error('nombre de función inválido'), { http: 400 });
  const args = cuerpo && typeof cuerpo === 'object' && !Array.isArray(cuerpo) ? cuerpo : {};
  const claves = Object.keys(args);
  // 1) la firma: la sobrecarga cuyos parámetros incluyen todas las claves que llegaron.
  const cands = JSON.parse(
    psql(
      `SELECT COALESCE(jsonb_agg(jsonb_build_object('nombres', to_jsonb(COALESCE(proargnames, '{}')), ` +
        `'tipos', (SELECT jsonb_agg(format_type(t, NULL) ORDER BY o) FROM unnest(proargtypes::oid[]) WITH ORDINALITY u(t, o)), ` +
        `'conjunto', proretset, 'void', prorettype = 'void'::regtype)), '[]'::jsonb) ` +
        `FROM pg_proc WHERE proname = ${lit(nombreFn)} AND pronamespace = 'public'::regnamespace`,
    ).trim(),
  );
  const f = cands.find((c) => claves.every((k) => c.nombres.includes(k)));
  if (!f) throw Object.assign(new Error(`no hay una función public.${nombreFn} con esos parámetros`), { http: 404 });
  const tipos = f.tipos ?? [];
  const llamada = `public.${nombreFn}(${claves
    .map((k) => `${k} => ${argumento(k, tipos[f.nombres.indexOf(k)] ?? 'text')}`)
    .join(', ')})`;
  const select = f.conjunto
    ? `SELECT '@@' || COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb)::text FROM ${llamada} t`
    : f.void
      ? `SELECT '@@null' FROM (SELECT ${llamada}) v`
      : `SELECT '@@' || COALESCE(to_jsonb(${llamada})::text, 'null')`;
  // 2) la llamada, como service_role, en una transacción que no escribe y se deshace.
  const sql =
    `BEGIN READ ONLY;\nSET LOCAL ROLE service_role;\n` +
    `SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);\n` +
    `SELECT set_config('rpc.args', ${lit(JSON.stringify(args))}, true);\n` +
    `${select};\nROLLBACK;\n`;
  // La marca @@ separa el resultado de la salida de set_config; un NULL es el JSON null.
  const linea = psql(sql)
    .split('\n')
    .find((l) => l.startsWith('@@'));
  if (linea === undefined) throw new Error('la función no devolvió una fila');
  return linea.slice(2).trim() || 'null';
}

const servidor = createServer((req, res) => {
  const m = /^\/rest\/v1\/rpc\/([^/?]+)/.exec(req.url ?? '');
  if (req.method !== 'POST' || !m) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ message: 'rpc-local sólo atiende POST /rest/v1/rpc/<función>' }));
    return;
  }
  let cuerpo = '';
  req.on('data', (c) => (cuerpo += c));
  req.on('end', () => {
    try {
      const salida = llamar(m[1], cuerpo ? JSON.parse(cuerpo) : {});
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(salida);
    } catch (e) {
      res.writeHead(e.http ?? 400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ message: e.message }));
    }
  });
});

servidor.listen(PUERTO, '127.0.0.1', () =>
  console.log(`rpc-local escuchando en http://127.0.0.1:${PUERTO} → ${d.descripcion}`),
);
