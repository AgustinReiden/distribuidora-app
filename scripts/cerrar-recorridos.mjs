#!/usr/bin/env node
/**
 * Cierre diario de los recorridos que quedaron "en curso" (#1056).
 *
 * Antes un recorrido se cerraba al aprobar su rendición; hoy la rendición se
 * controla por fecha y chofer, y nada los cerraba: se acumularon 70 entre agosto
 * y octubre de 2026. `cerrar_recorridos_vencidos()` (mig 183, corregida en las
 * migs 330 y 334) pasa a `completado` los de días pasados (día argentino) sin
 * ninguna parada todavía 'asignado'; los que tienen pendientes quedan abiertos
 * y se cuentan. En prod no hay pg_cron (#661): este script, corrido por
 * `.github/workflows/cerrar-recorridos.yml`, es quien la llama.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (la función es
 * server-only: sólo la ejecuta service_role).
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/cerrar-recorridos.mjs
 */
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const base = url.replace(/\/$/, '');
const headers = {
  apikey: key,
  Authorization: `Bearer ${key}`,
  'Content-Type': 'application/json',
};

/** Llama un RPC por PostgREST. Muere con exit 2 si la llamada en sí falla:
 *  un cierre que no pudo correr tiene que verse rojo, no verde. */
async function rpc(nombre, body = {}) {
  const res = await fetch(`${base}/rest/v1/rpc/${nombre}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    console.error(`El RPC ${nombre}() falló: HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

// RETURNS TABLE(cerrados, con_pendientes): PostgREST la devuelve como array.
const filas = await rpc('cerrar_recorridos_vencidos', { p_sucursal_id: null });
const fila = Array.isArray(filas) ? filas[0] : null;
if (!fila || !Number.isInteger(fila.cerrados) || !Number.isInteger(fila.con_pendientes)) {
  console.error(`cerrar_recorridos_vencidos() devolvió algo inesperado: ${JSON.stringify(filas)}`);
  process.exit(2);
}
console.log(`cerrar_recorridos_vencidos(): ${fila.cerrados} cerrado(s).`);
if (fila.con_pendientes > 0) {
  // No es un error del cierre: es trabajo para una persona.
  console.log(`Quedan ${fila.con_pendientes} recorrido(s) de días pasados con paradas todavía asignadas: resolverlas a mano.`);
}
