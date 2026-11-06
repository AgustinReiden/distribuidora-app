#!/usr/bin/env node
/**
 * Gate de las policies de storage (#1474).
 * Falla (exit 1) si una policy permisiva de storage.objects va TO public/anon, no
 * nombra su bucket, o tiene un camino que no mira la sucursal del path; o si
 * hay un bucket público. Lee el RPC auditoria_storage() (migrations/463) y
 * decide con hallazgosStorage de scripts/lib/acceso.mjs.
 *
 * Por qué existe: las tres policies del bucket `facturas` (mig 239) miraban
 * sólo el rol. Un encargado o admin de una sucursal listaba y leía las facturas
 * escaneadas de otra, con proveedores y costos. scripts/check-rama-admin.mjs
 * mira sólo las policies de public, así que no lo veía.
 *
 * La regla: el path de un objeto privado es `<sucursal_id>/…`, y la policy
 * compara `(storage.foldername(name))[1]` con las sucursales del usuario.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-storage.mjs
 */
import { hallazgosStorage } from './lib/acceso.mjs';

/**
 * Excepciones: `{ policy, huella, motivo }` (huella = md5 de `using|check`, como
 * en check-rama-admin.mjs) o `{ bucket, motivo }` para un bucket público. Hoy no
 * hay ninguna.
 */
const EXCEPCIONES = [];

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_storage`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_storage() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
const politicas = r.politicas ?? [];
const buckets = r.buckets ?? [];
if (!Array.isArray(politicas) || !Array.isArray(buckets) || !buckets.length) {
  // Sin buckets no es "todo bien": es que el RPC no está mirando nada.
  console.error('El RPC auditoria_storage() no devolvió ningún bucket: el gate no puede mirar.');
  process.exit(2);
}

const { hallazgos, sobrantes } = hallazgosStorage({ politicas, buckets }, EXCEPCIONES);

console.log(`Auditoría de storage @ ${r.generado_at}`);
console.log(
  `Buckets: ${buckets.length} | policies de storage.objects: ${politicas.length} | ` +
    `exceptuadas: ${EXCEPCIONES.length - sobrantes.length} | en rojo: ${hallazgos.length}`,
);

if (sobrantes.length) {
  console.log('\nℹ️  Excepciones que ya no hacen falta: sacalas.');
  for (const e of sobrantes) console.log(`  ${e.policy ?? `bucket ${e.bucket}`}  (${e.motivo})`);
}

if (hallazgos.length) {
  console.error('\n❌ Storage abierto de más:');
  for (const h of hallazgos) {
    if (h.bucket) console.error(`  bucket ${h.bucket}`);
    else console.error(`  ${h.policy} (${h.cmd})  huella ${h.huella}`);
    if (h.excepcionVieja) console.error('      está en EXCEPCIONES, pero la expresión cambió: revisala y actualizá la huella');
    for (const m of h.motivos) console.error(`      ${m.replace(/\s+/g, ' ')}`);
  }
  console.error(
    '\n   Arreglo: la policy va TO authenticated, con `bucket_id = \'…\'` y\n' +
      '   `(storage.foldername(name))[1] IN (SELECT us.sucursal_id::text FROM public.usuario_sucursales us\n' +
      '   WHERE us.usuario_id = auth.uid())`, y el front sube a `<sucursal_id>/…`.',
  );
  process.exit(1);
}

console.log('\n✅ Toda policy de storage nombra su bucket y mira la sucursal del path.');
