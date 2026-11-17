#!/usr/bin/env node
/**
 * Qué migraciones hay que aplicar sobre la foto del esquema de prod, en orden, una por línea.
 *
 *   1. Las numeradas de migrations/ que la foto NO tiene: número mayor que el último del
 *      ledger de la foto (esquema-base/ledger.txt) y nombre que no figura en él. Pasa cuando
 *      una migración se aplica a prod por MCP y su archivo entra a main con número después de
 *      las 07:30, que es cuando se toma la foto: sin esto, su ensayo corre contra un esquema que
 *      no la tiene y main y todos los PRs quedan rojos hasta el día siguiente (H3 de la lente
 *      de #1645).
 *   2. Después, las `NNN_*.sql` con el número literal: las del PR, que todavía no tienen número.
 *
 * Una migración con número menor o igual al último del ledger y que no figura en él es una
 * consolidada o aplicada fuera de orden (migrations/MANIFEST.md): no se toca.
 *
 * Uso: node scripts/ci/migraciones-pendientes.mjs esquema-base/ledger.txt
 */
import { readdirSync, readFileSync } from 'node:fs';

const ledgerArchivo = process.argv[2];
if (!ledgerArchivo) {
  console.error('Uso: migraciones-pendientes.mjs <ledger.txt>');
  process.exit(2);
}

const NUM = /^(\d+)([a-z]?)_(.*)\.sql$/;
const stemDe = (nombre) => nombre.replace(/\s*\(backfill.*$/i, '').replace(/^\d+[a-z]?_/, '').replace(/\.sql$/, '').trim();

const ledger = readFileSync(ledgerArchivo, 'utf8')
  .split('\n')
  .map((l) => l.trim())
  .filter(Boolean)
  .map((l) => l.split('|').slice(1).join('|'));
if (!ledger.length) {
  console.error('El ledger de la foto está vacío: no se puede saber qué falta.');
  process.exit(2);
}
const stemsLedger = new Set(ledger.map(stemDe));
const maxLedger = Math.max(...ledger.map((n) => parseInt((/^(\d+)/.exec(n) ?? [0, '0'])[1], 10)));

const archivos = readdirSync(new URL('../../migrations/', import.meta.url)).filter((f) => f.endsWith('.sql'));
const numeradas = archivos
  .map((f) => ({ f, m: NUM.exec(f) }))
  .filter(({ m }) => m)
  .map(({ f, m }) => ({ f, n: parseInt(m[1], 10), sufijo: m[2], stem: stemDe(f) }))
  .filter((x) => x.n > maxLedger && !stemsLedger.has(x.stem))
  .sort((a, b) => a.n - b.n || a.sufijo.localeCompare(b.sufijo) || a.f.localeCompare(b.f));
const literales = archivos.filter((f) => /^NNN_.*\.sql$/.test(f)).sort();

for (const x of numeradas) console.log(`migrations/${x.f}`);
for (const f of literales) console.log(`migrations/${f}`);
console.error(`ledger de la foto: ${ledger.length} migraciones, última numerada ${maxLedger} | por aplicar: ${numeradas.length} numeradas + ${literales.length} NNN`);
