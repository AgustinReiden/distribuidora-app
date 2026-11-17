#!/usr/bin/env node
/**
 * Gate del cruce por ids de otra sucursal (#1564, 1564-g2).
 * Corre scripts/gates-sql/cruce-ids-sucursal.sql sobre una base LOCAL y falla (exit 1) si
 * una RPC que recibe el id de un pedido, un cliente, un pago o una compra de la sucursal B,
 * llamada por un usuario de la sucursal A, no se rechaza y cambia filas de B o devuelve
 * datos de B, y no está en scripts/cruce-ids-permitidas.json.
 *
 * Por qué existe: check-rpcs-definer es textual (mira si el cuerpo NOMBRA la sucursal);
 * ningún gate ejecutaba el ataque. La pasada manual de la reauditoría del 12/11 (14
 * usuarios, ids de la otra sucursal) dio limpio y quedó sin repetir: acá se repite en cada
 * PR que abre una función, sobre la base local (.github/workflows/sql-local.yml).
 *
 * Qué cubre y qué no, en el encabezado del .sql. Lo principal que falta: sólo prueba las
 * RPC con un parámetro de id de entidad (49 de 589 funciones) y las llama con argumentos de
 * relleno, así que una RPC que los rechaza antes de mirar la sucursal no prueba nada de su
 * aislamiento: el resultado cuenta cuántas son («rechazadas por los argumentos»), y esa cuenta
 * es el tamaño de lo que todavía depende de la revisión manual.
 *
 * NUNCA contra prod: arma filas (que se deshacen) y corre RPCs de escritura. Se niega si la
 * URL nombra el ref de prod, y exige GATE_DB_CONTENEDOR o GATE_DB_URL (no SUPABASE_DB_URL).
 *
 * Uso local:  GATE_DB_CONTENEDOR=<contenedor con la semilla> node scripts/check-cruce-ids.mjs
 */
import { readFileSync } from 'node:fs';
import { apuntaAProd, destino, psql } from './lib/pg.mjs';

// A propósito no se mira SUPABASE_DB_URL: es la de prod.
const d = destino({ GATE_DB_CONTENEDOR: process.env.GATE_DB_CONTENEDOR, GATE_DB_URL: process.env.GATE_DB_URL });
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR o GATE_DB_URL (una base descartable con las sucursales 1 y 2): el gate no puede mirar.');
  process.exit(2);
}
if (apuntaAProd(d)) {
  console.error('Esta base es la de prod: el gate arma datos y corre RPCs de escritura, y se niega.');
  process.exit(2);
}

const { funciones: permitidas } = JSON.parse(
  readFileSync(new URL('./cruce-ids-permitidas.json', import.meta.url), 'utf8'),
);
const sql = readFileSync(new URL('./gates-sql/cruce-ids-sucursal.sql', import.meta.url), 'utf8').replaceAll('\r\n', '\n');

let mensaje = '';
try {
  psql(sql, { destino: d });
  mensaje = 'el guion terminó sin su excepción final';
} catch (e) {
  mensaje = String(e.message);
}
const m = /GATE_RESULT:(\{.*\})/s.exec(mensaje);
if (!m) {
  console.error(`El gate no pudo correr: ${mensaje}`);
  process.exit(2);
}
const r = JSON.parse(m[1]);

console.log(`Cruce por ids de otra sucursal (${d.descripcion})`);
console.log(
  `RPCs con un id de pedido, cliente, pago o compra: ${r.funciones} | llamadas (5 roles de A, y el admin con la cabecera de B): ${r.probadas}\n` +
    `  rechazadas por permiso o sucursal: ${r.rechazadas_por_acceso} | rechazadas antes, por los argumentos de relleno: ${r.rechazadas_por_los_argumentos} | aceptadas sin tocar ni mostrar nada de B: ${r.aceptadas}`,
);
if (!r.funciones) {
  console.error('\nNo probó ninguna función: el gate no puede mirar.');
  process.exit(2);
}

const porFirma = new Map();
for (const h of r.hallazgos) {
  if (!porFirma.has(h.firma)) porFirma.set(h.firma, []);
  porFirma.get(h.firma).push(h);
}
const sinPermiso = [...porFirma].filter(([firma]) => !Object.hasOwn(permitidas, firma));
const sobrantes = Object.keys(permitidas).filter((firma) => !porFirma.has(firma));

if (sobrantes.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (rechazan, o la función no existe más): sacalas del JSON.');
  for (const f of sobrantes) console.log(`  ${f}  (${permitidas[f]})`);
}

if (sinPermiso.length) {
  console.error('\n❌ RPCs que, llamadas desde la sucursal 1 con ids de la sucursal 2, no se rechazan:');
  for (const [firma, hs] of sinPermiso) {
    console.error(`  ${firma}`);
    for (const h of hs) console.error(`      ${h.actor} (cabecera de la sucursal ${h.cabecera}): ${h.que}`);
  }
  console.error(
    '\n   Arreglo: acotar el id a la sucursal activa (cliente_id/pedido_id/… con sucursal_id =\n' +
      '   current_sucursal_id()) antes de leer o escribir, y rechazar con 42501 si no coincide.\n' +
      '   Si cruza sucursales a propósito, sumala a scripts/cruce-ids-permitidas.json con el motivo.',
  );
  process.exit(1);
}

console.log('\n✅ Ninguna RPC con un id de pedido, cliente, pago o compra de otra sucursal lo acepta (salvo las permitidas).');
