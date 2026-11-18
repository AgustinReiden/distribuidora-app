#!/usr/bin/env node
/**
 * Gate del search_path de las funciones SECURITY DEFINER de public (#1564, 1564-b8 y 1564-g4;
 * plan #1603, tarjeta B15).
 * Lee el catálogo (pg_proc) y falla (exit 1) ante una SECURITY DEFINER de public que no fija
 * search_path, o cuyo search_path no termina en pg_temp.
 *
 * Por qué existe: cuando pg_temp no está escrito en el search_path, Postgres busca PRIMERO en
 * el esquema temporal de la sesión las tablas, vistas, secuencias y tipos (las funciones y los
 * operadores, no). Una definer corre con los permisos de su dueño (postgres): quien la llama
 * crea una tabla temporal `perfiles` con su uuid y rol 'admin', y `es_admin()` le da true (lo
 * reproduce scripts/test-search-path-ola2-1603.sql). Con pg_temp AL FINAL se busca último. La
 * migración de B15 se lo puso a todas; un `CREATE OR REPLACE FUNCTION` que no escriba el SET lo
 * pierde, y cada migración nueva tiende a copiar el `SET search_path TO 'public'` de la función
 * que reemplaza: por eso este gate.
 *
 * Sin lista de permitidas: ninguna definer de public necesita que una temporal le tape una
 * tabla. La que usa una temporal propia (guardar_combo, `_combo_resuelto`) la sigue
 * encontrando con pg_temp al final, mientras no se llame como algo de public.
 *
 * Lo que NO ve: las funciones de otros esquemas (las de Supabase: vault, pgbouncer) ni las
 * INVOKER (corren con los permisos de quien llama: una temporal suya no le da nada que no
 * tenga).
 *
 * Requiere una base: GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL (scripts/lib/pg.mjs).
 * Salida: 0 todas bien; 1 alguna mal; 2 no se pudo mirar.
 * Uso local:  GATE_DB_CONTENEDOR=conc-c1 node scripts/check-search-path.mjs
 */
import { problemaDeSearchPath, SQL_SEARCH_PATH_DEFINER } from './lib/catalogo.mjs';
import { consultaJson, destino } from './lib/pg.mjs';

const d = destino();
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL: el gate no puede mirar el catálogo.');
  process.exit(2);
}

let funciones;
try {
  funciones = consultaJson(SQL_SEARCH_PATH_DEFINER);
} catch (e) {
  console.error(`No pude leer el catálogo (${d.descripcion}): ${e.message}`);
  process.exit(2);
}
// Cero definer no es "todo bien": es que la consulta no está mirando nada (u otra base).
if (!Array.isArray(funciones) || funciones.length === 0) {
  console.error(`No encontré ninguna SECURITY DEFINER en public (${d.descripcion}): el gate no puede mirar.`);
  process.exit(2);
}

const malas = funciones
  .map((f) => ({ firma: f.firma, motivo: problemaDeSearchPath(f.proconfig) }))
  .filter((f) => f.motivo);

console.log(`SECURITY DEFINER de public (${d.descripcion}): ${funciones.length} | sin pg_temp al final: ${malas.length}`);

if (malas.length) {
  console.error('\n❌ SECURITY DEFINER cuyo search_path no termina en pg_temp:');
  for (const m of malas) console.error(`  ${m.firma}  ${m.motivo}`);
  console.error(
    '\n   Arreglo: la migración que la crea o la reemplaza escribe\n' +
      '   `SET search_path = public, pg_temp` (o su search_path, con pg_temp al final): un\n' +
      '   CREATE OR REPLACE sin el SET lo pierde. Para una que ya existe, sin tocar el cuerpo:\n' +
      '   ALTER FUNCTION public.<f>(<args>) SET search_path = public, pg_temp.',
  );
  process.exit(1);
}

console.log('\n✅ Toda SECURITY DEFINER de public fija su search_path y lo termina en pg_temp.');
