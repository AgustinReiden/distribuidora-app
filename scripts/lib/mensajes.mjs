/**
 * Mensajes de error de los triggers que filtran datos (#1564, 1564-g3).
 * Puro y sin dependencias: lo usa check-mensajes-trigger.mjs y lo prueban los casos de
 * src/test/catalogo.test.ts.
 *
 * El defecto: un trigger BEFORE corre antes de que la FK o la policy cierren el cruce
 * de sucursal, y si su `RAISE EXCEPTION` interpola un dato que lee con el id que mandó
 * quien llama (el nombre del cliente de un `NEW.cliente_id`, el nombre de un
 * `NEW.transportista_id`), el mensaje le muestra a un usuario datos de una fila que no
 * puede ver: por ahí un preventista sondeaba clientes de otra sucursal (#1559). Un
 * mensaje que dice «el pedido #12 está cancelado» con el id que el mismo usuario mandó
 * no filtra nada; el que dice el nombre, el teléfono o el saldo de otro, sí.
 *
 * Qué marca:
 *   · un RAISE que interpola un dato PERSONAL (nombre, razón social, email, teléfono,
 *     CUIT, dirección…) leído de otra tabla de personas (clientes, perfiles, proveedores,
 *     empleados), sea con un subselect adentro o con una variable que se llenó con un
 *     SELECT … INTO;
 *   · un RAISE que interpola una columna financiera sensible (costo*, saldo*, sueldo,
 *     comision*, margen*, limite_credito, password, token…), de NEW/OLD o de una variable;
 *   · un RAISE que vuelca la fila entera (NEW, OLD, to_jsonb(NEW), row_to_json, NEW::text).
 *
 * Lo que NO ve: un dato que llega por otra función (`RAISE … , public.quien_es(NEW.x)`),
 * el SQL dinámico y un alias de dos saltos. Es texto, no ejecución.
 */

const TABLAS_PERSONALES = /^(clientes|perfiles|proveedores|empleados|usuarios|bot_usuarios|vendedores|transportistas)$/i;
const COLUMNAS_PERSONALES = /^(nombre|nombres|razon_social|nombre_fantasia|email|telefono|celular|cuit|cuil|dni|direccion|domicilio|apellido)$/i;
const COLUMNAS_SENSIBLES =
  /^(costo\w*|precio_costo\w*|saldo\w*|sueldo\w*|comision\w*|margen\w*|limite_credito|password\w*|token\w*|secret\w*|api_key\w*)$/i;

/** Saca los comentarios (deja los literales: el mensaje es lo que hay que leer). */
const sinComentarios = (src) => String(src ?? '').replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ');

/** Parte `txt` en las comas de nivel cero (sin paréntesis ni comillas abiertos). */
function partirComas(txt) {
  const partes = [];
  let nivel = 0;
  let comillas = false;
  let desde = 0;
  for (let i = 0; i < txt.length; i++) {
    const ch = txt[i];
    if (comillas) {
      if (ch === "'") comillas = false;
      continue;
    }
    if (ch === "'") comillas = true;
    else if (ch === '(') nivel++;
    else if (ch === ')') nivel--;
    else if (ch === ',' && nivel === 0) {
      partes.push(txt.slice(desde, i));
      desde = i + 1;
    }
  }
  partes.push(txt.slice(desde));
  return partes.map((p) => p.trim()).filter(Boolean);
}

