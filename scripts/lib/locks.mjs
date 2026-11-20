/**
 * El criterio del gate de locks (#1520, gate 4; scripts/check-locks.mjs).
 *
 * auditoria_locks() devuelve cada sentencia de una función de public que toma un lock de fila (FOR UPDATE,
 * FOR NO KEY UPDATE, FOR SHARE, FOR KEY SHARE), sin comentarios y con los literales vacíos (cómo los saca:
 * `sinComentariosNiLiterales`, abajo). Acá se decide cuál toma varias filas sin ORDER BY.
 *
 * Por qué importa: dos transacciones que bloquean el mismo conjunto de filas en órdenes distintos se cruzan
 * (40P01). El orden global es por id ascendente (migrations/CLAUDE.md, "El orden de locks"). Un lock de varias
 * filas sin ORDER BY las toma en el orden en que las devuelve el plan, que cambia con los datos.
 *
 * Para cada lock, la consulta que lo lleva es el paréntesis que lo envuelve (una subconsulta o una CTE), o la
 * sentencia entera. En un `FOR r IN SELECT … LOOP` se corta en el LOOP. Dentro de esa consulta se vacían los
 * paréntesis, así un ORDER BY o un `id =` de una subconsulta no cuentan. No es multi-fila si:
 *   · tiene ORDER BY;
 *   · lleva NOWAIT, SKIP LOCKED o LIMIT 1 (no espera, o toma una sola);
 *   · es un SELECT … INTO de PL/pgSQL: trae una fila (dos con STRICT), y el lock se toma sobre lo que trae;
 *   · su WHERE compara `id` (o `alias.id`) por igual, sin ANY ni ALL: una fila por la PK.
 *
 * Lo que no ve (es texto, no ejecución):
 *   · una PK compuesta u otra clave única: la toma por multi-fila, y va a la lista con su motivo;
 *   · un `a.id = b.x` en el WHERE de un join con coma: lo toma por una fila;
 *   · SQL dinámico (EXECUTE), y un `;` o un `--` dentro de un literal $…$.
 */

const LOCK = /\bFOR\s+(?:NO\s+KEY\s+UPDATE|UPDATE|KEY\s+SHARE|SHARE)\b/gi;

/**
 * Cómo prepara la base cada cuerpo antes de cortarlo (#1541): espejo de `_sql_sin_comentarios` y
 * `_sql_sin_comentarios_ni_literales` (la migración de B9 del plan #1603), que usan auditoria_locks() y las
 * demás auditoria_* que leen código. Una sola pasada de izquierda a derecha: lo que empieza en una comilla
 * es un literal (con sus `''`) aunque adentro tenga `--` o `/*`, y lo que empieza en `--` o `/*` fuera de
 * un literal es un comentario. Antes se sacaban primero los comentarios y después los literales: un literal
 * `' -- '` (el motivo de la merma de cancelar_pedido_con_stock) perdía su comilla de cierre, la paridad
 * quedaba al revés y el gate no veía los locks que venían después. Los regex son los mismos que en SQL.
 * Una cadena E'…' (con la E suelta, no la de ELSE'x') entiende además `\'` y `\\` (H1 de la revisión de
 * C5, #1603): sin eso la comilla escapada cerraba el literal y lo que seguía quedaba al revés.
 * Lo que no entiende: un dólar-quote anidado ($q$…$q$).
 */
const LITERAL_SQL = String.raw`(?<!\w)[Ee]'(?:[^'\\]|\\[\s\S]|'')*'|'(?:[^']|'')*'`;
const TOKENS_SQL = new RegExp(`(${LITERAL_SQL})|--[^\\n]*|\\/\\*(?:[^*]|\\*+[^*/])*\\*+\\/`, 'g');

/** El cuerpo sin comentarios; los literales quedan como están. */
export function sinComentarios(src) {
  return src.replace(TOKENS_SQL, (_m, literal) => literal ?? '');
}

/** El cuerpo sin comentarios y con cada literal vacío (`''`). */
export function sinComentariosNiLiterales(src) {
  return sinComentarios(src).replace(new RegExp(LITERAL_SQL, 'g'), "''");
}

