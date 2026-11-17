#!/usr/bin/env node
/**
 * auditoria_integridad() contra la base LOCAL: falla (exit 1) si hay un check critical o
 * high en rojo. Es la batería 1 de check-integridad.mjs sin el resto (las otras tres
 * necesitan los datos de prod: reportes que cierran, criterio de merma, NaN en filas).
 * Sobre la base de un PR (esquema de prod + sus migraciones, sin datos) sirve para lo
 * ESTRUCTURAL: STK-F, PRECIO-A, COSTO-D, SEG-A, SEG-B, REPORTE-A… (funciones que se
 * abren sin su guarda, sin su etiqueta o sin su piso).
 *
 * Requiere GATE_DB_CONTENEDOR o GATE_DB_URL (scripts/lib/pg.mjs). Nunca prod.
 */
import { apuntaAProd, destino, consultaJson } from '../lib/pg.mjs';

const d = destino({ GATE_DB_CONTENEDOR: process.env.GATE_DB_CONTENEDOR, GATE_DB_URL: process.env.GATE_DB_URL });
if (!d) {
  console.error('Falta GATE_DB_CONTENEDOR o GATE_DB_URL: no hay base local a la que preguntar.');
  process.exit(2);
}
if (apuntaAProd(d)) {
  console.error('Esta base es la de prod: este script es para la base local de un PR.');
  process.exit(2);
}

const r = consultaJson('SELECT public.auditoria_integridad()', { destino: d });
const checks = Array.isArray(r.checks) ? r.checks : [];
if (!checks.length) {
  console.error('auditoria_integridad() no devolvió checks: el gate no puede mirar.');
  process.exit(2);
}
const enRojo = checks.filter((c) => !c.ok);
console.log(`Auditoría de integridad (${d.descripcion}) @ ${r.generado_at}`);
console.log(`Checks: ${r.total_checks} | con violaciones: ${r.con_violaciones} | critical/high en rojo: ${r.critical_high_en_rojo}`);
for (const c of enRojo) console.log(`  [${c.severidad}] ${c.id} = ${c.violaciones} — ${c.descripcion}`);

if ((r.critical_high_en_rojo ?? 0) > 0) {
  console.error('\n❌ Hay checks critical/high en rojo sobre la base local.');
  process.exit(1);
}
console.log('\n✅ Ningún check critical/high en rojo.');
