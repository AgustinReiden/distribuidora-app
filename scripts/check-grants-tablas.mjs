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
 *   · el default de postgres en public le concede algo a anon, escritura a
 *     authenticated, o cualquier cosa sobre secuencias a authenticated;
 *   · (#1151) authenticated lee una tabla sin ninguna policy de SELECT que le
 *     aplique (select_sin_policy);
 *   · (#1151) hay una policy con rol PUBLIC (policies_public);
 *   · (#1151) las secuencias de authenticated no son exactamente las del JSON
 *     («secuencias») con USAGE, en las dos direcciones, o tiene SELECT/UPDATE
 *     (setval) en alguna;
 *   · (#1151) una policy de escritura (o FOR ALL) sobre una tabla sin ningún
 *     grant de esa escritura: el catálogo miente.
 * Informativo (no rompe): el default de supabase_admin, que no se puede
 * cambiar desde postgres.
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
  if (d.grantee === 'authenticated' && d.objtipo === 'S') {
    errores.push(
      `el default de postgres en public le concede ${d.privilegio} en secuencias a authenticated: ` +
        'una secuencia nueva nace sin nada y su migración concede USAGE si hace falta',
    );
  }
}

// #1151 · Tablas que authenticated lee sin ninguna policy de SELECT: hoy dan 0
// filas, pero una policy nueva las abre. Si la tabla es de otra migración, la
// salida es suya.
if (!Array.isArray(r.select_sin_policy) || !Array.isArray(r.policies_public) || !Array.isArray(r.authenticated_secuencias)) {
  errores.push(
    'auditoria_grants_tablas() no devuelve select_sin_policy / policies_public / authenticated_secuencias: ' +
      'falta aplicar la migración de #1151',
  );
}
for (const t of r.select_sin_policy ?? []) {
  errores.push(
    `authenticated lee ${t} y ninguna policy de SELECT le aplica: crearle una policy FOR SELECT TO authenticated ` +
      `o REVOKE SELECT ON public.${t} FROM authenticated en su migración`,
  );
}

// #1151 · Una policy sin TO es de PUBLIC (o sea, también de anon).
for (const p of r.policies_public ?? []) {
  errores.push(`la policy ${p.tabla}.${p.policy} (${p.cmd}) es TO public: va TO authenticated`);
}

// #1151 · Secuencias: USAGE exactamente en las del JSON, y nada más.
const seqJson = new Set(esperado.secuencias ?? []);
const seqUsage = new Set();
for (const s of r.authenticated_secuencias ?? []) {
  if (s.privilegio === 'USAGE') seqUsage.add(s.secuencia);
  else errores.push(`authenticated tiene ${s.privilegio} sobre la secuencia ${s.secuencia}: alcanza USAGE`);
}
for (const s of seqUsage) {
  if (!seqJson.has(s)) errores.push(`authenticated tiene USAGE sobre ${s} y scripts/grants-rest.json («secuencias») no la lista`);
}
for (const s of Array.isArray(r.authenticated_secuencias) ? seqJson : []) {
  if (!seqUsage.has(s)) {
    errores.push(`scripts/grants-rest.json lista la secuencia ${s} y authenticated no tiene USAGE: su INSERT REST va a dar 42501`);
  }
}

// Policies de escritura sobre (tabla, cmd) sin grant: con el grant revocado no
// dejan pasar nada, pero el catálogo miente (desde #1151 es error, no aviso).
for (const p of r.policies_escritura ?? []) {
  const privs = p.cmd === 'ALL' ? ['INSERT', 'UPDATE', 'DELETE'] : [p.cmd];
  const sinGrant = privs.filter((priv) => !prod.has(`${p.tabla}.${priv}`));
  if (sinGrant.length === privs.length) {
    errores.push(`policy ${p.tabla}.${p.policy} (${p.cmd}) sobre escrituras sin grant: borrarla, o pasarla a FOR SELECT si es lectura`);
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
