#!/usr/bin/env node
/**
 * Gate del día argentino (#1250, ampliado en #1298).
 * Llama al RPC auditoria_fechas_utc() (ver migrations/410 y la de #1298) vía
 * PostgREST con la service_role key y falla (exit 1) si alguna función, default
 * de columna, vista, policy o CHECK de `public` usa el día del servidor
 * (CURRENT_DATE, now()::date, date_trunc('day', now()), to_char(now(), …), o
 * los mismos cortes sobre una columna timestamptz) sin estar en
 * scripts/fechas-utc-permitidas.json, o si la lista nombra algo que ya no lo
 * usa. Las funciones se comparan por firma (scripts/lib/fechasUtc.mjs).
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
import { evaluarFechasUtc, hayFallas, seccionesFaltantes, SECCIONES } from './lib/fechasUtc.mjs';

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

// Sin las secciones de #1298 la base corre el gate viejo: lo que no mira no
// puede salir verde.
const faltan = seccionesFaltantes(r);
if (faltan.length) {
  console.error(`auditoria_fechas_utc() no devuelve ${faltan.join(', ')}: falta aplicar la migración de #1298.`);
  process.exit(2);
}

const v = evaluarFechasUtc(r, permitidas);

console.log(`Auditoría del día UTC @ ${r.generado_at}`);
console.log(
  `Funciones miradas: ${r.total_funciones} | ` +
    SECCIONES.map(
      ({ seccion }) => `${seccion}: ${r[seccion].length} (permitidas ${Object.keys(permitidas[seccion] ?? {}).length})`,
    ).join(' | '),
);

const QUE = { funciones: 'función', defaults: 'default', vistas: 'vista', policies: 'policy', checks: 'CHECK' };
for (const { seccion, clave } of SECCIONES) {
  for (const h of v[seccion].nuevas) {
    const detalle = seccion === 'defaults' ? `= ${h.default}` : `(${(h.patrones ?? []).join(', ')})`;
    console.log(`  ❌ ${QUE[seccion]} ${h[clave]}  ${detalle}`);
  }
  for (const k of v[seccion].sobrantes) {
    console.log(`  ⚠️  ${QUE[seccion]} ${k} ya no usa el día UTC y sigue en la lista`);
  }
}

if (hayFallas(v)) {
  if (SECCIONES.some(({ seccion }) => v[seccion].nuevas.length > 0)) {
    console.error(
      '\n❌ Hay funciones, defaults, vistas, policies o CHECKs que usan el día del servidor (UTC):\n' +
        '   entre las 21 y las 24 de Argentina ya es mañana.\n' +
        '   Arreglo: en una función, public._tablero_hoy(); en un default de columna,\n' +
        "   ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date; sobre un timestamptz,\n" +
        "   (x AT TIME ZONE 'America/Argentina/Buenos_Aires')::date.",
    );
  }
  if (SECCIONES.some(({ seccion }) => v[seccion].sobrantes.length > 0)) {
    console.error(
      '\n❌ scripts/fechas-utc-permitidas.json nombra cosas que ya no usan el día UTC.\n' +
        '   Arreglo: sacalas de la lista, para que no puedan volver sin que el gate lo vea.',
    );
  }
  process.exit(1);
}

console.log('\n✅ Nada nuevo usa el día UTC.');
