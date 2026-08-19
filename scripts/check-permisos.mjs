#!/usr/bin/env node
/**
 * Gate de permisos EXECUTE.
 * Llama al RPC auditoria_permisos_execute() (ver migrations/189) vía PostgREST
 * con la service_role key y falla (exit 1) si alguna función del schema public
 * quedó ejecutable por el rol `anon`.
 *
 * Por qué existe: Supabase le concede EXECUTE a `anon` explícitamente en cada
 * función nueva, ADEMÁS del grant implícito a PUBLIC. Revocar una sola de las
 * dos mitades no cierra nada, y el error es invisible en code review.
 * Ver migrations/README.md § Permisos y la migración 188.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-permisos.mjs
 */
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_permisos_execute`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_permisos_execute() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
const abiertas = r.detalle_anon ?? [];
const sinGuarda = r.detalle_authenticated_sin_guarda ?? [];

console.log(`Auditoría de permisos EXECUTE @ ${r.generado_at}`);
console.log(
  `Funciones en public: ${r.total_funciones} | SECURITY DEFINER: ${r.security_definer} | ` +
    `ejecutables por anon: ${r.expuestas_a_anon}`,
);

if (abiertas.length) {
  console.log('\nEjecutables por anon:');
  for (const f of abiertas) {
    const flags = [
      f.security_definer ? 'DEFINER' : 'invoker',
      f.menciona_guarda ? 'con guarda' : 'SIN GUARDA',
      f.escribe ? 'ESCRIBE' : 'sólo lee',
    ].join(', ');
    console.log(`  ${f.firma}  (${flags})`);
    console.log(`      acl: ${f.acl}`);
  }
}

// Riesgo residual, informativo: un usuario logueado puede invocarlas directo y
// la función no chequea nada por sí misma. No rompe el gate — es la cola de
// revisión que queda después de la 188.
if (sinGuarda.length) {
  console.log(
    `\nℹ️  ${sinGuarda.length} función(es) SECURITY DEFINER sin gate propio alcanzables por ` +
      'authenticated (no rompe el gate, es backlog de revisión):',
  );
  for (const f of sinGuarda.slice(0, 15)) {
    console.log(`  ${f.firma}${f.escribe ? '  [escribe]' : ''}`);
  }
  if (sinGuarda.length > 15) console.log(`  … y ${sinGuarda.length - 15} más.`);
}

if ((r.expuestas_a_anon ?? 0) > 0) {
  console.error(
    `\n❌ ${r.expuestas_a_anon} función(es) del schema public son ejecutables con la anon key.\n` +
      '   Arreglo: REVOKE EXECUTE ON FUNCTION <firma> FROM PUBLIC, anon;  ← las DOS mitades.\n' +
      '   Ver migrations/README.md § Permisos.',
  );
  process.exit(1);
}

console.log('\n✅ Ninguna función de public es ejecutable por anon.');
