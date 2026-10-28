#!/usr/bin/env node
/**
 * Gate de la rama admin de las policies (#1244).
 * Falla (exit 1) si una policy permisiva de public da acceso por ser admin (o
 * encargado) en una rama que no mira la sucursal. Lee las policies del RPC
 * auditoria_rama_admin() (migrations/404) y decide con scripts/lib/acceso.mjs.
 *
 * Por qué existe: el admin se acotaba a su sucursal en el front y en la
 * mayoría de las policies, pero no en perfiles ni en cliente_descuentos_categoria.
 * El admin de Taco Pozo desactivaba por REST a un usuario de Tucumán. #1074 ya
 * había encontrado la misma clase en avance_metas. Nadie la mira en code review:
 * `USING (es_admin())` se ve correcto.
 *
 * Qué cuenta como rama: los términos unidos por OR en el nivel de afuera. Un
 * término con AND es una rama entera: `es_admin() AND sucursal_id = …` pasa.
 * "Mira la sucursal" es que el texto de la rama nombre algo con `sucursal`:
 * sucursal_id, current_sucursal_id(), cliente_de_sucursal_activa(),
 * admin_comparte_sucursal_con()…
 *
 * Lo que NO ve (es texto, no ejecución):
 *   · Un helper que dice `sucursal` en el nombre y no acota nada.
 *   · Una rama con AND que nombra la sucursal en un OR interno:
 *     `es_admin() AND (x OR sucursal_id = y)` pasa aunque `x` no acote.
 *   · El rol admin pedido de otra forma que es_admin(), es_encargado_o_admin()
 *     o el literal 'admin'.
 *   · Las funciones SECURITY DEFINER, que no pasan por RLS: para eso está
 *     SEG-A de auditoria_integridad().
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-rama-admin.mjs
 */
import { hallazgosRamaAdmin } from './lib/acceso.mjs';

/**
 * Excepciones, por tabla + policy + huella (md5 de `using|check`). Una entrada
 * exime a ESA expresión: si la policy cambia, vuelve a salir en rojo con la
 * huella nueva. Para sacar la huella:
 *   SELECT md5(coalesce(qual,'') || '|' || coalesce(with_check,''))
 *     FROM pg_policies WHERE tablename = '<t>' AND policyname = '<p>';
 */
const EXCEPCIONES = [
  // Globales por diseño: los encuadres de impuestos internos no son de una
  // sucursal (la tabla no tiene sucursal_id) y los edita el admin.
  { tabla: 'ii_encuadres', policy: 'ii_encuadres_insert', huella: '0bcae601192312c63aba2ebc31827615', motivo: 'tabla global' },
  { tabla: 'ii_encuadres', policy: 'ii_encuadres_update', huella: '77e233987c85e988e18df94f4683306d', motivo: 'tabla global' },
  // Pendientes de #1272: las encontró este gate al nacer.
  { tabla: 'cliente_preventistas', policy: 'cp_delete', huella: '004e99e26fd7fc30631b300cfdc132a7', motivo: '#1272' },
  { tabla: 'cliente_preventistas', policy: 'cp_insert', huella: 'b1d05cf3e4b34da57d149a492a16334c', motivo: '#1272' },
  { tabla: 'metas_gerenciales', policy: 'metas_gerenciales_admin_select', huella: '06852a325dfe50c66be752cb475d85f2', motivo: '#1272' },
  { tabla: 'proveedores_eliminados', policy: 'proveedores_eliminados_select_admin', huella: '06852a325dfe50c66be752cb475d85f2', motivo: '#1272' },
  { tabla: 'reportes_mensuales', policy: 'reportes_mensuales_admin_select', huella: '06852a325dfe50c66be752cb475d85f2', motivo: '#1272' },
];

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_rama_admin`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_rama_admin() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
const politicas = r.politicas ?? [];
if (!politicas.length) {
  // Cero policies no es "todo bien": es que el RPC no está mirando nada.
  console.error('El RPC auditoria_rama_admin() no devolvió ninguna policy: el gate no puede mirar.');
  process.exit(2);
}

const { hallazgos, sobrantes } = hallazgosRamaAdmin(politicas, EXCEPCIONES);

console.log(`Auditoría de la rama admin @ ${r.generado_at}`);
console.log(
  `Policies permisivas en public: ${politicas.length} | exceptuadas: ${EXCEPCIONES.length - sobrantes.length} | ` +
    `en rojo: ${hallazgos.length}`,
);

if (sobrantes.length) {
  console.log('\nℹ️  Excepciones que ya no hacen falta (la policy mira la sucursal o no existe): sacalas.');
  for (const e of sobrantes) console.log(`  ${e.tabla} / ${e.policy}  (${e.motivo})`);
}

if (hallazgos.length) {
  console.error('\n❌ Policies con una rama admin que no mira la sucursal:');
  for (const h of hallazgos) {
    console.error(`  ${h.tabla} / ${h.policy} (${h.cmd})  huella ${h.huella}`);
    if (h.excepcionVieja) console.error('      está en EXCEPCIONES, pero la expresión cambió: revisala y actualizá la huella');
    for (const { clausula, rama } of h.ramas) console.error(`      ${clausula}: ${rama.replace(/\s+/g, ' ')}`);
  }
  console.error(
    '\n   Arreglo: sumarle a la rama la sucursal (`AND sucursal_id = current_sucursal_id()`,\n' +
      '   `AND cliente_de_sucursal_activa(cliente_id)`, `admin_comparte_sucursal_con(id)`…).\n' +
      '   Si la tabla es global de verdad, agregala a EXCEPCIONES con su motivo.',
  );
  process.exit(1);
}

console.log('\n✅ Toda rama admin de las policies mira la sucursal.');
