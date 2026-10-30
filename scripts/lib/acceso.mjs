/**
 * Lo que deciden los gates de acceso (check-auth.mjs, check-rama-admin.mjs y
 * check-rpcs-definer.mjs).
 * Puro y sin dependencias: los scripts corren en CI sin node_modules, y los
 * casos viven en src/test/acceso.test.ts.
 */
import { createHash } from 'node:crypto';

// ------------------------------------------------------------------- Auth ---

/**
 * Lo que dice /auth/v1/settings y no tendría que decir (#1243). Con el signup
 * abierto cualquiera con la anon key —que viaja en el bundle— crea un usuario,
 * y handle_new_user() le arma un perfil activo.
 */
export function problemasDeSignup(settings) {
  const problemas = [];
  if (settings?.disable_signup !== true) {
    problemas.push(
      `el signup está abierto (disable_signup: ${JSON.stringify(settings?.disable_signup)}): ` +
        'cualquiera con la anon key se crea un usuario',
    );
  }
  if (settings?.external?.anonymous_users === true) {
    problemas.push('los usuarios anónimos están habilitados: cada uno nace con perfil');
  }
  return problemas;
}

const quitarComentariosSql = (src) =>
  src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ');

/**
 * Las lecturas del metadata que escribe el propio usuario en el cuerpo de una
 * función de trigger de auth.users. El nombre es la única que se tolera: no da
 * permisos. Todo lo demás (rol, sucursal, el JSON entero) sale de
 * raw_app_meta_data, que el usuario no puede escribir.
 */
export function lecturasDeMetadataDelUsuario(cuerpo) {
  const src = quitarComentariosSql(cuerpo ?? '').replace(
    /\braw_user_meta_data\s*->>\s*'nombre'/gi,
    ' ',
  );
  return [...src.matchAll(/\b(raw_user_meta_data|user_metadata)\b[^\n;]{0,40}/gi)].map((m) =>
    m[0].trim(),
  );
}

// ------------------------------------------------------------- Rama admin ---

const ADMIN = /\bes_admin\s*\(\s*\)|\bes_encargado_o_admin\s*\(\s*\)|'admin'/i;
const SUCURSAL = /sucursal/i;

/** Corta `expr` en el separador `sep` (OR) sólo donde no hay paréntesis ni comillas abiertas. */
function partirEnNivelCero(expr, sep) {
  const partes = [];
  const re = new RegExp(`^${sep}\\b`, 'i');
  let nivel = 0;
  let enComillas = false;
  let desde = 0;
  for (let i = 0; i < expr.length; i++) {
    const ch = expr[i];
    if (enComillas) {
      if (ch === "'") enComillas = false; // '' es una comilla escapada: cierra y reabre
      continue;
    }
    if (ch === "'") enComillas = true;
    else if (ch === '(') nivel++;
    else if (ch === ')') nivel--;
    else if (nivel === 0 && /\s/.test(expr[i - 1] ?? ' ') && re.test(expr.slice(i))) {
      partes.push(expr.slice(desde, i));
      i += sep.length - 1;
      desde = i + 1;
    }
  }
  partes.push(expr.slice(desde));
  return partes.map((p) => p.trim()).filter(Boolean);
}

/** Saca los paréntesis que envuelven la expresión entera: `((a) OR (b))` → `(a) OR (b)`. */
function sinParentesisExternos(expr) {
  let s = expr.trim();
  for (;;) {
    if (!s.startsWith('(') || !s.endsWith(')')) return s;
    let nivel = 0;
    let enComillas = false;
    let cierra = -1;
    for (let i = 0; i < s.length; i++) {
      const ch = s[i];
      if (enComillas) {
        if (ch === "'") enComillas = false;
        continue;
      }
      if (ch === "'") enComillas = true;
      else if (ch === '(') nivel++;
      else if (ch === ')' && --nivel === 0) {
        cierra = i;
        break;
      }
    }
    if (cierra !== s.length - 1) return s;
    s = s.slice(1, -1).trim();
  }
}

