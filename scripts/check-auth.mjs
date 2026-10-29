#!/usr/bin/env node
/**
 * Gate de Auth (#1243).
 * Falla (exit 1) si:
 *   · el signup está abierto: GET /auth/v1/settings dice disable_signup: false,
 *     o los usuarios anónimos están habilitados;
 *   · un trigger de auth.users lee el metadata que escribe el propio usuario
 *     (raw_user_meta_data) para algo que no sea el nombre. Lo lee del RPC
 *     auditoria_auth() (migrations/403b).
 *
 * Por qué existe: el signup por email estaba abierto en prod y
 * handle_new_user() tomaba el rol y la sucursal de raw_user_meta_data. Con la
 * anon key, que viaja en el bundle, cualquiera se registraba como admin de la
 * sucursal que quisiera. Un proyecto nuevo de Supabase nace con el signup
 * abierto, así que el fork lo va a heredar si nadie lo mira.
 *
 * Cómo se cierra el signup: panel de Supabase, Authentication → Sign In /
 * Providers → "Allow new users to sign up" en off. Las altas desde el panel y
 * por la admin API siguen andando. El rol y la sucursal del alta van en
 * app_metadata (ver migrations/403b).
 *
 * Lo que NO ve: lo que haga una función que el trigger llama (sólo lee el
 * cuerpo de la función del trigger); la protección contra contraseñas
 * filtradas, que no sale en /auth/v1/settings y es de los planes pagos.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-auth.mjs
 */
import { lecturasDeMetadataDelUsuario, problemasDeSignup } from './lib/acceso.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const base = url.replace(/\/$/, '');

const resSettings = await fetch(`${base}/auth/v1/settings`, { headers: { apikey: key } });
if (!resSettings.ok) {
  console.error(`GET /auth/v1/settings falló: HTTP ${resSettings.status}\n${await resSettings.text()}`);
  process.exit(2);
}
const settings = await resSettings.json();

const resRpc = await fetch(`${base}/rest/v1/rpc/auditoria_auth`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});
if (!resRpc.ok) {
  console.error(`El RPC auditoria_auth() falló: HTTP ${resRpc.status}\n${await resRpc.text()}`);
  process.exit(2);
}
const r = await resRpc.json();
const triggers = r.triggers_auth_users ?? [];

console.log(`Auditoría de Auth @ ${r.generado_at}`);
console.log(
  `Signup: ${settings.disable_signup === true ? 'cerrado' : 'ABIERTO'} | ` +
    `anónimos: ${settings.external?.anonymous_users === true ? 'SÍ' : 'no'} | ` +
    `triggers en auth.users: ${triggers.length}`,
);

const fallas = problemasDeSignup(settings);
for (const t of triggers) {
  const lecturas = lecturasDeMetadataDelUsuario(t.cuerpo);
  console.log(`  ${t.trigger} → ${t.funcion}${t.habilitado ? '' : ' (deshabilitado)'}`);
  for (const l of lecturas) {
    fallas.push(`${t.funcion} (trigger ${t.trigger}) lee el metadata del usuario: ${l}`);
  }
}

if (fallas.length) {
  console.error('\n❌ Auth deja que el usuario decida sus propios permisos:');
  for (const f of fallas) console.error(`   · ${f}`);
  console.error(
    '\n   Signup: panel → Authentication → Sign In / Providers → "Allow new users to sign up" en off.\n' +
      '   Trigger: el rol y la sucursal salen de raw_app_meta_data (migrations/403b), nunca de\n' +
      '   raw_user_meta_data, que lo escribe el que se registra.',
  );
  process.exit(1);
}

console.log('\n✅ El signup está cerrado y ningún trigger de auth.users le cree al usuario.');
