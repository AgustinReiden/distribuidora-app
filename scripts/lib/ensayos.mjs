/**
 * El veredicto de un ensayo de SQL (scripts/test-*.sql) a partir de lo que imprime.
 * Puro y sin dependencias: lo usa scripts/ci/ensayos-sql.mjs y lo prueba src/test/catalogo.test.ts.
 *
 * Un ensayo dice su veredicto en un NOTICE o en el mensaje de su excepción final (que lo
 * deshace todo), así que el exit code no sirve. Es bueno si imprime una línea «ENSAYO … OK»
 * (también «ensayo #1234 OK», «ENSAYO OK · …») y ninguna línea «ENSAYO FALL…» (con o sin tilde).
 *
 * Lo que fija la lista de excepciones es la FIRMA de la falla: la línea del veredicto (la de
 * «ENSAYO FALLÓ», o el primer ERROR) más las dos siguientes, sin uuids ni números. Un ensayo
 * exceptuado que empieza a fallar por otra cosa pone el CI rojo: puede ser una regla rota
 * nueva escondida detrás de una excepción vieja.
 */

const limpiar = (l) =>
  l
    .replace(/^psql:[^:]*:\d+:\s*/, '')
    .trim();

/** uuids y números fuera: lo que cambia de una corrida a otra (ids, fechas, conteos). */
export function normalizarFirma(txt) {
  return String(txt ?? '')
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<uuid>')
    .replace(/\d+/g, 'N')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 300);
}

/** {ok, firma}: la firma sólo cuando no es OK. */
export function veredicto(salida) {
  const lineas = String(salida ?? '')
    .split('\n')
    .map(limpiar)
    .filter(Boolean);
  // «FALLÓ» / «FALLO» es el veredicto; «0 fallas» en una línea de OK no lo es.
  const FALLO = /\bfall(?:ó|o)(?![a-záéíóúñ])/i;
  const esFallo = (l) => /\bensayo\b/i.test(l) && FALLO.test(l) && !/rollback/i.test(l);
  const esOk = (l) => /\bensayo\b[^\n]*\bOK\b/i.test(l) && !FALLO.test(l);
  const fallo = lineas.findIndex(esFallo);
  if (fallo === -1 && lineas.some(esOk)) return { ok: true, firma: '' };
  let i = fallo;
  if (i === -1) i = lineas.findIndex((l) => /^ERROR:/.test(l) && !/rollback|current transaction is aborted/i.test(l));
  if (i === -1) return { ok: false, firma: 'no dijo ENSAYO OK' };
  const cola = lineas.slice(i + 1, i + 3).filter((l) => !/^(CONTEXT|LINE \d+|PL\/pgSQL|SQL statement)|current transaction is aborted/i.test(l));
  return { ok: false, firma: normalizarFirma([lineas[i], ...cola].map((l) => l.replace(/^(ERROR|NOTICE|WARNING|INFO|LOG):\s+/, '')).join(' | ')) };
}
