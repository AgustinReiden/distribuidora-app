// Punto de entrada único al modelo del agente (#979, PR 3a).
//
// `generar()` recibe una request en formato Gemini (el que usa todo el bot) y
// la manda al proveedor del modelo elegido; devuelve la respuesta en el mismo
// formato y lo que costó. agent.ts y el digest no saben qué proveedor hay
// detrás.

import type {
  GeminiGenerateContentRequest,
  GeminiGenerateContentResponse,
} from "../gemini/types.ts";
import { callGemini } from "../gemini/client.ts";
import { callOpenAI } from "./openai.ts";
import { costoUsd, modeloActivo, proveedorDe } from "./modelo.ts";

export { modeloActivo, modeloFallback, proveedorDe } from "./modelo.ts";

export interface Generacion {
  response: GeminiGenerateContentResponse;
  modelo: string;
  costoUsd: number;
}

export interface GenerarOpciones {
  /** Default: modeloActivo() (BOT_LLM_MODEL). */
  modelo?: string;
  /**
   * Para el loop del agente: aplica el razonamiento acotado de
   * `razonamientoGemini`. El digest y el escáner ya fijan el suyo.
   */
  razonamientoAcotado?: boolean;
}

export async function generar(
  req: GeminiGenerateContentRequest,
  opts: GenerarOpciones = {},
): Promise<Generacion> {
  const modelo = opts.modelo ?? modeloActivo();
  let response: GeminiGenerateContentResponse;
  if (proveedorDe(modelo) === "openai") {
    response = await callOpenAI(req, modelo);
  } else {
    const thinking = opts.razonamientoAcotado ? razonamientoGemini(modelo) : undefined;
    const conThinking: GeminiGenerateContentRequest = thinking && !req.generationConfig?.thinkingConfig
      ? { ...req, generationConfig: { ...req.generationConfig, thinkingConfig: thinking } }
      : req;
    response = await callGemini(conThinking, { model: modelo });
  }
  const u = response.usageMetadata ?? {};
  return {
    response,
    modelo,
    costoUsd: costoUsd(modelo, {
      entrada: u.promptTokenCount ?? 0,
      entradaCacheada: u.cachedContentTokenCount ?? 0,
      // Gemini informa el razonamiento aparte; OpenAI lo trae adentro de
      // completion_tokens y openai.ts no completa thoughtsTokenCount.
      salida: (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0),
    }),
  };
}

/**
 * Razonamiento del loop del agente en Gemini (B2 del plan). Se cobra como
 * salida, que vale 8 veces la entrada, y en el registro real se comía la
 * mayor parte del costo de cada consulta.
 *
 *   * 2.5: `thinkingBudget` en tokens. Default 512, acotado y no apagado:
 *     elegir herramienta y argumentos es justo lo que el razonamiento ayuda a
 *     hacer bien. BOT_THINKING_BUDGET lo cambia (0 lo apaga, -1 vuelve al
 *     dinámico).
 *   * 3.x: `thinkingLevel`, sólo si está BOT_THINKING_LEVEL. Un valor que el
 *     modelo no acepta tira la request entera, así que sin la variable se
 *     deja el default del modelo.
 */
export function razonamientoGemini(
  modelo: string,
): { thinkingBudget?: number; thinkingLevel?: string } | undefined {
  // Flash-Lite no razona por defecto: un budget lo encendería y el modo
  // "barato" del techo de gasto saldría más caro.
  if (modelo.startsWith("gemini-2.5") && !modelo.includes("-lite")) {
    const raw = Deno.env.get("BOT_THINKING_BUDGET");
    const n = raw === undefined || raw.trim() === "" ? 512 : parseInt(raw, 10);
    if (!Number.isFinite(n) || n < -1 || n > 24576) return { thinkingBudget: 512 };
    return n === -1 ? undefined : { thinkingBudget: n };
  }
  if (modelo.startsWith("gemini-2.5")) return undefined;
  const nivel = Deno.env.get("BOT_THINKING_LEVEL")?.trim();
  return nivel ? { thinkingLevel: nivel } : undefined;
}
