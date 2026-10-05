#!/usr/bin/env node
/**
 * Refresco diario del impuesto interno derivado (mig 282, #865).
 *
 * `productos.impuestos_internos` es la efectiva del encuadre vigente HOY (mig
 * 277). La base la recalcula cuando se toca la ficha o se escribe una
 * alícuota, pero una alícuota cargada con vigencia futura empieza a regir un
 * día en que nadie escribe nada. En prod no hay pg_cron (#661): este script,
 * corrido por `.github/workflows/refrescar-ii.yml`, es quien la activa.
 *
 * `refrescar_ii_productos()` sólo actualiza las fichas cuyo valor cambia, así
 * que un día sin cambios de tasa devuelve 0 y no escribe nada.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (la función es
 * server-only: sólo la ejecuta service_role).
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/refrescar-ii.mjs
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
 *  un refresco que no pudo correr tiene que verse rojo, no verde. */
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

const actualizadas = await rpc('refrescar_ii_productos');
if (!Number.isInteger(actualizadas)) {
  console.error(`refrescar_ii_productos() devolvió algo que no es un entero: ${JSON.stringify(actualizadas)}`);
  process.exit(2);
}
console.log(`refrescar_ii_productos(): ${actualizadas} ficha(s) actualizada(s).`);
