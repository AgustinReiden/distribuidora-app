// Puntaje de un caso de la evaluación (#979): funciones puras, sin red, para
// poder probarlas. `correr.ts` las usa con lo que devuelve `runAgent`.

import type { ArgEsperado, CasoEval } from "./casos.ts";
import { numerosInventados } from "./numeros.ts";

export interface ToolCallEval {
  name: string;
  args: Record<string, unknown>;
  ok: boolean;
  data?: unknown;
}

export interface Evaluacion {
  eleccionOk: boolean;
  argsOk: boolean;
  prohibidasOk: boolean;
  sinPreguntaOk: boolean;
  inventados: number[];
  /** Pasa elección, args, prohibidas y no-repregunta. Los inventados se miran aparte. */
  ok: boolean;
  motivos: string[];
}

const TZ = "America/Argentina/Buenos_Aires";

/** YYYY-MM-DD de `ahora` en Buenos Aires. */
export function hoyAR(ahora: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(ahora);
}

function sumarDias(fecha: string, dias: number): string {
  const [y, m, d] = fecha.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + dias)).toISOString().slice(0, 10);
}

/** Resuelve los marcadores de fecha ("{hoy}" etc.). Devuelve null si no es un marcador. */
export function resolverFecha(token: string, hoy: string): string | null {
  const [y, m] = hoy.split("-").map(Number);
  switch (token) {
    case "{hoy}":
      return hoy;
    case "{ayer}":
      return sumarDias(hoy, -1);
    case "{hace30}":
      return sumarDias(hoy, -30);
    case "{inicioMes}":
      return `${hoy.slice(0, 8)}01`;
    case "{mesPasadoDesde}":
      return new Date(Date.UTC(y, m - 2, 1)).toISOString().slice(0, 10);
    case "{mesPasadoHasta}":
      return new Date(Date.UTC(y, m - 1, 0)).toISOString().slice(0, 10);
    default:
      return null;
  }
}

const norm = (s: unknown) => String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

function difDias(a: string, b: string): number {
  return Math.abs(Date.parse(a) - Date.parse(b)) / 86_400_000;
}

/** ¿El argumento real cumple lo esperado? */
export function argCoincide(esperado: ArgEsperado, real: unknown, hoy: string): boolean {
  if (real === undefined || real === null) return false;
  if (typeof esperado === "object") return norm(real).includes(norm(esperado.contiene));
  if (typeof esperado === "boolean") return real === esperado;
  if (typeof esperado === "number") return Number(real) === esperado;
  const fecha = resolverFecha(esperado, hoy);
  if (fecha) {
    if (typeof real !== "string") return false;
    // "últimos 30 días" admite 29 o 31: el modelo cuenta desde ayer o desde hoy.
    const margen = esperado === "{hace30}" ? 2 : 0;
    return /^\d{4}-\d{2}-\d{2}$/.test(real) && difDias(real, fecha) <= margen;
  }
  return norm(real) === norm(esperado);
}

function argsCumplen(
  esperados: Record<string, ArgEsperado>,
  reales: Record<string, unknown>,
  hoy: string,
): boolean {
  return Object.entries(esperados).every(([k, v]) => argCoincide(v, reales[k], hoy));
}

export function evaluarCaso(
  caso: CasoEval,
  texto: string,
  toolCalls: ToolCallEval[],
  hoy: string,
): Evaluacion {
  const motivos: string[] = [];
  const nombres = toolCalls.map((t) => t.name);

  const eleccionOk = caso.ninguna
    ? toolCalls.length === 0
    : toolCalls.some((t) => caso.herramientas.includes(t.name));
  if (!eleccionOk) {
    motivos.push(
      caso.ninguna
        ? `llamó a herramientas (${nombres.join(", ")}) y no debía`
        : `no llamó a ninguna de: ${caso.herramientas.join(", ")}`,
    );
  }

  let argsOk = true;
  if (caso.args && !caso.ninguna) {
    const candidatas = toolCalls.filter((t) => caso.herramientas.includes(t.name));
    argsOk = candidatas.some((t) => argsCumplen(caso.args!, t.args, hoy));
    if (!argsOk) motivos.push(`argumentos distintos a ${JSON.stringify(caso.args)}`);
  }

  const llamadasProhibidas = (caso.prohibidas ?? []).filter((p) => nombres.includes(p));
  const prohibidasOk = llamadasProhibidas.length === 0;
  if (!prohibidasOk) {
    motivos.push(`llamó a herramientas prohibidas: ${llamadasProhibidas.join(", ")}`);
  }

  let sinPreguntaOk = true;
  if (caso.debeResponderSinPreguntar) {
    const trajoDatos = toolCalls.some((t) => t.ok && t.data !== undefined && t.data !== null);
    sinPreguntaOk = !(texto.trim().endsWith("?") && !trajoDatos);
    if (!sinPreguntaOk) motivos.push("repreguntó cuando había un default razonable");
  }

  const inventados = numerosInventados(
    texto,
    toolCalls.filter((t) => t.ok).map((t) => t.data),
  );

  return {
    eleccionOk,
    argsOk,
    prohibidasOk,
    sinPreguntaOk,
    inventados,
    ok: eleccionOk && argsOk && prohibidasOk && sinPreguntaOk,
    motivos,
  };
}
