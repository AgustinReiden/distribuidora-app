#!/usr/bin/env node
/**
 * Gate de los permisos que leen el rol sin mirar `activo` (#1490).
 * Llama al RPC auditoria_rol_sin_activo() (migrations/471) vía PostgREST con
 * la service_role key y falla (exit 1) si una función de public ejecutable por
 * authenticated lee perfiles.rol de quien llama —auth.uid(), o un alias de un
 * salto como `v_uid := auth.uid()`— en una sentencia que no nombra `activo`, y no
 * está en scripts/rol-sin-activo-permitidas.json.
 *
 * Por qué existe: el ban de Auth no invalida un access token ya emitido, así que
 * un desactivado sigue llamando RPCs hasta que le vence. La 463 (#1474) hizo que
 * es_admin(), es_encargado_o_admin(), es_preventista(), es_transportista() y
 * current_sucursal_id() den false/NULL para perfiles.activo = false, pero 22
 * RPCs leían el rol a pelo: un admin dado de baja seguía viendo /reportes y
 * cargando metas.
 *
 * Desde la migración de B9 del plan #1603 (1564-b11) mira también las policies
 * (de cualquier esquema): una subconsulta sobre perfiles que lee el rol de
 * auth.uid() sin `activo` es rojo, sin lista de permitidas. La protección que
 * tenían (current_sucursal_id() da NULL para un desactivado) era indirecta.
 *
 * Arreglo: decidir el permiso con los helpers de la 463, o sumar
 * `AND COALESCE(activo, true)` a la lectura. La lista blanca es para las que ya
 * rechazan a un desactivado por otro lado (current_sucursal_id() NULL antes de
 * leer o escribir, bot_admin_puede_gestionar()…), con cómo; sólo se achica.
 *
 * Las funciones SIN EXECUTE para authenticated (las `_impl` de los pagos y de la nota de
 * crédito, que llama su wrapper DEFINER) no entran en el RPC: leían el rol sin activo y
 * ningún gate las miraba (#1595, 1595-b4). El complemento corre la misma consulta sobre
 * ellas leyendo el catálogo directo (GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL; sin
 * conexión se avisa y queda sólo la parte del RPC), con su propia lista de permitidas
 * ("impl" en scripts/rol-sin-activo-permitidas.json), que también sólo se achica.
 *
 * Lo que NO ve (es texto, no ejecución):
 *   · Un alias de dos saltos, o el usuario que llega como parámetro.
 *   · SQL dinámico (EXECUTE), ni un `;` dentro de un literal $…$.
 *   · Que el "otro lado" de una permitida siga frenando: eso lo prueba el
 *     caso E de scripts/test-desactivado-sin-rol-1490.sql.
 *   · El rol leído de perfil_roles, o el que da _rol_en_sucursal(uid, suc): es
 *     perfiles.rol desde la 486, pero el usuario le llega como parámetro.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-rol-sin-activo.mjs
 */
import { readFileSync } from 'node:fs';
import { hallazgosRolSinActivo, policiesRolSinActivo } from './lib/acceso.mjs';
import { SQL_ROL_SIN_ACTIVO_SIN_API } from './lib/catalogo.mjs';
import { consultaJson, destino } from './lib/pg.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const { funciones: permitidas, impl: permitidasImpl = {} } = JSON.parse(
  readFileSync(new URL('./rol-sin-activo-permitidas.json', import.meta.url), 'utf8'),
);

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_rol_sin_activo`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_rol_sin_activo() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
// Cero funciones no es "todo bien": es que el RPC no está mirando nada (o es otro).
if (!r.funciones || !Array.isArray(r.lecturas)) {
  console.error('El RPC auditoria_rol_sin_activo() no devolvió funciones: el gate no puede mirar.');
  process.exit(2);
}

const { sinActivo, sobrantes } = hallazgosRolSinActivo(r, permitidas);
const policies = policiesRolSinActivo(r);
const marcadas = new Set(r.lecturas.map((l) => l.firma)).size;

console.log(`Auditoría del rol sin activo @ ${r.generado_at}`);
console.log(
  `Funciones de la API que leen perfiles: ${r.funciones} | leen el rol de quien llama sin activo: ${marcadas} ` +
    `(permitidas: ${marcadas - sinActivo.length})`,
);

// Complemento: las que no tienen EXECUTE para authenticated (se llaman desde un wrapper).
let implSinActivo = [];
let implSobrantes = [];
if (destino()) {
  const impl = consultaJson(SQL_ROL_SIN_ACTIVO_SIN_API);
  ({ sinActivo: implSinActivo, sobrantes: implSobrantes } = hallazgosRolSinActivo(impl, permitidasImpl));
  const marcadasImpl = new Set(impl.lecturas.map((l) => l.firma)).size;
  console.log(
    `Funciones sin API que leen perfiles: ${impl.funciones} | leen el rol sin activo: ${marcadasImpl} ` +
      `(permitidas: ${marcadasImpl - implSinActivo.length})`,
  );
} else {
  console.log(
    '\nℹ️  Sin GATE_DB_CONTENEDOR / GATE_DB_URL / SUPABASE_DB_URL: se omite el complemento de las funciones sin API (_impl).',
  );
}

if (sobrantes.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (miran activo, o la función no existe más): sacalas del JSON.');
  for (const f of sobrantes) console.log(`  ${f}  (${permitidas[f]})`);
}
if (implSobrantes.length) {
  console.log('\nℹ️  Permitidas de "impl" que ya no hacen falta (miran activo, o la función no existe más): sacalas del JSON.');
  for (const f of implSobrantes) console.log(`  ${f}  (${permitidasImpl[f]})`);
}

if (policies === null) {
  console.log('\nℹ️  El RPC todavía no mira las policies (es de antes de la migración de B9 del plan #1603).');
} else {
  console.log(`Policies que leen el rol de quien llama sin activo: ${policies.length}`);
}

if (policies?.length) {
  console.error('\n❌ Policies que deciden por el rol de quien llama sin mirar si está activo:');
  for (const p of policies) {
    console.error(`  ${p.policy}`);
    for (const l of p.lecturas) console.error(`      ${l}`);
  }
  console.error(
    '\n   Arreglo: usar es_admin() / es_encargado_o_admin(), o sumar AND COALESCE(activo, true)\n' +
      '   a la subconsulta sobre perfiles. Las policies no tienen lista de permitidas.',
  );
}

if (sinActivo.length || implSinActivo.length) {
  console.error('\n❌ Funciones que deciden por el rol de quien llama sin mirar si está activo:');
  for (const h of [...sinActivo, ...implSinActivo]) {
    console.error(`  ${h.firma}`);
    for (const l of h.lecturas) console.error(`      ${l}`);
  }
  console.error(
    '\n   Arreglo: usar es_admin() / es_encargado_o_admin() (miran activo desde la 463), o\n' +
      '   sumar AND COALESCE(activo, true) a la lectura. Un desactivado conserva su token\n' +
      '   hasta que vence: el ban de Auth no lo invalida.',
  );
}

if (sinActivo.length || implSinActivo.length || policies?.length) process.exit(1);

console.log(
  '\n✅ Ninguna función de la API ni sin API (salvo las permitidas) ni ninguna policy decide por el rol de quien llama sin mirar activo.',
);
