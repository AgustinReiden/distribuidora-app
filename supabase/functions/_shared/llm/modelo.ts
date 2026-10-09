// Qué modelo usa el agente y cuánto cuesta (#979, PR 3a).
//
// El modelo se elige con una variable de entorno y no con código, para poder
// cambiarlo (o volver atrás) sin deploy:
//   * BOT_LLM_MODEL           — el modelo del agente. Si no está, GEMINI_MODEL
//                               (la variable de antes) y si tampoco, el de
//                               siempre: gemini-2.5-flash.
//   * BOT_LLM_MODEL_FALLBACK  — el más barato, para cuando se agota el
//                               presupuesto del mes (presupuesto.ts).
//
// El proveedor sale del nombre: "gpt-*" y "o<n>*" van a la API de OpenAI (o a
// una compatible, con OPENAI_BASE_URL); el resto, a Gemini.

export type Proveedor = "gemini" | "openai";

export const MODELO_DEFAULT = "gemini-2.5-flash";
export const MODELO_FALLBACK_DEFAULT = "gemini-2.5-flash-lite";

export function modeloActivo(): string {
  return limpio(Deno.env.get("BOT_LLM_MODEL")) ?? limpio(Deno.env.get("GEMINI_MODEL")) ??
    MODELO_DEFAULT;
}

export function modeloFallback(): string {
  return limpio(Deno.env.get("BOT_LLM_MODEL_FALLBACK")) ?? MODELO_FALLBACK_DEFAULT;
}

export function proveedorDe(modelo: string): Proveedor {
  return /^(gpt-|o\d)/i.test(modelo) ? "openai" : "gemini";
}

function limpio(v: string | undefined): string | null {
  const t = v?.trim();
  return t ? t : null;
}

// ----------------------------------------------------------------------------
// Precios (USD por millón de tokens). Fuente: páginas oficiales de Google y
// OpenAI consultadas el 2026-10-07 (plan del bot, decisión del dueño). Si un
// proveedor cambia la tarifa, se cambia ACÁ; el techo mensual se calcula con
// esto y con el uso que devuelve cada respuesta.
// ----------------------------------------------------------------------------

export interface Precio {
  entrada: number;
  entradaCacheada: number;
  /** Incluye el razonamiento: los dos proveedores lo cobran como salida. */
  salida: number;
}

// Por prefijo, del más específico al más general: "gemini-2.5-flash-lite"
// tiene que ganarle a "gemini-2.5-flash".
const PRECIOS: Array<[prefijo: string, precio: Precio]> = [
  ["gpt-6-luna", { entrada: 0.10, entradaCacheada: 0.01, salida: 0.50 }],
  ["gpt-5.6-luna", { entrada: 0.20, entradaCacheada: 0.02, salida: 1.20 }],
  ["gpt-5-nano", { entrada: 0.05, entradaCacheada: 0.005, salida: 0.40 }],
  ["gemini-2.5-flash-lite", { entrada: 0.10, entradaCacheada: 0.01, salida: 0.40 }],
  ["gemini-2.5-flash", { entrada: 0.30, entradaCacheada: 0.03, salida: 2.50 }],
  // 3.5 Flash-Lite cuesta lo mismo que 2.5 Flash (plan, 2026-10-07).
  ["gemini-3.5-flash-lite", { entrada: 0.30, entradaCacheada: 0.03, salida: 2.50 }],
];

/**
 * Un modelo que no está en la tabla se cobra como el más caro de la tabla:
 * equivocarse para arriba adelanta el aviso del techo; para abajo, lo pasa
 * de largo sin que nadie se entere.
 */
const PRECIO_DESCONOCIDO: Precio = PRECIOS.reduce(
  (max, [, p]) => (p.salida > max.salida ? p : max),
  PRECIOS[0][1],
);

export function precioDe(modelo: string): { precio: Precio; conocido: boolean } {
  const m = modelo.toLowerCase();
  const hit = PRECIOS.find(([prefijo]) => m.startsWith(prefijo));
  return hit ? { precio: hit[1], conocido: true } : { precio: PRECIO_DESCONOCIDO, conocido: false };
}

export interface UsoTokens {
  entrada: number;
  entradaCacheada: number;
  salida: number;
}

export function costoUsd(modelo: string, uso: UsoTokens): number {
  const { precio } = precioDe(modelo);
  const sinCache = Math.max(0, uso.entrada - uso.entradaCacheada);
  return (sinCache * precio.entrada + uso.entradaCacheada * precio.entradaCacheada +
    uso.salida * precio.salida) / 1_000_000;
}
