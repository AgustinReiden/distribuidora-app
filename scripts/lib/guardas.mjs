/**
 * Guardas `IF NOT ( … OR … )` que no cortan cuando un término da NULL (#1601, SEG-1).
 * Puro y sin dependencias: lo usa check-rpcs-definer.mjs y lo prueban los casos de
 * src/test/catalogo.test.ts.
 *
 * El defecto: `IF NOT (p.transportista_id = auth.uid() OR v_rol IN ('admin'))` con
 * `transportista_id` NULL (un pedido sin chofer) da NULL = uid → NULL; NULL OR falso →
 * NULL; NOT NULL → NULL, y un IF con NULL no entra: la guarda no corta y pasa cualquier
 * rol (marcar_no_entregado, #1601). El SQL de auditoria_rpcs_definer() sólo mira el
 * PRIMER término del OR; la forma `NOT (rol IN (…) OR col = uid)` no la ve.
 */

/** Saca los comentarios y deja vacíos los literales de texto: lo que queda es sólo código. */
export function soloCodigoSql(src) {
  return String(src ?? '')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/--[^\n]*/g, ' ')
    .replace(/'(?:[^']|'')*'/g, "''");
}

/** Contenido del paréntesis que abre en `desde` (el índice del `(`), o null si no cierra. */
function grupo(txt, desde) {
  let nivel = 0;
  for (let i = desde; i < txt.length; i++) {
    if (txt[i] === '(') nivel++;
    else if (txt[i] === ')' && --nivel === 0) return txt.slice(desde + 1, i);
  }
  return null;
}

/** Parte `expr` en las palabras OR que no están dentro de un paréntesis. */
export function terminosDeOr(expr) {
  const terminos = [];
  let nivel = 0;
  let desde = 0;
  for (let i = 0; i < expr.length; i++) {
    const ch = expr[i];
    if (ch === '(') nivel++;
    else if (ch === ')') nivel--;
    else if (nivel === 0 && /^or\b/i.test(expr.slice(i)) && /[\s)]/.test(expr[i - 1] ?? ' ')) {
      terminos.push(expr.slice(desde, i));
      desde = i + 2;
      i += 1;
    }
  }
  terminos.push(expr.slice(desde));
  return terminos.map((t) => t.trim()).filter(Boolean);
}

/** `((a))` → `a`. */
function sinParentesisExternos(e) {
  let x = e.trim();
  while (x.startsWith('(') && grupo(x, 0)?.length === x.length - 2) x = x.slice(1, -1).trim();
  return x;
}

/**
 * Las condiciones `IF NOT ( … ) THEN` (o ELSIF) donde algún término del OR es `col = uid`
 * o `uid = col` a secas, con `uid` = auth.uid() o una variable que lo guarda. Con
 * COALESCE(col, …) = uid o IS NOT DISTINCT FROM no marca. Devuelve un texto corto por
 * cada una, para mostrar.
 */
export function guardasNegadasAbiertas(cuerpo) {
  const src = soloCodigoSql(cuerpo);
  const alias = new Set();
  for (const m of src.matchAll(/(\w+)\s*(?:uuid\s*)?(?::=|\bDEFAULT\b)\s*\(?\s*(?:SELECT\s+)?auth\.uid\s*\(\s*\)/gi)) {
    alias.add(m[1].toLowerCase());
  }
  const esUid = (t) => {
    const x = sinParentesisExternos(t).toLowerCase().replace(/\s+/g, ' ');
    return x === 'auth.uid()' || x === 'select auth.uid()' || x === 'select auth.uid() as uid' || alias.has(x);
  };
  const columna = /^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)?$/i;
  const hallazgos = [];
  for (const c of src.matchAll(/\b(?:IF|ELSIF)\b([\s\S]*?)\bTHEN\b/gi)) {
    const cond = c[1];
    for (const n of cond.matchAll(/\bNOT\s*\(/gi)) {
      const interior = grupo(cond, n.index + n[0].length - 1);
      if (interior === null) continue;
      for (const termino of terminosDeOr(interior)) {
        const t = sinParentesisExternos(termino);
        if (/<>|!=|>=|<=/.test(t) || /\bIS\b/i.test(t)) continue;
        const m = /^(.+?)\s*=\s*(.+)$/s.exec(t);
        if (!m) continue;
        const izq = m[1].trim();
        const der = m[2].trim();
        if ((columna.test(izq) && esUid(der) && !esUid(izq)) || (columna.test(der) && esUid(izq) && !esUid(der))) {
          hallazgos.push(`NOT (… ${t.replace(/\s+/g, ' ').slice(0, 70)} …)`);
        }
      }
    }
  }
  return [...new Set(hallazgos)];
}
