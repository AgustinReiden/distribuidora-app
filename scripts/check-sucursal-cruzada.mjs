#!/usr/bin/env node
/**
 * Gate de aislamiento por sucursal.
 * Llama al RPC auditoria_sucursal_cruzada() (ver migrations/186) vía PostgREST
 * con la service_role key y falla (exit 1) si aparece cualquiera de las dos
 * cosas que la migración 187 dejó imposibles:
 *
 *   · una fila hija que contradice la sucursal de su padre  → dato ya corrupto;
 *   · un par hija->padre sin FK compuesta                   → agujero reabierto.
 *
 * El segundo es el que importa a futuro y el que justifica que esto viva en CI:
 * el agujero original no fue una tabla mal hecha, fue que nadie miraba la CLASE.
 * Una tabla nueva con `sucursal_id` y una FK simple al padre aparece acá al día
 * siguiente, en vez de dentro de un año cuando alguien note que un costo se fue
 * a la sucursal equivocada.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-sucursal-cruzada.mjs
 */
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/auditoria_sucursal_cruzada`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC auditoria_sucursal_cruzada() falló: HTTP ${res.status}\n${await res.text()}`);
  console.error('¿Aplicaste migrations/186_quien_cruza_de_sucursal.sql?');
  process.exit(2);
}

const pares = await res.json();

if (!Array.isArray(pares) || pares.length === 0) {
  // Cero pares no es "todo bien": es que el reporte dejó de ver el esquema.
  // Mientras existan compra_items o pedido_items tiene que haber pares.
  console.error('El reporte devolvió 0 pares. Eso no puede pasar con este esquema:');
  console.error('revisar _pares_sucursal_cruzada() antes de dar el gate por bueno.');
  process.exit(2);
}

const cruzados = pares.filter((p) => Number(p.divergentes) > 0);
const sinProteger = pares.filter((p) => !p.protegida);

console.log(`Aislamiento por sucursal: ${pares.length} pares hija->padre`);
console.log(
  `Protegidos por FK compuesta: ${pares.length - sinProteger.length} | sin proteger: ${sinProteger.length} | con filas cruzadas: ${cruzados.length}`,
);

if (sinProteger.length) {
  console.log('\nSin FK compuesta (la hija puede colgarse de un padre de otra sucursal):');
  for (const p of sinProteger) {
    console.log(`  ${p.hija}.${p.columna} -> ${p.padre}  (${p.filas} filas)`);
  }
}

if (cruzados.length) {
  console.log('\nCon filas que YA cruzan de sucursal:');
  for (const p of cruzados) {
    console.log(`  ${p.hija}.${p.columna} -> ${p.padre}: ${p.divergentes} de ${p.filas} filas`);
  }
}

if (cruzados.length || sinProteger.length) {
  console.error(
    '\n❌ El aislamiento por sucursal tiene agujeros. Ver migrations/186 y 187: una tabla nueva con sucursal_id necesita FK compuesta (columna, sucursal_id) -> padre(id, sucursal_id), no una FK simple.',
  );
  process.exit(1);
}

console.log('\n✅ Todos los pares atados por FK compuesta y sin filas cruzadas.');
