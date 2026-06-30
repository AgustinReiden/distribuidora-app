#!/usr/bin/env node
/**
 * Drift-check de migraciones.
 * Contrasta los archivos migrations/NNN_*.sql contra el ledger REAL de prod
 * (supabase_migrations.schema_migrations), leído vía el RPC
 * public.migraciones_aplicadas() (creado en migrations/109).
 *
 * Modelo (ver migrations/MANIFEST.md): el historial <= SNAPSHOT ya está
 * reconciliado y documentado en el MANIFEST — es curado/consolidado, NO 1:1, y
 * NO se re-chequea acá (daría falsos positivos). Este script vigila que las
 * migraciones NUEVAS (por encima del snapshot) mantengan el 1:1 archivo<->ledger,
 * que es la convención a futuro. Atrapa los dos modos de drift reales:
 *   - aplicado en prod pero sin archivo en el repo (p.ej. el 108 que faltaba)
 *   - archivo commiteado pero nunca aplicado a prod
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-migrations.mjs
 */
import { readdirSync } from 'node:fs';

// Frontera reconciliada el 2026-06-30 (ver MANIFEST.md). Subir estos dos valores
// SOLO cuando se re-snapshotee el MANIFEST con un histórico nuevo ya verificado.
const SNAPSHOT_VERSION = '20260630160533'; // 109_migraciones_aplicadas_rpc
const SNAPSHOT_MAX_FILE = 109;

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

// --- 1. Archivos locales (migrations/NNN_*.sql; archive/ y *.md quedan afuera) ---
const migDir = new URL('../migrations/', import.meta.url);
const files = readdirSync(migDir).filter((f) => /^\d+.*\.sql$/.test(f));

const fileNum = (f) => parseInt(f.match(/^(\d+)/)[1], 10);
const fileStem = (f) => f.replace(/^\d+[a-z]?_/, '').replace(/\.sql$/, '');

// --- 2. Ledger en vivo (mismo patrón que scripts/check-integridad.mjs) ---
const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/migraciones_aplicadas`, {
  method: 'POST',
  headers: {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
  },
  body: '{}',
});

if (!res.ok) {
  console.error(`El RPC migraciones_aplicadas() falló: HTTP ${res.status}\n${await res.text()}`);
  console.error('¿Aplicaste migrations/109_migraciones_aplicadas_rpc.sql?');
  process.exit(2);
}

const ledger = await res.json(); // [{ version, name }]
// Normaliza el name del ledger al "stem" comparable: saca el sufijo de backfill y el prefijo NNN_.
const ledgerStem = (name) => name.replace(/\s*\(backfill.*$/i, '').replace(/^\d+[a-z]?_/, '').trim();

// --- 3. Diff por encima del snapshot ---
const nuevosArchivos = files.filter((f) => fileNum(f) > SNAPSHOT_MAX_FILE);
const nuevasFilas = ledger.filter((m) => m.version > SNAPSHOT_VERSION);

const stemsArchivo = new Set(nuevosArchivos.map(fileStem));
const stemsLedger = new Set(nuevasFilas.map((m) => ledgerStem(m.name)));

const aplicadoSinArchivo = nuevasFilas.filter((m) => !stemsArchivo.has(ledgerStem(m.name)));
const archivoSinAplicar = nuevosArchivos.filter((f) => !stemsLedger.has(fileStem(f)));

// --- 4. Reporte ---
console.log(`Drift-check de migraciones @ snapshot ${SNAPSHOT_VERSION} (archivos <= ${SNAPSHOT_MAX_FILE} reconciliados en MANIFEST.md)`);
console.log(`Ledger en prod: ${ledger.length} filas | archivos repo: ${files.length}`);
console.log(`Nuevos desde el snapshot — archivos: ${nuevosArchivos.length}, filas de ledger: ${nuevasFilas.length}`);

if (aplicadoSinArchivo.length) {
  console.log('\n❌ Aplicado en prod pero SIN archivo en migrations/:');
  for (const m of aplicadoSinArchivo) console.log(`   ${m.version}  ${m.name}`);
}
if (archivoSinAplicar.length) {
  console.log('\n❌ Archivo en migrations/ pero NO aplicado en prod (o con nombre distinto):');
  for (const f of archivoSinAplicar) console.log(`   ${f}`);
}

if (aplicadoSinArchivo.length || archivoSinAplicar.length) {
  console.error(
    '\n❌ Drift detectado. Reconciliá (agregá el archivo / aplicá la migración / alineá el name) ' +
    'o, si es legítimo, actualizá migrations/MANIFEST.md y subí el snapshot en este script.',
  );
  process.exit(1);
}

console.log('\n✅ Sin drift por encima del snapshot. migrations/ alineado con prod.');
