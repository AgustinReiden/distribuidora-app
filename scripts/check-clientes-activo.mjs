#!/usr/bin/env node
/**
 * Gate de los clientes dados de baja (gate 3 de #1520, mig 480).
 * Llama al RPC auditoria_pedidos_cliente_activo() vía PostgREST con la service_role key y falla
 * (exit 1) si una función de public inserta en pedidos sin nombrar `clientes` y `activo` en una
 * misma sentencia, y no está en scripts/clientes-activo-permitidas.json.
 *
 * Por qué existe: un cliente con pedidos no se puede borrar (la FK es RESTRICT desde la mig 200),
 * así que darlo de baja es desactivarlo, y un cliente inactivo no recibe pedidos. Lo frenan
 * crear_pedido_completo, crear_pedido_completo_bot y crear_pedido_cambio_en_ruta; el cambio de
 * cliente no lo miraba y lo frenaba recién el alta, después de cancelar el pedido (PAT-8-1, #1513).
 * Un camino nuevo que inserte pedidos tiene que mirarlo también.
 *
 * Lo que NO ve (es texto, no ejecución):
 *   · Una función que crea el pedido llamando a crear_pedido_completo: hereda su control, y no
 *     cuenta.
 *   · Que la sentencia que nombra los dos de verdad rechace al inactivo: eso lo prueba el ensayo de
 *     cada camino (para el cambio de cliente, scripts/test-cambio-cliente-conserva-1513.sql).
 *   · SQL dinámico (EXECUTE), ni un `;` dentro de un literal $…$.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-clientes-activo.mjs
 */
import { readFileSync } from 'node:fs';
import { hallazgosClientesActivo } from './lib/clientesActivo.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const { funciones: permitidas } = JSON.parse(
  readFileSync(new URL('./clientes-activo-permitidas.json', import.meta.url), 'utf8'),
);

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_pedidos_cliente_activo`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_pedidos_cliente_activo() falló: HTTP ${res.status}\n${await res.text()}`);
  process.exit(2);
}

const r = await res.json();
// Cero funciones no es "todo bien": es que el RPC no está mirando nada (o es otro).
// Hoy insertan en pedidos al menos el alta, el bot y el canje en ruta.
if (!r.funciones || r.funciones < 3 || !Array.isArray(r.sin_activo)) {
  console.error('El RPC auditoria_pedidos_cliente_activo() no devolvió las funciones que crean pedidos: el gate no puede mirar.');
  process.exit(2);
}

const { faltan, sobrantes } = hallazgosClientesActivo(r, permitidas);

console.log(`Auditoría de clientes dados de baja @ ${r.generado_at}`);
console.log(
  `Funciones que insertan en pedidos: ${r.funciones} | sin mirar clientes.activo: ${r.sin_activo.length} ` +
    `(permitidas: ${r.sin_activo.length - faltan.length})`,
);

if (sobrantes.length) {
  console.log('\nℹ️  Permitidas que ya no hacen falta (miran activo, o la función no existe más): sacalas del JSON.');
  for (const f of sobrantes) console.log(`  ${f}  (${permitidas[f]})`);
}

if (faltan.length) {
  console.error('\n❌ Funciones que crean pedidos sin mirar si el cliente está activo:');
  for (const f of faltan) console.error(`  ${f}`);
  console.error(
    '\n   Arreglo: rechazar al cliente dado de baja antes de escribir, como crear_pedido_completo\n' +
      "   (IF EXISTS (SELECT 1 FROM clientes WHERE id = … AND NOT activo) THEN …), o crear el\n" +
      '   pedido llamando a crear_pedido_completo.',
  );
  process.exit(1);
}

console.log('\n✅ Toda función que crea pedidos mira si el cliente está activo (salvo las permitidas).');
