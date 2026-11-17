#!/usr/bin/env node
/**
 * Gate del contenido de los mensajes de error de los triggers (#1564, 1564-g3).
 * Lee el texto de las funciones `RETURNS trigger` de public y falla (exit 1) si un
 * `RAISE` interpola un dato que no tendría que mostrarle a quien llama, y la función no
 * está en scripts/mensajes-trigger-permitidas.json:
 *
 *   · un dato PERSONAL (nombre, razón social, teléfono, CUIT, dirección…) leído de
 *     clientes, perfiles, proveedores o empleados con un id que mandó quien llama;
 *   · una columna financiera sensible (costo, saldo, sueldo, comisión, margen…);
 *   · la fila entera (NEW, OLD, to_jsonb(NEW)…).
 *
 * Por qué existe: un trigger BEFORE corre antes de que la FK o la policy cierren el
 * cruce de sucursal, así que su mensaje de error le muestra a un usuario datos de una
 * fila que no puede ver: por ahí un preventista sondeaba los clientes de otra sucursal
 * (#1559). Ningún gate miraba el texto de los mensajes. Ver scripts/lib/mensajes.mjs.
 *
 * La lista de permitidas va por firma, con su motivo, y SÓLO SE ACHICA (lo fija
 * src/test/catalogo.test.ts): una función nueva no interpola datos de otros en el
 * mensaje, dice «el pedido #12» con el id que mandó el mismo usuario.
 *
 * Lo que NO ve: un dato que llega por otra función, el SQL dinámico, y los RAISE de
 * las funciones que no son de trigger (las RPC tienen el mismo problema; ver el informe
 * de #1603). Es texto, no ejecución.
 *
 * Requiere una base: GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL (scripts/lib/pg.mjs).
 * Uso local:  GATE_DB_CONTENEDOR=conc-c1 node scripts/check-mensajes-trigger.mjs
 */
import { readFileSync } from 'node:fs';
import { mensajesQueFiltran } from './lib/mensajes.mjs';
import { consultaJson, destino } from './lib/pg.mjs';

const d = destino();
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL: el gate no puede leer las funciones.');
  process.exit(2);
}

const { funciones: permitidas } = JSON.parse(
  readFileSync(new URL('./mensajes-trigger-permitidas.json', import.meta.url), 'utf8'),
);

const funciones = consultaJson(String.raw`
SELECT COALESCE(jsonb_agg(jsonb_build_object('firma', p.oid::regprocedure::text, 'definer', p.prosecdef, 'src', p.prosrc)
                          ORDER BY p.oid::regprocedure::text), '[]'::jsonb)
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND p.prokind = 'f'
   AND p.prorettype = 'trigger'::regtype`);

// Cero funciones no es "todo bien": es que el gate no está mirando nada.
if (!funciones.length) {
  console.error('No hay ninguna función de trigger en public: el gate no puede mirar.');
  process.exit(2);
}

const hallazgos = [];
for (const f of funciones) {
  const h = mensajesQueFiltran(f.src);
  if (h.length) hallazgos.push({ firma: f.firma, definer: f.definer, detalle: h });
}
const sinPermiso = hallazgos.filter((h) => !Object.hasOwn(permitidas, h.firma));
const sobrantes = Object.keys(permitidas).filter((firma) => !hallazgos.some((h) => h.firma === firma));

console.log(`Mensajes de error de los triggers (${d.descripcion})`);
console.log(
  `Funciones de trigger en public: ${funciones.length} | con un RAISE que interpola datos: ${hallazgos.length} ` +
    `(permitidas: ${hallazgos.length - sinPermiso.length})`,
);

if (sobrantes.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (el mensaje no interpola datos, o la función no existe más): sacalas del JSON.');
  for (const f of sobrantes) console.log(`  ${f}  (${permitidas[f]})`);
}

if (sinPermiso.length) {
  console.error('\n❌ Triggers cuyo mensaje de error muestra datos que quien llama no tendría que ver:');
  for (const h of sinPermiso) {
    console.error(`  ${h.firma}${h.definer ? '  [SECURITY DEFINER]' : ''}`);
    for (const t of h.detalle) console.error(`      ${t}`);
  }
  console.error(
    '\n   Arreglo: el mensaje dice el id que mandó el mismo usuario («el pedido #12»), no el\n' +
      '   nombre ni el saldo de lo que encontró con él. Si el dato es de una fila que el usuario\n' +
      '   ya ve y se muestra a propósito, sumá la firma a scripts/mensajes-trigger-permitidas.json\n' +
      '   con el motivo.',
  );
  process.exit(1);
}

console.log('\n✅ Ningún trigger muestra en su mensaje de error datos personales o sensibles (salvo los permitidos).');
