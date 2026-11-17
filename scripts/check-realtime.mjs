#!/usr/bin/env node
/**
 * Gate de la publicación de Realtime (#1564, 1564-g1).
 * Lee el catálogo (pg_publication, pg_class, los grants) y falla (exit 1) si una
 * tabla que entra en una publicación de Realtime (`supabase_realtime`) puede
 * mandar por el websocket lo que no se lee por REST:
 *
 *   · una tabla con SELECT **por columna** para authenticated o anon (`productos`,
 *     `pedido_items`): Realtime lee la fila entera con otro rol y no respeta el
 *     reparto de columnas (los costos viajarían por el canal aunque no se lean por
 *     REST);
 *   · una tabla sin RLS, o legible por anon;
 *   · una publicación `FOR ALL TABLES`, que mete cualquier tabla que se cree después.
 *
 * Por qué existe: en prod la publicación tiene sólo `pedidos` (con SELECT de tabla
 * entera), pero ningún gate la miraba: una migración que hiciera
 * `ALTER PUBLICATION supabase_realtime ADD TABLE productos` ponía los costos en un
 * canal y nada se ponía rojo. Ver #1564.
 *
 * Lo que NO ve: las columnas que filtra una publicación con lista de columnas
 * (`ADD TABLE t (a, b)`) no cambian el veredicto: se avisa pero la regla es la de
 * arriba; y los filtros de fila. Lo que viaja lo decide la RLS de la tabla, que
 * revisan check-rama-admin / check-grants-tablas.
 *
 * Requiere una base: GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL (scripts/lib/pg.mjs).
 * Uso local:  GATE_DB_CONTENEDOR=conc-c1 node scripts/check-realtime.mjs
 */
import { problemasDeTabla } from './lib/catalogo.mjs';
import { consultaJson, destino } from './lib/pg.mjs';

const d = destino();
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL: el gate no puede mirar la publicación.');
  process.exit(2);
}

// Una fila por (publicación, tabla). Los roles de la API son authenticated y anon.
const SQL = `
SELECT jsonb_build_object(
  'publicaciones', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('nombre', p.pubname, 'todas', p.puballtables) ORDER BY p.pubname)
      FROM pg_publication p WHERE p.pubname LIKE 'supabase\\_realtime%'), '[]'::jsonb),
  'tablas', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'publicacion', pt.pubname,
             'tabla', pt.schemaname || '.' || pt.tablename,
             'rls', c.relrowsecurity,
             'columnas_publicadas', COALESCE(array_length(pt.attnames, 1), 0),
             'columnas_tabla', (SELECT count(*) FROM pg_attribute a
                                 WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
             'auth_tabla', has_table_privilege('authenticated', c.oid, 'SELECT'),
             'auth_columnas', has_any_column_privilege('authenticated', c.oid, 'SELECT'),
             'anon_algo', has_any_column_privilege('anon', c.oid, 'SELECT'))
           ORDER BY pt.pubname, pt.schemaname, pt.tablename)
      FROM pg_publication_tables pt
      JOIN pg_class c ON c.oid = (quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename))::regclass
     WHERE pt.pubname LIKE 'supabase\\_realtime%'), '[]'::jsonb))`;

const r = consultaJson(SQL);

console.log(`Publicaciones de Realtime (${d.descripcion}): ${r.publicaciones.map((x) => x.nombre).join(', ') || '(ninguna)'}`);
console.log(`Tablas publicadas: ${r.tablas.length}${r.tablas.length ? ' · ' + r.tablas.map((t) => t.tabla).join(', ') : ''}`);

const errores = [];
for (const p of r.publicaciones) {
  if (p.todas) errores.push(`${p.nombre} es FOR ALL TABLES: cualquier tabla que se cree después entra sola al canal`);
}
for (const t of r.tablas) {
  for (const m of problemasDeTabla(t)) errores.push(`${t.publicacion}: ${t.tabla} ${m}`);
  if (t.columnas_publicadas && t.columnas_publicadas < t.columnas_tabla) {
    console.log(`ℹ️  ${t.tabla}: publica ${t.columnas_publicadas} de ${t.columnas_tabla} columnas.`);
  }
}

if (errores.length) {
  console.error('\n❌ Realtime publica lo que no debería:');
  for (const e of errores) console.error(`  ${e}`);
  console.error(
    '\n   Arreglo: sacar la tabla de la publicación (ALTER PUBLICATION supabase_realtime\n' +
      '   DROP TABLE …), o darle SELECT de tabla entera sólo si no tiene columnas que\n' +
      '   authenticated no deba leer. Una tabla con costos NO va en el canal.',
  );
  process.exit(1);
}

console.log('\n✅ Las tablas de la publicación de Realtime tienen RLS, SELECT de tabla entera para authenticated y nada para anon.');