/** Variables que un `SELECT expr INTO v FROM tabla` o `v := (SELECT expr FROM tabla …)` llena. */
function variablesDeSelect(src) {
  const vars = new Map();
  for (const m of src.matchAll(/\bSELECT\b([^;]*?)\bINTO\b\s+(?:STRICT\s+)?([a-z_][a-z0-9_]*)\s+\bFROM\b\s+(?:public\.)?([a-z_][a-z0-9_]*)/gi)) {
    vars.set(m[2].toLowerCase(), { tabla: m[3].toLowerCase(), expr: m[1].trim() });
  }
  for (const m of src.matchAll(/\b([a-z_][a-z0-9_]*)\s*:=\s*\(\s*SELECT\b([^;]*?)\bFROM\b\s+(?:public\.)?([a-z_][a-z0-9_]*)/gi)) {
    vars.set(m[1].toLowerCase(), { tabla: m[3].toLowerCase(), expr: m[2].trim() });
  }
  return vars;
}

/** Las columnas que nombra una expresión (`c.nombre`, `razon_social`, `nombre || ' x'`). */
function columnasDe(expr) {
  return [...String(expr).matchAll(/(?:\b[a-z_][a-z0-9_]*\.)?\b([a-z_][a-z0-9_]*)\b/gi)].map((m) => m[1].toLowerCase());
}

/**
 * Los RAISE de `cuerpo` que filtran datos. Devuelve un texto por cada uno:
 * «RAISE '<mensaje>' interpola <qué>».
 */
export function mensajesQueFiltran(cuerpo) {
  const src = sinComentarios(cuerpo);
  const vars = variablesDeSelect(src);
  const hallazgos = [];
  for (const m of src.matchAll(/\bRAISE\s+(?:EXCEPTION|WARNING|NOTICE|INFO|LOG|DEBUG)?\s*('(?:[^']|'')*')\s*([^;]*);/gis)) {
    const mensaje = m[1].replace(/\s+/g, ' ').slice(0, 70);
    const resto = m[2].trim();
    if (!resto) continue;
    const usingAt = resto.search(/\bUSING\b/i);
    const args = usingAt === -1 ? resto : resto.slice(0, usingAt);
    const using = usingAt === -1 ? '' : resto.slice(usingAt);
    const expresiones = [...partirComas(args.replace(/^,/, '')), ...(using ? [using] : [])];
    const dichos = new Set();
    const decir = (q) => {
      if (!dichos.has(q)) {
        dichos.add(q);
        hallazgos.push(`RAISE ${mensaje} interpola ${q}`);
      }
    };
    for (const e of expresiones) {
      const x = e.replace(/\s+/g, ' ');
      // La fila entera.
      if (/(^|[\s,(])(NEW|OLD)\s*(::\w+)?\s*($|[\s,)])/.test(x) || /\b(to_jsonb|to_json|row_to_json|jsonb_build_object)\s*\(\s*(NEW|OLD)\b/i.test(x)) {
        decir('la fila entera (NEW/OLD)');
      }
      // NEW.col / OLD.col.
      for (const c of x.matchAll(/\b(?:NEW|OLD)\.([a-z_][a-z0-9_]*)/gi)) {
        if (COLUMNAS_SENSIBLES.test(c[1])) decir(`${c[0]} (columna sensible)`);
      }
      // Un subselect adentro: `(SELECT nombre FROM public.perfiles WHERE …)`.
      for (const s of x.matchAll(/\(\s*SELECT\b(.*?)\bFROM\b\s+(?:public\.)?([a-z_][a-z0-9_]*)/gi)) {
        const tabla = s[2].toLowerCase();
        const cols = columnasDe(s[1]);
        if (TABLAS_PERSONALES.test(tabla) && cols.some((c) => COLUMNAS_PERSONALES.test(c))) decir(`un dato personal de ${tabla} (${s[1].trim()})`);
        else if (cols.some((c) => COLUMNAS_SENSIBLES.test(c))) decir(`una columna sensible de ${tabla} (${s[1].trim()})`);
      }
      // Una variable que se llenó con un SELECT … INTO.
      for (const id of x.matchAll(/\b([a-z_][a-z0-9_]*)\b/gi)) {
        const v = vars.get(id[1].toLowerCase());
        if (!v) continue;
        const cols = columnasDe(v.expr);
        if (TABLAS_PERSONALES.test(v.tabla) && cols.some((c) => COLUMNAS_PERSONALES.test(c))) decir(`un dato personal de ${v.tabla} (${id[1]} ← ${v.expr})`);
        else if (cols.some((c) => COLUMNAS_SENSIBLES.test(c))) decir(`una columna sensible de ${v.tabla} (${id[1]} ← ${v.expr})`);
      }
    }
  }
  return hallazgos;
}
