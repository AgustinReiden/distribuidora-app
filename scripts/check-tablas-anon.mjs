#!/usr/bin/env node
/**
 * Gate de lectura anónima sobre TABLAS.
 * Llama al RPC auditoria_tablas_anon() (ver migrations/228) vía PostgREST con
 * la service_role key y falla (exit 1) si alguna tabla del schema public
 * devuelve filas con la anon key.
 *
 * Por qué existe: el hermano `check-permisos.mjs` mira sólo FUNCIONES. Durante
 * meses `perfiles` fue legible sin loguearse —la policy `perfiles_select_all`
 * nació sin cláusula TO, así que aplicaba a PUBLIC, y el baseline le hace
 * GRANT ALL a anon— y ningún check dijo nada: los 17 empleados con nombre,
 * email y rol salían con la anon key que viaja en el bundle. Ver migrations/228.
 *
 * El RPC no lo deduce del catálogo: se pone el sombrero de `anon` y hace el
 * SELECT. Un check estático marcaría en rojo para siempre policies como
 * `USING (auth.uid() IS NOT NULL)`, que aplican a PUBLIC y no filtran nada.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-tablas-anon.mjs
 */
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_tablas_anon`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_tablas_anon() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
const legibles = r.detalle_legibles ?? [];

console.log(`Auditoría de lectura anónima @ ${r.generado_at}`);
console.log(`Tablas en public: ${r.total_tablas} | legibles con la anon key: ${r.legibles_anon}`);

if (legibles.length) {
  console.log('\nLegibles por anon:');
  for (const t of legibles) console.log(`  ${t.tabla}`);
}

if ((r.legibles_anon ?? 0) > 0) {
  console.error(
    `\n❌ ${r.legibles_anon} tabla(s) del schema public devuelven filas con la anon key.\n` +
      '   Arreglo: sacarle la policy permisiva que aplica a PUBLIC/anon Y revocar el grant\n' +
      '   (REVOKE SELECT ON <tabla> FROM anon) — las DOS mitades, como en las funciones.\n' +
      '   Ver migrations/228 y migrations/README.md § Permisos.',
  );
  process.exit(1);
}

console.log('\n✅ Ninguna tabla de public es legible con la anon key.');
