#!/usr/bin/env node
/**
 * Gate de la publicación de Realtime (#1564, 1564-g1).
 * Lee el catálogo (pg_publication, pg_class, los grants) y falla (exit 1) si una
 * tabla que entra en la publicación `supabase_realtime` (la de postgres_changes) puede
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
 * Mira SÓLO `supabase_realtime`. La otra publicación de Supabase,
 * `supabase_realtime_messages_publication` (Realtime Broadcast), lleva las particiones
 * `realtime.messages_AAAA_MM_DD`, que cambian de nombre todos los días, son de Supabase
 * y el authenticated no las lee: no es de este gate y no puede ponerlo rojo.
 *
 * Lo que NO ve: las columnas que filtra una publicación con lista de columnas
 * (`ADD TABLE t (a, b)`) no cambian el veredicto: se avisa pero la regla es la de
 * arriba; y los filtros de fila. Lo que viaja lo decide la RLS de la tabla, que
 * revisan check-rama-admin / check-grants-tablas.
 *
 * Requiere una base: GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL (scripts/lib/pg.mjs).
 * Uso local:  GATE_DB_CONTENEDOR=conc-c1 node scripts/check-realtime.mjs
 */
import { problemasDeTabla, SQL_REALTIME } from './lib/catalogo.mjs';
import { consultaJson, destino } from './lib/pg.mjs';

const d = destino();
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL: el gate no puede mirar la publicación.');
  process.exit(2);
}

const r = consultaJson(SQL_REALTIME);

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
