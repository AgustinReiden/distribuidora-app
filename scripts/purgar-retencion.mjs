#!/usr/bin/env node
/**
 * Retención de avisos y auditoría (1561-b10 y 1596-b10, plan #1603).
 *
 * Decisión del dueño (D38, 15/11): los avisos (`notificaciones`) se guardan 90
 * días y el registro de auditoría (`audit_logs`) 24 meses. `purgar_retencion()`
 * (migración NNN_usuarios_sucursal_default_y_retencion) borra, de cada tabla,
 * hasta un lote de filas más viejas que su corte y dice si quedan más. En prod
 * no hay pg_cron (#661): este script, corrido por
 * `.github/workflows/purgar-retencion.yml`, la llama en un bucle hasta que no
 * queden. Nada más borra `audit_logs`, que es evidencia.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (la función es
 * server-only: sólo la ejecuta service_role).
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/purgar-retencion.mjs
 */
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const LOTE = 5000;
// Tope de vueltas por corrida: 200 × 5.000 = un millón de filas por tabla. Lo
// que quede lo borra la corrida del día siguiente.
const MAX_VUELTAS = 200;

const base = url.replace(/\/$/, '');
const headers = {
  apikey: key,
  Authorization: `Bearer ${key}`,
  'Content-Type': 'application/json',
};

/** Llama un RPC por PostgREST. Muere con exit 2 si la llamada en sí falla:
 *  una purga que no pudo correr tiene que verse roja, no verde. */
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

let avisos = 0;
let auditoria = 0;
let vueltas = 0;
let r;
do {
  r = await rpc('purgar_retencion', { p_lote: LOTE });
  if (!r || !Number.isInteger(r.notificaciones) || !Number.isInteger(r.audit_logs) || typeof r.quedan !== 'boolean') {
    console.error(`purgar_retencion() devolvió algo inesperado: ${JSON.stringify(r)}`);
    process.exit(2);
  }
  avisos += r.notificaciones;
  auditoria += r.audit_logs;
  vueltas += 1;
} while (r.quedan && vueltas < MAX_VUELTAS);

console.log(`purgar_retencion(): ${avisos} aviso(s) de antes del ${r.corte_notificaciones} y ` +
  `${auditoria} fila(s) de auditoría de antes del ${r.corte_audit_logs}, en ${vueltas} vuelta(s).`);
if (r.quedan) {
  console.log(`Quedan filas para borrar: las borra la próxima corrida (tope de ${MAX_VUELTAS} vueltas).`);
}
