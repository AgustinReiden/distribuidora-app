#!/usr/bin/env node
/**
 * Gate del bot de Telegram (#1309, #1311).
 * Falla (exit 1) si:
 *   · a alguien con el resumen diario activo le tocaba uno entre hace 30 y hace
 *     2 horas (su hora, un día de los suyos) y no le llegó: ni 'ok' ni
 *     'skipped' en bot_digests_enviados para esa fecha y esa sucursal;
 *   · alguien está suscripto al resumen y no tiene ninguna sucursal activa
 *     asignada: antes recibía la Red, ahora no recibe nada;
 *   · el trigger que sostiene "apagar el bot desde el panel es definitivo" no
 *     está, está deshabilitado, o hay un chat prendido de un perfil que un
 *     admin apagó.
 * Lo lee del RPC auditoria_bot() (migrations/NNN_el_bot_resumen_numeros_y_apagado).
 *
 * Por qué existe: el resumen dependía del cron horario de GitHub con la hora
 * exacta, y en 41 días salió 14 sin que nada se pusiera rojo; el workflow del
 * digest termina en verde aunque no mande nada. Y el canje de un código
 * prendía de nuevo a quien el admin había apagado (decisión del dueño, 29/10:
 * apagarlo es definitivo hasta que un admin lo prenda).
 *
 * Lo que NO ve: un resumen que salió pero llegó mal (eso lo ve el que lo lee);
 * los avisos de atrasados y de vencimientos, que no son diarios ni para todos.
 * El ensayo con datos armados de las dos reglas es scripts/test-bot-1309-1311.sql.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-bot.mjs
 */
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_bot`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});
if (!res.ok) {
  console.error(`El RPC auditoria_bot() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}
const r = await res.json();
const faltantes = r.digest_faltantes ?? [];
const sinSucursal = r.sin_sucursal ?? [];
const apagado = r.apagado ?? {};

console.log(`Auditoría del bot @ ${r.generado_at}`);
console.log(
  `Suscripciones al resumen (perfil × sucursal): ${r.suscripciones} | ` +
    `faltantes en las últimas 30 h: ${faltantes.length} | ` +
    `suscriptos sin sucursal: ${sinSucursal.length} | ` +
    `trigger del apagado: ${apagado.trigger_ok ? 'ok' : 'FALTA'} | ` +
    `chats prendidos con marca: ${apagado.chats_prendidos_con_marca}`,
);

const fallas = [];
for (const f of faltantes) {
  fallas.push(
    `${f.nombre ?? f.perfil_id} · ${f.sucursal ?? f.sucursal_id}: no recibió el resumen del ${f.fecha_resumida} ` +
      `(le tocaba ${f.momento}${f.status ? `, quedó en '${f.status}'` : ', sin ninguna marca'})`,
  );
}
for (const s of sinSucursal) {
  fallas.push(`${s.nombre ?? s.perfil_id}: tiene el resumen activo y ninguna sucursal activa asignada, así que no recibe nada`);
}
if (apagado.trigger_ok !== true) {
  fallas.push('trg_bot_usuarios_respeta_apagado no está o está deshabilitado: el canje puede prender a quien apagó un admin');
}
if (Number(apagado.chats_prendidos_con_marca ?? 0) > 0) {
  fallas.push(`${apagado.chats_prendidos_con_marca} chat(s) prendidos de perfiles que un admin apagó`);
}

if (fallas.length) {
  console.error('\n❌ El bot no hizo lo que tenía que hacer:');
  for (const f of fallas) console.error(`   · ${f}`);
  console.error(
    '\n   Resumen: gh run list --workflow=telegram-digest.yml (¿corrió?) y bot_digests_enviados.error_meta\n' +
      "   (¿en qué etapa falló?). Una marca en 'enviando' es una corrida que murió en el medio: no se\n" +
      '   reintenta sola, para no mandar dos veces.',
  );
  process.exit(1);
}

console.log('\n✅ Todos los resúmenes que tocaban salieron, y el apagado del admin se sostiene.');