/**
 * Las ramas de una expresión de policy: sus términos unidos por OR en el nivel
 * de afuera, abriendo los paréntesis que agrupan más OR. Un término con AND es
 * una rama: `es_admin() AND sucursal_id = x` se acota entero.
 */
export function ramasDe(expr) {
  const s = sinParentesisExternos(expr ?? '');
  if (!s) return [];
  const partes = partirEnNivelCero(s, 'OR');
  if (partes.length === 1) return [s];
  return partes.flatMap(ramasDe);
}

/** Las ramas que dan acceso por ser admin (o encargado) sin mirar la sucursal. */
export function ramasAdminSinSucursal(expr) {
  return ramasDe(expr).filter((r) => ADMIN.test(r) && !SUCURSAL.test(r));
}

export const huellaPolicy = (p) =>
  createHash('md5')
    .update(`${p.using ?? ''}|${p.check ?? ''}`)
    .digest('hex');

/**
 * Las policies con una rama admin que no mira la sucursal (#1244), salvo las
 * excepciones. Una excepción exime a ESA expresión (tabla + policy + huella):
 * si la policy cambia, vuelve a salir.
 */
export function hallazgosRamaAdmin(politicas, excepciones = []) {
  const hallazgos = [];
  const conRamaAdmin = new Set();
  for (const p of politicas) {
    const ramas = [
      ...ramasAdminSinSucursal(p.using).map((rama) => ({ clausula: 'USING', rama })),
      ...ramasAdminSinSucursal(p.check).map((rama) => ({ clausula: 'WITH CHECK', rama })),
    ];
    if (!ramas.length) continue;
    conRamaAdmin.add(`${p.tabla}/${p.policy}`);
    const huella = huellaPolicy(p);
    const exc = excepciones.find((e) => e.tabla === p.tabla && e.policy === p.policy);
    if (exc && exc.huella === huella) continue;
    hallazgos.push({
      tabla: p.tabla,
      policy: p.policy,
      cmd: p.cmd,
      huella,
      ramas,
      excepcionVieja: Boolean(exc),
    });
  }
  // Una excepción de una policy que ya mira la sucursal (o que no existe más)
  // esconde el día que alguien la vuelva a escribir mal: se avisa para sacarla.
  const sobrantes = excepciones.filter((e) => !conRamaAdmin.has(`${e.tabla}/${e.policy}`));
  return { hallazgos, sobrantes };
}

// ----------------------------------------------------------- RPCs definer ---

/**
 * Lo que es rojo en la salida de auditoria_rpcs_definer() (#1291). El texto de
 * cada función lo mira el RPC; acá sólo se decide.
 *
 *  · gestion: una RPC que escribe la gestión de usuarios (quién es de qué
 *    sucursal, su rol, su bot) sin acotar al usuario. Sin excepciones: es la
 *    clase de #1291.
 *  · parametros: un parámetro de usuario o de sucursal sin acotar que no está
 *    en `permitidas` ({ 'funcion.parametro': motivo }). Va por nombre y no por
 *    firma: cambiarle la firma a una función no la saca de la lista.
 *  · sobrantes: las permitidas que ya no hacen falta (el parámetro se acota o
 *    la función no existe más). Se avisan para sacarlas; no son rojo.
 */
export function hallazgosRpcsDefiner(auditoria, permitidas = {}) {
  const clave = (p) => `${p.nombre}.${p.parametro}`;
  const sinAcotar = (auditoria?.parametros ?? []).filter((p) => !p.acotado);
  const vistas = new Set(sinAcotar.map(clave));
  return {
    gestion: (auditoria?.gestion_usuarios ?? []).filter((g) => !g.acota),
    parametros: sinAcotar.filter((p) => !Object.hasOwn(permitidas, clave(p))),
    sobrantes: Object.keys(permitidas).filter((k) => !vistas.has(k)),
  };
}