/** Las sentencias de un cuerpo que toman un lock de fila, como las devuelve auditoria_locks(). */
export function sentenciasConLock(src) {
  return sinComentariosNiLiterales(src)
    .split(';')
    .filter((s) => new RegExp(LOCK.source, 'i').test(s))
    .map((s) => s.replace(/\s+/g, ' ').trim());
}

/** Vacía el contenido de todo paréntesis, del más interno hacia afuera: `f(a, (b))` → `f()`. */
export function aplanar(texto) {
  // El vacío va como un marcador sin paréntesis: si fuera `()`, el de afuera nunca quedaría sin paréntesis
  // adentro y no se vaciaría.
  let antes;
  let t = texto;
  do {
    antes = t;
    t = t.replace(/\([^()]*\)/g, '\u0001');
  } while (t !== antes);
  return t.replace(/\u0001/g, '()');
}

/** La consulta que lleva el lock que empieza en `i`: el paréntesis que lo envuelve, o la sentencia. */
export function consultaDelLock(sentencia, i) {
  let inicio = 0;
  for (let j = i - 1, prof = 0; j >= 0; j--) {
    const c = sentencia[j];
    if (c === ')') prof++;
    else if (c === '(') {
      if (prof === 0) {
        inicio = j + 1;
        break;
      }
      prof--;
    }
  }
  let fin = sentencia.length;
  for (let j = i, prof = 0; j < sentencia.length; j++) {
    const c = sentencia[j];
    if (c === '(') prof++;
    else if (c === ')') {
      if (prof === 0) {
        fin = j;
        break;
      }
      prof--;
    }
  }
  let consulta = sentencia.slice(inicio, fin);
  // `FOR r IN SELECT … FOR UPDATE LOOP <cuerpo>`: el cuerpo no es parte de la consulta.
  const loop = /\bLOOP\b/i.exec(consulta.slice(i - inicio));
  if (loop) consulta = consulta.slice(0, i - inicio + loop.index);
  return consulta;
}

/** Por qué un lock no toma varias filas sin orden, o null si las toma. */
export function porQueNoEsMultiFila(consulta) {
  const plana = aplanar(consulta);
  if (/\bORDER\s+BY\b/i.test(plana)) return 'ORDER BY';
  if (/\b(?:NOWAIT|SKIP\s+LOCKED)\b/i.test(plana)) return 'NOWAIT o SKIP LOCKED';
  if (/\bLIMIT\s+1\b/i.test(plana)) return 'LIMIT 1';
  if (/(?<!\bINSERT\s+)\bINTO\b/i.test(plana)) return 'SELECT INTO';
  const where = /\bWHERE\b/i.exec(plana);
  if (where && /(?:^|[^\w.])(?:\w+\.)?id\s*=\s*(?!\s*(?:ANY|ALL)\b)/i.test(plana.slice(where.index + 5))) {
    return 'una fila por id';
  }
  return null;
}

/** ¿La sentencia toma, en alguno de sus locks, varias filas sin ORDER BY? */
export function tomaVariasFilasSinOrden(sentencia) {
  for (const m of sentencia.matchAll(LOCK)) {
    if (porQueNoEsMultiFila(consultaDelLock(sentencia, m.index)) === null) return true;
  }
  return false;
}

/**
 * Lo que es rojo en la salida de auditoria_locks().
 *  · marcadas: las funciones con alguna sentencia que toma varias filas sin ORDER BY y que no están en
 *    `permitidas` ({ firma: motivo }), con esas sentencias. Va por firma: una sobrecarga nueva no hereda la
 *    excepción.
 *  · sobrantes: las permitidas que ya no hacen falta (ordenan, o la función no existe más). Se avisan para
 *    sacarlas; no son rojo.
 */
export function hallazgosLocks(auditoria, permitidas = {}) {
  const porFirma = new Map();
  for (const s of auditoria?.sentencias ?? []) {
    if (!tomaVariasFilasSinOrden(s.sentencia)) continue;
    if (!porFirma.has(s.firma)) porFirma.set(s.firma, []);
    porFirma.get(s.firma).push(s.sentencia);
  }
  return {
    marcadas: [...porFirma]
      .filter(([firma]) => !Object.hasOwn(permitidas, firma))
      .map(([firma, sentencias]) => ({ firma, sentencias })),
    sobrantes: Object.keys(permitidas).filter((firma) => !porFirma.has(firma)),
  };
}
