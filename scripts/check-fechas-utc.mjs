#!/usr/bin/env node
/**
 * Gate del día argentino (#1250).
 * Llama al RPC auditoria_fechas_utc() (ver migrations/410) vía PostgREST con la
 * service_role key y falla (exit 1) si alguna función o default de columna de
 * `public` usa el día del servidor (CURRENT_DATE, LOCALTIMESTAMP, now()::date…)
 * sin estar en scripts/fechas-utc-permitidas.json, o si la lista nombra algo que
 * ya no lo usa.
 *
 * Por qué existe: la base corre en UTC, y entre las 21 y las 24 de Argentina
 * CURRENT_DATE ya es mañana. La mora, las alertas, la antigüedad de deuda y las
 * metas corrían un día de noche sin que fallara nada (#1250). El día argentino es
 * `_tablero_hoy()`; en un default de columna, el mismo
 * `(now() AT TIME ZONE 'America/Argentina/Tucuman')::date` inline.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-fechas-utc.mjs
 */
import { readFileSync } from 'node:fs';
import { evaluarFechasUtc, hayFallas } from './lib/fechasUtc.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const permitidas = JSON.parse(
  readFileSync(new URL('./fechas-utc-permitidas.json', import.meta.url), 'utf8'),
);

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_fechas_utc`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_fechas_utc() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();

// Un resultado sin funciones mirado sobre cero funciones no es verde: es no
// haber podido mirar.
if (!(r.total_funciones > 0)) {
  console.error('auditoria_fechas_utc() no miró ninguna función: el gate no puede decir nada.');
  process.exit(2);
}

const v = evaluarFechasUtc(r, permitidas);

console.log(`Auditoría del día UTC @ ${r.generado_at}`);
console.log(
  `Funciones miradas: ${r.total_funciones} | con el día UTC: ${r.funciones.length} ` +
    `(permitidas ${Object.keys(permitidas.funciones).length}) | defaults: ${r.defaults.length} ` +
    `(permitidos ${Object.keys(permitidas.defaults).length})`,
);

for (const f of v.funcionesNuevas) {
  console.log(`  ❌ función ${f.firma}  (${f.patrones.join(', ')})`);
}
for (const d of v.defaultsNuevos) {
  console.log(`  ❌ default ${d.columna} = ${d.default}`);
}
for (const n of v.funcionesSobrantes) {
  console.log(`  ⚠️  ${n} ya no usa el día UTC y sigue en la lista`);
}
for (const c of v.defaultsSobrantes) {
  console.log(`  ⚠️  el default de ${c} ya no usa el día UTC y sigue en la lista`);
}

if (hayFallas(v)) {
  if (v.funcionesNuevas.length || v.defaultsNuevos.length) {
    console.error(
      '\n❌ Hay funciones o defaults que usan el día del servidor (UTC): entre las 21 y las 24 de\n' +
        '   Argentina ya es mañana.\n' +
        '   Arreglo: en una función, public._tablero_hoy(); en un default de columna,\n' +
        "   ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date.",
    );
  }
  if (v.funcionesSobrantes.length || v.defaultsSobrantes.length) {
    console.error(
      '\n❌ scripts/fechas-utc-permitidas.json nombra cosas que ya no usan el día UTC.\n' +
        '   Arreglo: sacalas de la lista, para que no puedan volver sin que el gate lo vea.',
    );
  }
  process.exit(1);
}

console.log('\n✅ Nada nuevo usa el día UTC.');
