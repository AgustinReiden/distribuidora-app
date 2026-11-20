#!/usr/bin/env node
/**
 * Gate del search_path de las funciones de public (#1564, 1564-b8 y 1564-g4; plan #1603,
 * tarjeta B15).
 * Lee el catálogo (pg_proc) y falla (exit 1) ante:
 *   · una SECURITY DEFINER de public que no fija search_path;
 *   · CUALQUIER función de public (definer o no, de trigger o no) que fija search_path y no
 *     lo termina en pg_temp.
 * Una INVOKER que no fija search_path pasa: hereda el de quien la llama (dentro de una definer,
 * el de la definer), y una SQL sin SET se inlinea, que es a propósito (`_cliente_visible`).
 *
 * Por qué existe: cuando pg_temp no está escrito en el search_path, Postgres busca PRIMERO en
 * el esquema temporal de la sesión las tablas, vistas, secuencias y tipos (las funciones y los
 * operadores, no). Una definer corre con los permisos de su dueño (postgres): quien la llama
 * crea una tabla temporal `perfiles` con su uuid y rol 'admin', y `es_admin()` le da true. Y una
 * INVOKER con su propio `SET search_path = public` llamada por una definer (o disparada como
 * trigger de su DML) también corre como postgres y su SET vuelve a poner pg_temp primero. Los
 * dos casos los reproduce scripts/test-search-path-ola2-1603.sql. Con pg_temp AL FINAL se
 * busca último. La migración de B15 se lo puso a todas; un `CREATE OR REPLACE FUNCTION` que no
 * escriba el SET lo pierde, y cada migración nueva tiende a copiar el
 * `SET search_path TO 'public'` de la función que reemplaza: por eso este gate.
 *
 * Sin lista de permitidas: ninguna función de public necesita que una temporal le tape una
 * tabla. La que usa una temporal propia (guardar_combo, `_combo_resuelto`) la sigue
 * encontrando con pg_temp al final, mientras no se llame como algo de public.
 *
 * Lo que NO ve: las funciones de otros esquemas (las de Supabase: vault, pgbouncer).
 *
 * Requiere una base: GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL (scripts/lib/pg.mjs).
 * Salida: 0 todas bien; 1 alguna mal; 2 no se pudo mirar.
 * Uso local:  GATE_DB_CONTENEDOR=conc-c1 node scripts/check-search-path.mjs
 */
import { problemaDeSearchPath, SQL_SEARCH_PATH_FUNCIONES } from './lib/catalogo.mjs';
import { consultaJson, destino } from './lib/pg.mjs';

const d = destino();
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL: el gate no puede mirar el catálogo.');
  process.exit(2);
}

let funciones;
try {
  funciones = consultaJson(SQL_SEARCH_PATH_FUNCIONES);
} catch (e) {
  console.error(`No pude leer el catálogo (${d.descripcion}): ${e.message}`);
  process.exit(2);
}
// Ninguna definer no es "todo bien": es que la consulta no está mirando nada (u otra base).
if (!Array.isArray(funciones) || !funciones.some((f) => f.definer)) {
  console.error(`No encontré ninguna SECURITY DEFINER en public (${d.descripcion}): el gate no puede mirar.`);
  process.exit(2);
}

const malas = funciones
  .map((f) => ({ firma: f.firma, definer: f.definer, motivo: problemaDeSearchPath(f.proconfig, f.definer) }))
  .filter((f) => f.motivo);

const definer = funciones.filter((f) => f.definer).length;
console.log(
  `Funciones de public (${d.descripcion}): ${definer} SECURITY DEFINER, ${funciones.length - definer} INVOKER que fijan search_path` +
    ` | mal: ${malas.length} (${malas.filter((m) => m.definer).length} definer)`,
);

if (malas.length) {
  console.error('\n❌ Funciones de public cuyo search_path no termina en pg_temp:');
  for (const m of malas) console.error(`  ${m.firma}${m.definer ? ' [definer]' : ''}  ${m.motivo}`);
  console.error(
    '\n   Arreglo: la migración que la crea o la reemplaza escribe\n' +
      '   `SET search_path = public, pg_temp` (o su search_path, con pg_temp al final): un\n' +
      '   CREATE OR REPLACE sin el SET lo pierde. Para una que ya existe, sin tocar el cuerpo:\n' +
      '   ALTER FUNCTION public.<f>(<args>) SET search_path = public, pg_temp.',
  );
  process.exit(1);
}

console.log('\n✅ Toda SECURITY DEFINER de public fija su search_path, y toda función que lo fija lo termina en pg_temp.');
