#!/usr/bin/env node
/**
 * Corre los ensayos de SQL (scripts/test-*.sql) sobre una base LOCAL y falla (exit 1) si
 * alguno que no está en scripts/ensayos-sql-excepciones.json no dice «ENSAYO OK».
 *
 * Por qué existe (#1601 1601-b7, #1563 1563-b9, decisión D60 del dueño: «los ensayos de
 * SQL se suman a CI sobre una base local»): los ~190 ensayos eran a mano, así que un PR que
 * rompía uno se mergeaba y se veía cuando alguien lo corría. Ahora corren en cada PR que
 * toca SQL (.github/workflows/sql-local.yml), sobre el esquema de prod + las migraciones
 * del PR, sin datos (la semilla de docker-local.mjs: el admin y las sucursales 1 y 2).
 *
 * Qué es un ensayo bueno: su salida (stdout + stderr: el veredicto va en un NOTICE o en el
 * mensaje de su excepción final, que lo deshace todo) dice «ENSAYO OK» y no dice «ENSAYO
 * FALL…». El exit code no es el veredicto: un ensayo que termina en un RAISE para
 * revertirse sale con error.
 *
 * Las excepciones (scripts/ensayos-sql-excepciones.json) son los ensayos que, sobre una base
 * SIN DATOS, no pueden dar OK (piden un cliente o un chofer que sólo hay en prod, o están
 * rotos desde antes de este gate: la tarjeta B13b de #1603 los arregla). Cada una dice su
 * motivo, y la lista SÓLO SE ACHICA: un ensayo nuevo corre sobre la base vacía (arma sus
 * propios datos, como los de #1603), no se suma acá. El gate avisa cuál sobra.
 *
 * Uso:  GATE_DB_CONTENEDOR=<contenedor con la semilla> node scripts/ci/ensayos-sql.mjs
 *       [--solo <fragmento>]   corre sólo los que lo contienen
 *       [--escribir-excepciones]  imprime el JSON con los que fallan (para armar la lista)
 * NUNCA contra prod: los ensayos escriben (y se deshacen), y algunos no se deshacen.
 */
import { readdirSync, readFileSync } from 'node:fs';
import '../lib/salir-con-2.mjs';
import { veredicto } from '../lib/ensayos.mjs';
import { destino, esLocal, psqlCompleto, verificarSemilla } from '../lib/pg.mjs';

const args = process.argv.slice(2);
const solo = args.includes('--solo') ? args[args.indexOf('--solo') + 1] : null;
const escribir = args.includes('--escribir-excepciones');

const d = destino({ GATE_DB_CONTENEDOR: process.env.GATE_DB_CONTENEDOR, GATE_DB_URL: process.env.GATE_DB_URL });
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR o GATE_DB_URL (una base descartable con la semilla): no puedo correr los ensayos.');
  process.exit(2);
}
if (!esLocal(d)) {
  console.error('Esta base no es local (contenedor de docker, o una URL a localhost): los ensayos escriben, y se niega.');
  process.exit(2);
}

verificarSemilla(d);

const carpeta = new URL('../', import.meta.url);
const lista = JSON.parse(readFileSync(new URL('../ensayos-sql-excepciones.json', import.meta.url), 'utf8'));
const excepciones = lista.ensayos ?? {};
// Los que no se corren: piden dos sesiones a la vez y CONFIRMAN datos (ensucian la base).
const omitidos = lista.omitir ?? {};
const archivos = readdirSync(carpeta)
  .filter((f) => /^test-.*\.sql$/.test(f) && !Object.hasOwn(omitidos, f))
  .filter((f) => !solo || f.includes(solo))
  .sort();
if (!archivos.length) {
  console.error('No hay ensayos para correr: el gate no puede mirar.');
  process.exit(2);
}

const resultados = [];
const t0 = Date.now();
for (const f of archivos) {
  const sql = readFileSync(new URL(f, carpeta), 'utf8').replaceAll('\r\n', '\n');
  const t = Date.now();
  const r = psqlCompleto(sql, { destino: d });
  const { ok, firma: motivo } = veredicto(`${r.stdout}\n${r.stderr}`);
  resultados.push({ f, ok, motivo, seg: (Date.now() - t) / 1000 });
  console.log(`${ok ? 'OK   ' : 'FALLA'} ${f}${ok ? '' : `  ← ${motivo}`}  (${((Date.now() - t) / 1000).toFixed(1)} s)`);
}

const fallan = resultados.filter((r) => !r.ok);
if (escribir) {
  const j = Object.fromEntries(
    fallan.map((r) => [r.f, { firma: r.motivo, motivo: 'falla al nacer el gate, sobre la base de CI' }]),
  );
  console.log(`\n${JSON.stringify(j, null, 2)}`);
}
const sinPermiso = fallan.filter((r) => !Object.hasOwn(excepciones, r.f));
// Exceptuado que falla, pero por OTRA cosa que cuando se lo exceptuó (H4 de la lente de #1645).
const cambiaron = fallan.filter((r) => Object.hasOwn(excepciones, r.f) && excepciones[r.f].firma !== r.motivo);
const sobrantes = resultados.filter((r) => r.ok && Object.hasOwn(excepciones, r.f));
const faltan = Object.keys(excepciones).filter((f) => !archivos.includes(f) && !solo);

if (Object.keys(omitidos).length) console.log(`\nNo se corren (${Object.keys(omitidos).length}): ${Object.keys(omitidos).join(', ')}`);
console.log(
  `\nEnsayos: ${resultados.length} | OK: ${resultados.length - fallan.length} | fallan: ${fallan.length} ` +
    `(exceptuados: ${fallan.length - sinPermiso.length}) | ${((Date.now() - t0) / 1000).toFixed(0)} s`,
);
if (sobrantes.length) {
  console.log('\nℹ️  Exceptuados que ya dan ENSAYO OK: sacalos de scripts/ensayos-sql-excepciones.json.');
  for (const r of sobrantes) console.log(`  ${r.f}`);
}
if (faltan.length) {
  console.log('\nℹ️  Exceptuados que ya no existen: sacalos de scripts/ensayos-sql-excepciones.json.');
  for (const f of faltan) console.log(`  ${f}`);
}
if ((sinPermiso.length || cambiaron.length) && !escribir) {
  if (sinPermiso.length) {
    console.error('\n❌ Ensayos que no dieron ENSAYO OK sobre la base local:');
    for (const r of sinPermiso) console.error(`  ${r.f}  ← ${r.motivo}`);
    console.error(
      '\n   Un ensayo que falla es una regla que se rompió (o un ensayo viejo que ya no afirma la regla\n' +
        '   vigente: se corrige, no se exceptúa). Sólo se exceptúa uno que necesita datos de prod.',
    );
  }
  if (cambiaron.length) {
    console.error('\n❌ Ensayos exceptuados que ahora fallan por OTRA cosa (puede ser una regla rota nueva, escondida detrás de la excepción vieja):');
    for (const r of cambiaron) console.error(`  ${r.f}\n      era:   ${excepciones[r.f].firma}\n      ahora: ${r.motivo}`);
    console.error('\n   Si el cambio es esperado (otra cosa que falta en la semilla), actualizá la firma en scripts/ensayos-sql-excepciones.json.');
  }
  process.exit(1);
}
console.log('\n✅ Todos los ensayos dan ENSAYO OK (salvo los exceptuados).');
