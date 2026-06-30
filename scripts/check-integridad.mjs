#!/usr/bin/env node
/**
 * Gate de integridad de datos.
 * Llama al RPC auditoria_integridad() (ver migrations/105) vía PostgREST con la
 * service_role key y falla (exit 1) si hay algún check critical/high en rojo.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-integridad.mjs
 */
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_integridad`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_integridad() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
const checks = Array.isArray(r.checks) ? r.checks : [];
const enRojo = checks.filter((c) => !c.ok);

console.log(`Auditoría de integridad @ ${r.generado_at}`);
console.log(
  `Checks: ${r.total_checks} | con violaciones: ${r.con_violaciones} | critical/high en rojo: ${r.critical_high_en_rojo}`,
);
if (enRojo.length) {
  console.log('\nEn rojo:');
  for (const c of enRojo) {
    console.log(`  [${c.severidad}] ${c.id} = ${c.violaciones} — ${c.descripcion}`);
  }
}

if ((r.critical_high_en_rojo ?? 0) > 0) {
  console.error(`\n❌ Hay ${r.critical_high_en_rojo} check(s) critical/high en rojo. Revisar antes de presentar números.`);
  process.exit(1);
}

console.log('\n✅ Sin checks critical/high en rojo. Integridad OK.');
