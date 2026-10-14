#!/usr/bin/env node
/**
 * Gate de grants de TABLA (#1135).
 * Llama al RPC auditoria_grants_tablas() vía PostgREST con la service_role key
 * y compara lo que anon y authenticated tienen en prod contra
 * scripts/grants-rest.json. Falla (exit 1) si:
 *   · anon tiene cualquier privilegio sobre una tabla, vista o secuencia de
 *     public (por tabla o por columna);
 *   · authenticated tiene TRUNCATE, REFERENCES, TRIGGER o MAINTAIN;
 *   · las escrituras (INSERT/UPDATE/DELETE) de authenticated no son exactamente
 *     las del JSON, en las dos direcciones e INCLUIDO EL NIVEL: si un UPDATE
 *     por columnas pasa a tabla entera, o cambian las columnas, se pone rojo;
 *   · hay una tabla sin RLS o una vista sin security_invoker;
 *   · el default de postgres en public le concede algo a anon, o escritura a
 *     authenticated.
 * Informativo (no rompe): las policies de escritura sobre tablas sin grant
 * (las FOR ALL que también son el SELECT de alguien) y el default de
 * supabase_admin, que no se puede cambiar desde postgres.
 *
 * Por qué existe: el baseline le hizo GRANT ALL a anon y authenticated en cada
 * tabla, y lo único que frenaba la escritura REST eran las policies: por ahí se
 * podía falsear el ledger de stock (#1134), cambiar el monto de un pago o
 * borrar la alícuota vigente de un impuesto interno (#1135). Ver
 * migrations/*_rest_escribe_solo_lo_que_usa.sql y migrations/README.md
 * § Permisos.
 *
 * Su mitad local es src/test/grantsRest.contract.test.ts: que el front no
 * escriba nada fuera del JSON y que ninguna migración nueva conceda de más.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-grants-tablas.mjs
 */
import fs from 'node:fs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const esperado = JSON.parse(fs.readFileSync(new URL('./grants-rest.json', import.meta.url), 'utf8'));

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_grants_tablas`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_grants_tablas() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
const errores = [];
const avisos = [];

// Un nivel se escribe "tabla" o la lista ordenada de columnas.
const nivelTexto = (n) => (Array.isArray(n) ? `columnas(${[...n].sort().join(', ')})` : String(n));

console.log(`Auditoría de grants de tabla @ ${r.generado_at}`);

for (const g of r.anon ?? []) {
  errores.push(`anon tiene ${g.privilegio} sobre ${g.relacion} (${nivelTexto(g.nivel)})`);
}
for (const g of r.authenticated_extras ?? []) {
  errores.push(`authenticated tiene ${g.privilegio} sobre ${g.relacion}`);
}

// Escrituras: prod (tabla.PRIV → niveles) contra el JSON.
const prod = new Map();
for (const g of r.authenticated_escrituras ?? []) {
  const clave = `${g.tabla}.${g.privilegio}`;
  prod.set(clave, [...(prod.get(clave) ?? []), nivelTexto(g.nivel)]);
}
const json = new Map();
for (const [tabla, privs] of Object.entries(esperado.escrituras)) {
  for (const [priv, nivel] of Object.entries(privs)) json.set(`${tabla}.${priv}`, [nivelTexto(nivel)]);
}
for (const [clave, niveles] of prod) {
  if (!json.has(clave)) {
    errores.push(`authenticated tiene ${clave} (${niveles.join(' + ')}) y scripts/grants-rest.json no lo lista`);
  } else if (niveles.length > 1) {
    errores.push(`${clave} está concedido a la vez por tabla y por columnas (${niveles.join(' + ')})`);
  } else if (niveles[0] !== json.get(clave)[0]) {
    errores.push(`${clave}: en prod es ${niveles[0]}, el JSON dice ${json.get(clave)[0]}`);
  }
}
for (const [clave, niveles] of json) {
  if (!prod.has(clave)) {
    errores.push(`scripts/grants-rest.json lista ${clave} (${niveles[0]}) y authenticated no lo tiene: el front o un trigger va a dar 42501`);
  }
}

for (const t of r.sin_rls ?? []) errores.push(`la tabla ${t} no tiene RLS`);
for (const v of r.vistas_sin_invoker ?? []) errores.push(`la vista ${v} no es security_invoker (o es materializada)`);

for (const d of r.default_acl ?? []) {
  const objeto = { r: 'tablas', S: 'secuencias', f: 'funciones', T: 'tipos', n: 'esquemas' }[d.objtipo] ?? d.objtipo;
  if (d.owner !== 'postgres') {
    if (d.grantee === 'anon' || d.grantee === 'PUBLIC') {
      avisos.push(`default de ${d.owner}: ${d.privilegio} en ${objeto} para ${d.grantee} (no se cambia desde postgres)`);
    }
    continue;
  }
  if ((d.grantee === 'anon' || d.grantee === 'PUBLIC') && (d.objtipo === 'r' || d.objtipo === 'S')) {
    errores.push(`el default de postgres en public le concede ${d.privilegio} en ${objeto} a ${d.grantee}`);
  }
  if (d.grantee === 'authenticated' && d.objtipo === 'r' && d.privilegio !== 'SELECT') {
    errores.push(`el default de postgres en public le concede ${d.privilegio} en tablas a authenticated`);
  }
}

// Policies de escritura sobre (tabla, cmd) sin grant: con el grant revocado no
// dejan pasar nada, pero el catálogo miente. Las FOR ALL son esperables.
for (const p of r.policies_escritura ?? []) {
  const privs = p.cmd === 'ALL' ? ['INSERT', 'UPDATE', 'DELETE'] : [p.cmd];
  const sinGrant = privs.filter((priv) => !prod.has(`${p.tabla}.${priv}`));
  if (sinGrant.length === privs.length) {
    avisos.push(`policy ${p.tabla}.${p.policy} (${p.cmd}) sobre escrituras sin grant`);
  }
}

console.log(`Escrituras de authenticated: ${prod.size} | en el JSON: ${json.size}`);

if (avisos.length) {
  console.log('\nInformativo:');
  for (const a of avisos) console.log(`  · ${a}`);
}

if (errores.length) {
  console.error(`\n❌ ${errores.length} problema(s) de grants de tabla:`);
  for (const e of errores) console.error(`  ${e}`);
  console.error(
    '\n   Una escritura REST nueva se concede con el privilegio exacto (por columna si alcanza)\n' +
      '   en una migración y se suma a scripts/grants-rest.json en el mismo PR. Nunca a anon.\n' +
      '   Ver migrations/README.md § Permisos.',
  );
  process.exit(1);
}

console.log('\n✅ anon sin nada; authenticated escribe exactamente lo de scripts/grants-rest.json.');
