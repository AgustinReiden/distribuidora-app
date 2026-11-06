#!/usr/bin/env node
/**
 * Gate de los permisos que leen el rol sin mirar `activo` (#1490).
 * Llama al RPC auditoria_rol_sin_activo() (migrations/ de #1490) vía PostgREST con
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
 * Arreglo: decidir el permiso con los helpers de la 463, o sumar
 * `AND COALESCE(activo, true)` a la lectura. La lista blanca es para las que ya
 * rechazan a un desactivado por otro lado (current_sucursal_id() NULL antes de
 * leer o escribir, bot_admin_puede_gestionar()…), con cómo; sólo se achica.
 *
 * Lo que NO ve (es texto, no ejecución):
 *   · Un alias de dos saltos, o el usuario que llega como parámetro.
 *   · SQL dinámico (EXECUTE), ni un `;` dentro de un literal $…$.
 *   · Que el "otro lado" de una permitida siga frenando: eso lo prueba el
 *     caso E de scripts/test-desactivado-sin-rol-1490.sql.
 *   · El rol leído de usuario_sucursales o perfil_roles (_rol_en_sucursal): no
 *     es perfiles.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-rol-sin-activo.mjs
 */
import { readFileSync } from 'node:fs';
import { hallazgosRolSinActivo } from './lib/acceso.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const { funciones: permitidas } = JSON.parse(
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
const marcadas = new Set(r.lecturas.map((l) => l.firma)).size;

console.log(`Auditoría del rol sin activo @ ${r.generado_at}`);
console.log(
  `Funciones de la API que leen perfiles: ${r.funciones} | leen el rol de quien llama sin activo: ${marcadas} ` +
    `(permitidas: ${marcadas - sinActivo.length})`,
);

if (sobrantes.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (miran activo, o la función no existe más): sacalas del JSON.');
  for (const f of sobrantes) console.log(`  ${f}  (${permitidas[f]})`);
}

if (sinActivo.length) {
  console.error('\n❌ Funciones que deciden por el rol de quien llama sin mirar si está activo:');
  for (const h of sinActivo) {
    console.error(`  ${h.firma}`);
    for (const l of h.lecturas) console.error(`      ${l}`);
  }
  console.error(
    '\n   Arreglo: usar es_admin() / es_encargado_o_admin() (miran activo desde la 463), o\n' +
      '   sumar AND COALESCE(activo, true) a la lectura. Un desactivado conserva su token\n' +
      '   hasta que vence: el ban de Auth no lo invalida.',
  );
  process.exit(1);
}

console.log('\n✅ Ninguna función de la API decide por el rol de quien llama sin mirar activo (salvo las permitidas).');
