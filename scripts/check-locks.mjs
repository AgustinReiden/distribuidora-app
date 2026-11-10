#!/usr/bin/env node
/**
 * Gate de los locks de varias filas sin orden (#1520, gate 4).
 * Llama al RPC auditoria_locks() (la migración de la tarjeta 9 de #1524) vía PostgREST con la service_role key y
 * falla (exit 1) si una función de public toma un lock de fila (FOR UPDATE / NO KEY UPDATE / SHARE / KEY SHARE)
 * sobre varias filas sin ORDER BY, y no está en scripts/locks-permitidas.json.
 *
 * Por qué existe: el orden global de locks es por id ascendente (migrations/CLAUDE.md). Un `PERFORM 1 FROM t
 * WHERE x = … FOR UPDATE` toma las filas en el orden del plan, y contra otro camino que las toma por id es un
 * 40P01. Los arreglos de #1255, #1375 y #1460 los encontró el arnés de concurrencia, uno por uno.
 *
 * El criterio (qué cuenta como una fila, qué consulta lleva cada lock) vive en scripts/lib/locks.mjs, con sus
 * tests en src/test/locks.test.ts. La lista blanca va por firma, con su motivo, y sólo se achica (lo fija el
 * mismo test): una función nueva ordena, no se suma.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-locks.mjs
 */
import { readFileSync } from 'node:fs';
import { hallazgosLocks } from './lib/locks.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const { funciones: permitidas } = JSON.parse(
  readFileSync(new URL('./locks-permitidas.json', import.meta.url), 'utf8'),
);

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_locks`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_locks() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
// Cero sentencias no es "todo bien": es que el RPC no está mirando nada (o es otro).
if (!r.funciones || !Array.isArray(r.sentencias) || r.sentencias.length === 0) {
  console.error('El RPC auditoria_locks() no devolvió sentencias con lock: el gate no puede mirar.');
  process.exit(2);
}

const { marcadas, sobrantes } = hallazgosLocks(r, permitidas);

console.log(`Auditoría de locks @ ${r.generado_at}`);
console.log(
  `Funciones miradas: ${r.funciones} | sentencias con lock de fila: ${r.sentencias.length} | ` +
    `permitidas: ${Object.keys(permitidas).length - sobrantes.length}`,
);

if (sobrantes.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (ordenan, o la función no existe más): sacalas del JSON.');
  for (const f of sobrantes) console.log(`  ${f}  (${permitidas[f]})`);
}

if (marcadas.length) {
  console.error('\n❌ Funciones que bloquean varias filas sin ORDER BY:');
  for (const m of marcadas) {
    console.error(`  ${m.firma}`);
    for (const s of m.sentencias) console.error(`      ${s.length > 240 ? `…${s.slice(-240)}` : s}`);
  }
  console.error(
    '\n   Arreglo: sumar `ORDER BY id` (o la clave) a la consulta que toma el lock, en el orden global de\n' +
      '   migrations/CLAUDE.md. Si toma una sola fila por otra clave única, sumala a\n' +
      '   scripts/locks-permitidas.json con su motivo.',
  );
  process.exit(1);
}

console.log('\n✅ Ninguna función bloquea varias filas sin ORDER BY (salvo las permitidas).');
