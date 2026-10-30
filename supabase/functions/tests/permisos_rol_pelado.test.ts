// Gate de #1312: ninguna edge function decide permisos leyendo `perfiles.rol`
// pelado.
//
// `perfiles.rol` es el rol BASE. Los roles extra viven en `perfil_roles` (mig
// 155) y el rol propio de una sucursal en `usuario_sucursales.rol`, y la base
// los junta en `es_transportista()`, `es_preventista()` y compañía. Una edge
// function que compara `perfiles.rol` contra una lista no ve nada de eso: así
// optimizar-ruta les daba 403 a los choferes con el transportista como extra.
// La forma de preguntar es la misma que la base, con la sesión del usuario
// (ver optimizar-ruta/auth.ts).
//
// El test recorre supabase/functions (menos tests/) y falla ante cualquier
// lectura de `perfiles` que pida la columna `rol` o filtre por ella, salvo las
// excepciones de abajo, cada una con su motivo. La lista sólo se achica: una
// excepción que ya no aparece en su archivo también falla.
import { assertEquals } from "std/assert/mod.ts";

const RAIZ = new URL("../", import.meta.url).pathname.replace(/^\/([A-Z]:)/, "$1");

const EXCEPCIONES: Record<string, string> = {
  "escanear-factura/auth.ts":
    "Exige admin o encargado en la sucursal activa (con usuario_sucursales.rol). " +
    "perfil_roles sólo puede dar transportista (CHECK de la tabla), así que un extra no habilita nada acá.",
  "_shared/llm/presupuesto.ts":
    "Elige a qué admins avisarles del presupuesto del LLM: no autoriza a nadie.",
  "_eval/correr.ts":
    "Herramienta local de evaluación: elige usuarios de prueba por rol, no corre en prod.",
  "telegram-digest/vencimientos.ts":
    "Elige a qué encargados y depósitos mandarles el aviso de vencimientos: no autoriza a nadie.",
};

async function archivosTs(dir: string, rel = ""): Promise<string[]> {
  const salida: string[] = [];
  for await (const e of Deno.readDir(`${dir}${rel}`)) {
    const ruta = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory) {
      if (ruta === "tests" || e.name === "node_modules") continue;
      salida.push(...await archivosTs(dir, ruta));
    } else if (e.isFile && ruta.endsWith(".ts")) {
      salida.push(ruta);
    }
  }
  return salida;
}

/**
 * Cada consulta a `perfiles` (hasta el `;` que la cierra) que pide o filtra por
 * `rol`, y cada embed de `perfiles` que lo pide o lo filtra
 * (`perfiles!inner(rol, …)`, `.in("perfiles.rol", …)`).
 */
export function lecturasDeRol(texto: string): string[] {
  const hallazgos: string[] = [];
  const embed =
    /perfiles(?:![a-z_]+)?\(\s*[^)]*\brol\b[^)]*\)|\.(?:eq|in|neq)\(\s*["'`]perfiles\.rol["'`]/g;
  for (const m of texto.matchAll(embed)) hallazgos.push(m[0]);
  const desde = /\.from\(\s*["'`]perfiles["'`]\s*\)/g;
  for (const m of texto.matchAll(desde)) {
    const inicio = m.index ?? 0;
    const fin = texto.indexOf(";", inicio);
    const consulta = texto.slice(inicio, fin === -1 ? undefined : fin);
    const pideRol = /\.select\(\s*["'`][^"'`]*\brol\b/.test(consulta);
    const filtraRol = /\.(eq|in|neq)\(\s*["'`]rol["'`]/.test(consulta);
    if (pideRol || filtraRol) hallazgos.push(consulta.replace(/\s+/g, " ").trim());
  }
  return hallazgos;
}

Deno.test("lecturasDeRol: detecta select y filtro por rol, y no la lectura sin rol", () => {
  assertEquals(lecturasDeRol(`x.from("perfiles").select("rol").eq("id", u);`).length, 1);
  assertEquals(lecturasDeRol(`x.from('perfiles')\n .select('id, rol, activo');`).length, 1);
  assertEquals(lecturasDeRol(`x.from("perfiles").select("id").eq("rol", "admin");`).length, 1);
  assertEquals(lecturasDeRol(`x.from("perfiles").select("id, nombre").in("id", ids);`).length, 0);
  assertEquals(lecturasDeRol(`x.from("perfiles").select("id, rolito");`).length, 0);
  assertEquals(lecturasDeRol(`x.select("id, perfiles!inner(rol, activo)");`).length, 1);
  assertEquals(lecturasDeRol(`x.select("id").in("perfiles.rol", ["admin"]);`).length, 1);
  assertEquals(lecturasDeRol(`x.select("id, perfiles(nombre)");`).length, 0);
});

Deno.test("ninguna edge function decide permisos con perfiles.rol pelado (#1312)", async () => {
  const conRol: Record<string, string[]> = {};
  for (const archivo of await archivosTs(RAIZ)) {
    const lecturas = lecturasDeRol(await Deno.readTextFile(`${RAIZ}${archivo}`));
    if (lecturas.length > 0) conRol[archivo] = lecturas;
  }

  const nuevos = Object.keys(conRol).filter((a) => !(a in EXCEPCIONES));
  assertEquals(
    nuevos,
    [],
    `Leen perfiles.rol sin estar en EXCEPCIONES: ${
      JSON.stringify(nuevos.map((a) => [a, conRol[a]]))
    }. ` +
      "Un rol extra (perfil_roles) o el de la sucursal no se ven así: preguntale a la base con la sesión del usuario.",
  );

  const viejas = Object.keys(EXCEPCIONES).filter((a) => !(a in conRol));
  assertEquals(viejas, [], `Excepciones que ya no leen perfiles.rol: sacalas de la lista.`);
});
