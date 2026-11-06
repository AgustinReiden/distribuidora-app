#!/usr/bin/env node
/**
 * Gate de las RPCs SECURITY DEFINER que reciben un usuario o una sucursal (#1291),
 * o que tocan una tabla con sucursal (#1438).
 * Llama al RPC auditoria_rpcs_definer() (migrations/415, 418 y la de #1438) vía
 * PostgREST con la service_role key y falla (exit 1) si:
 *
 *   · una RPC alcanzable desde la API escribe la gestión de usuarios
 *     (usuario_sucursales, perfil_roles, perfiles, bot_usuarios,
 *     bot_digest_config) sin acotar al usuario: ni un helper que lo relacione
 *     con las sucursales del que llama (admin_abarca_sucursales_de…), ni todas
 *     sus escrituras sobre auth.uid();
 *   · una RPC usa un parámetro de usuario (uuid) o de sucursal sin que el texto
 *     muestre que lo acota, y no está en scripts/rpcs-definer-permitidas.json
 *     ("parametros"), que va por firma (#1374);
 *   · una RPC lee o escribe (FROM, JOIN, UPDATE, INTO) una tabla o vista de
 *     public con sucursal_id y su cuerpo no nombra ninguna sucursal
 *     (sucursal_id, current_sucursal_id(), _sucursales_red(), un parámetro o
 *     una variable de sucursal), y no está en la misma lista ("tablas", por
 *     firma). actualizar_precios_masivo cambiaba precios de otra sucursal así:
 *     recibía ids de producto, no una sucursal;
 *   · una RPC compara current_sucursal_id() (o un alias) con `<>`, `!=` o
 *     NOT IN sin chequear antes su IS NULL, o _rol_en_sucursal(…) con `<>`,
 *     `!=` o NOT IN sin COALESCE ("guardas_nulas", #1488). Con NULL el IF no
 *     corta: los movimientos entre sucursales dejaban pasar así a un usuario de
 *     otra sucursal y a un desactivado. No tiene lista de permitidas.
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
 *   · Que nombrar la sucursal sea acotarla: alcanza con que aparezca en el
 *     cuerpo (hasta en un mensaje de error). Lo que ve es la definer que se
 *     olvidó de la sucursal entera. Tampoco ve una tabla que se toca por SQL
 *     dinámico (EXECUTE) o a través de otra función.
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

const { parametros: permitidas, tablas: tablasPermitidas } = JSON.parse(
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
if (
  !r.funciones ||
  !Array.isArray(r.gestion_usuarios) ||
  !Array.isArray(r.parametros) ||
  !Array.isArray(r.tablas_sucursal) ||
  !Array.isArray(r.guardas_nulas)
) {
  console.error('El RPC auditoria_rpcs_definer() no devolvió funciones: el gate no puede mirar.');
  process.exit(2);
}

const { gestion, parametros, sobrantes, tablas, sobrantesTablas, guardas } = hallazgosRpcsDefiner(
  r,
  permitidas,
  tablasPermitidas,
);
const sinAcotar = r.parametros.filter((p) => !p.acotado).length;
const sinSucursal = r.tablas_sucursal.filter((t) => !t.nombra_sucursal).length;

console.log(`Auditoría de las RPCs SECURITY DEFINER @ ${r.generado_at}`);
console.log(
  `RPCs alcanzables desde la API: ${r.funciones} | escriben la gestión de usuarios: ${r.gestion_usuarios.length} | ` +
    `parámetros de usuario o sucursal: ${r.parametros.length} (sin acotar: ${sinAcotar}, ` +
    `permitidos: ${sinAcotar - parametros.length}) | tocan una tabla con sucursal: ${r.tablas_sucursal.length} ` +
    `(sin nombrarla: ${sinSucursal}, permitidas: ${sinSucursal - tablas.length}) | ` +
    `guardas que fallan abiertas con NULL: ${guardas.length}`,
);

if (sobrantes.length || sobrantesTablas.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (se acotan, o la función no existe más): sacalas del JSON.');
  for (const k of sobrantes) console.log(`  parametros: ${k}  (${permitidas[k]})`);
  for (const k of sobrantesTablas) console.log(`  tablas: ${k}  (${tablasPermitidas[k]})`);
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
      '   sumalo a scripts/rpcs-definer-permitidas.json como firma.parametro, con cómo\n' +
      '   se acota.',
  );
  falla = true;
}

if (tablas.length) {
  console.error('\n❌ RPCs que leen o escriben una tabla con sucursal sin nombrar ninguna sucursal:');
  for (const t of tablas) console.error(`  ${t.firma}  toca ${t.tablas.join(', ')}`);
  console.error(
    '\n   Arreglo: acotar a la sucursal, como la policy de la tabla (sucursal_id =\n' +
      '   current_sucursal_id(), sucursal_id = ANY(_sucursales_red())…), o sacarla de la\n' +
      '   API (REVOKE ... FROM PUBLIC, anon, authenticated) si sólo la usa el servidor.\n' +
      '   Si ya se acota de otra forma (al que llama, por un helper) o es global a\n' +
      '   propósito, sumala a "tablas" de scripts/rpcs-definer-permitidas.json con su firma\n' +
      '   y el motivo.',
  );
  falla = true;
}

if (guardas.length) {
  console.error('\n❌ RPCs con una guarda que no corta cuando la sucursal o el rol dan NULL:');
  for (const g of guardas) console.error(`  ${g.firma}`);
  console.error(
    '\n   Arreglo: rechazar primero si current_sucursal_id() IS NULL y comparar con\n' +
      "   IS DISTINCT FROM; el rol, con COALESCE(_rol_en_sucursal(…), '') NOT IN (…).\n" +
      '   Como los movimientos entre sucursales (mig 469, #1488).',
  );
  falla = true;
}

if (falla) process.exit(1);

console.log(
  '\n✅ Ninguna RPC definer usa un usuario o una sucursal sin acotarlo, ni toca una tabla con sucursal sin nombrarla (salvo las permitidas),' +
    ' ni tiene una guarda que falle abierta con NULL.',
);
