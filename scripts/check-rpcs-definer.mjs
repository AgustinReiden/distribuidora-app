#!/usr/bin/env node
/**
 * Gate de las RPCs SECURITY DEFINER que reciben un usuario o una sucursal (#1291).
 * Llama al RPC auditoria_rpcs_definer() (migrations/415) vía PostgREST con
 * la service_role key y falla (exit 1) si:
 *
 *   · una RPC alcanzable desde la API escribe la gestión de usuarios
 *     (usuario_sucursales, perfil_roles, perfiles, bot_usuarios,
 *     bot_digest_config) sin acotar al usuario: ni un helper que lo relacione
 *     con las sucursales del que llama (admin_abarca_sucursales_de…), ni todas
 *     sus escrituras sobre auth.uid();
 *   · una RPC usa un parámetro de usuario (uuid) o de sucursal sin que el texto
 *     muestre que lo acota, y no está en scripts/rpcs-definer-permitidas.json.
 *
 * Por qué existe: una función SECURITY DEFINER no pasa por RLS, así que
 * check-rama-admin.mjs no la ve. asignar_usuario_sucursal controlaba que el
 * admin fuera de la sucursal, no que el usuario fuera suyo: el admin de Taco
 * Pozo se traía a uno de Tucumán con su uuid y desde ahí lo veía entero.
 *
 * Qué cuenta como acotar (lo decide el RPC, con el parámetro o un alias suyo,
 * `v := p` o `v := COALESCE(p, …)`):
 *   · usuario: pasarlo a admin_abarca_sucursales_de, admin_comparte_sucursal_con,
 *     perfil_de_sucursal_activa o bot_admin_puede_gestionar; compararlo con
 *     auth.uid() (o un alias); o cruzarlo con usuario_sucursales en un statement
 *     que también mira la sucursal activa o al que llama.
 *   · sucursal: compararlo con current_sucursal_id() (o un alias), buscarlo en
 *     un array (= ANY, <@), pasarlo a _tablero_sucursales o
 *     comision_regla_alcanzable, o cruzarlo con usuario_sucursales en un
 *     statement que mira al que llama.
 *
 * Lo que NO ve (es texto, no ejecución):
 *   · Que el array del `= ANY` sea de verdad el de las sucursales del usuario.
 *   · Una comparación con auth.uid() que sólo rige para un rol:
 *     `IF p <> auth.uid() AND NOT es_admin()` deja pasar al admin con cualquier p.
 *   · Un alias de dos saltos, o el parámetro leído por posición ($1).
 *   · Un uuid de usuario cuyo nombre no diga usuario, perfil, preventista,
 *     transportista, vendedor, encargado, admin, chofer o deposito: el usuario
 *     se reconoce por el nombre, no por el tipo (la planilla de
 *     aplicar_control_stock también es uuid). Tampoco una sucursal que no se
 *     llame *sucursal*.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-rpcs-definer.mjs
 */
import { readFileSync } from 'node:fs';
import { hallazgosRpcsDefiner } from './lib/acceso.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const { parametros: permitidas } = JSON.parse(
  readFileSync(new URL('./rpcs-definer-permitidas.json', import.meta.url), 'utf8'),
);

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_rpcs_definer`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_rpcs_definer() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
// Cero funciones, o sin las listas, no es "todo bien": es que el RPC no está
// mirando nada (o es otro).
if (!r.funciones || !Array.isArray(r.gestion_usuarios) || !Array.isArray(r.parametros)) {
  console.error('El RPC auditoria_rpcs_definer() no devolvió funciones: el gate no puede mirar.');
  process.exit(2);
}

const { gestion, parametros, sobrantes } = hallazgosRpcsDefiner(r, permitidas);
const sinAcotar = r.parametros.filter((p) => !p.acotado).length;

console.log(`Auditoría de las RPCs SECURITY DEFINER @ ${r.generado_at}`);
console.log(
  `RPCs alcanzables desde la API: ${r.funciones} | escriben la gestión de usuarios: ${r.gestion_usuarios.length} | ` +
    `parámetros de usuario o sucursal: ${r.parametros.length} (sin acotar: ${sinAcotar}, ` +
    `permitidos: ${sinAcotar - parametros.length})`,
);

if (sobrantes.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (se acotan, o la función no existe más): sacalas del JSON.');
  for (const k of sobrantes) console.log(`  ${k}  (${permitidas[k]})`);
}

let falla = false;

if (gestion.length) {
  console.error('\n❌ RPCs que escriben la gestión de usuarios sin acotar al usuario:');
  for (const g of gestion) console.error(`  ${g.firma}  escribe ${g.tablas.join(', ')}`);
  console.error(
    '\n   Arreglo: pedir admin_abarca_sucursales_de(<usuario>) antes de escribir, como\n' +
      '   asignar_usuario_sucursal; o escribir sólo las filas de auth.uid().',
  );
  falla = true;
}

if (parametros.length) {
  console.error('\n❌ Parámetros de usuario o de sucursal que la RPC usa sin acotar:');
  for (const p of parametros) console.error(`  ${p.firma}  ${p.parametro} (${p.clase})`);
  console.error(
    '\n   Arreglo: acotarlo (admin_comparte_sucursal_con(p), p = current_sucursal_id(),\n' +
      '   p = ANY(_sucursales_red())…). Si ya se acota de una forma que el gate no ve,\n' +
      '   sumalo a scripts/rpcs-definer-permitidas.json con cómo se acota.',
  );
  falla = true;
}

if (falla) process.exit(1);

console.log('\n✅ Ninguna RPC definer usa un usuario o una sucursal sin acotarlo (salvo las permitidas).');
