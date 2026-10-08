// Adaptador a la API de chat de OpenAI (#979, PR 3a).
//
// El agente piensa en formato Gemini: la memoria (`bot_conversaciones`) guarda
// `GeminiContent[]` y el loop de agent.ts lee respuestas de Gemini. En vez de
// reescribir todo eso, este módulo traduce en los dos sentidos:
//   request Gemini → /v1/chat/completions → respuesta con forma de Gemini.
// Así la memoria de un chat sobrevive a un cambio de modelo, y volver atrás
// es cambiar una variable de entorno.
//
// Compatible con cualquier API que hable el mismo dialecto (OpenRouter, por
// ejemplo) vía OPENAI_BASE_URL.
//
// Tres decisiones a propósito:
//   * Los ids de tool_call se fabrican por posición (`c<turno>_<n>`). Gemini
//     no tiene ids y la memoria tampoco: alcanza con que cada `tool` apunte al
//     id de la llamada que contesta, y eso sale del orden.
//   * No se manda `temperature`: los modelos de OpenAI que razonan sólo
//     aceptan el valor por defecto y rechazan la request entera con otro.
//   * El esfuerzo de razonamiento sale de BOT_REASONING_EFFORT o, si no está,
//     de `reasoningEffortDefault` (sólo los modelos que lo exigen). Un valor
//     que el modelo no conoce tira la request y dejaría al bot mudo.

import type {
  GeminiContent,
  GeminiGenerateContentRequest,
  GeminiGenerateContentResponse,
  GeminiPart,
} from "../gemini/types.ts";
import { isFunctionCallPart, isFunctionResponsePart, isTextPart } from "../gemini/types.ts";

const OPENAI_BASE_DEFAULT = "https://api.openai.com/v1";

export class OpenAIError extends Error {
  status?: number;
  constructor(message: string, status?: number) {
    super(message);
    this.name = "OpenAIError";
    this.status = status;
  }
}

// deno-lint-ignore no-explicit-any
type Msg = Record<string, any>;

/** Request de Gemini → body de /chat/completions. Exportada para los tests. */
export function aChatCompletions(
  req: GeminiGenerateContentRequest,
  modelo: string,
  reasoningEffort?: string,
): Record<string, unknown> {
  const messages: Msg[] = [];
  const sistema = (req.system_instruction?.parts ?? []).map((p) => p.text).join("\n\n");
  if (sistema) messages.push({ role: "system", content: sistema });

  // Ids de las llamadas del último turno del modelo, para que las respuestas
  // del turno siguiente apunten a la suya. Por nombre y en orden: si el
  // modelo llamó dos veces a la misma herramienta, la primera respuesta con
  // ese nombre es de la primera llamada.
  let pendientes: Array<{ id: string; name: string }> = [];
  // OpenAI rechaza la request ENTERA si una tool_call queda sin su mensaje
  // `tool` antes del próximo mensaje. Una llamada sin respuesta en la memoria
  // (un turno cortado, una respuesta que no coincide) se contesta con un
  // error en vez de dejar al chat trabado para siempre.
  const cerrarPendientes = () => {
    for (const { id } of pendientes) {
      messages.push({ role: "tool", tool_call_id: id, content: JSON.stringify({ error: "sin respuesta" }) });
    }
    pendientes = [];
  };

  req.contents.forEach((c: GeminiContent, turno: number) => {
    if (c.role === "model") {
      cerrarPendientes();
      const texto = c.parts.filter(isTextPart).map((p) => p.text).join("");
      const llamadas = c.parts.filter(isFunctionCallPart).map((p, n) => ({
        id: `c${turno}_${n}`,
        name: p.functionCall.name,
        args: p.functionCall.args ?? {},
      }));
      // Un turno del modelo vacío (Gemini lo guarda tras un STOP silencioso o
      // un MALFORMED_FUNCTION_CALL) no se manda: un assistant sin content ni
      // tool_calls también tira la request entera.
      if (!texto && llamadas.length === 0) return;
      pendientes = llamadas.map(({ id, name }) => ({ id, name }));
      const m: Msg = { role: "assistant", content: texto || null };
      if (llamadas.length > 0) {
        m.tool_calls = llamadas.map((l) => ({
          id: l.id,
          type: "function",
          function: { name: l.name, arguments: JSON.stringify(l.args) },
        }));
      }
      messages.push(m);
      return;
    }

    // role "user": texto del usuario, o respuestas de herramientas.
    const respuestas = c.parts.filter(isFunctionResponsePart);
    for (const r of respuestas) {
      const i = pendientes.findIndex((p) => p.name === r.functionResponse.name);
      // Una respuesta sin llamada no se puede mandar a OpenAI (rechaza toda la
      // request). memory.ts ya evita ese estado; esto es la última defensa.
      if (i === -1) continue;
      const [{ id }] = pendientes.splice(i, 1);
      messages.push({
        role: "tool",
        tool_call_id: id,
        content: JSON.stringify(r.functionResponse.response),
      });
    }
    const texto = c.parts.filter(isTextPart).map((p) => p.text).join("");
    if (texto) {
      cerrarPendientes();
      messages.push({ role: "user", content: texto });
    }
  });
  cerrarPendientes();

  const body: Record<string, unknown> = { model: modelo, messages };
  const decls = req.tools?.flatMap((t) => t.function_declarations) ?? [];
  if (decls.length > 0) {
    body.tools = decls.map((d) => ({
      type: "function",
      function: { name: d.name, description: d.description, parameters: d.parameters },
    }));
    const modo = req.tool_config?.function_calling_config.mode;
    body.tool_choice = modo === "NONE" ? "none" : modo === "ANY" ? "required" : "auto";
  }
  // En OpenAI el razonamiento sale de este mismo tope: con el de Gemini
  // (2048) un modelo que razona puede gastarlo entero y devolver vacío. Se
  // duplica, con piso de 4096; sólo se cobra lo que se usa.
  const max = req.generationConfig?.maxOutputTokens;
  if (max) body.max_completion_tokens = Math.max(max * 2, 4096);
  if (reasoningEffort) body.reasoning_effort = reasoningEffort;
  return body;
}

const FINISH: Record<string, string> = {
  stop: "STOP",
  tool_calls: "STOP",
  function_call: "STOP",
  length: "MAX_TOKENS",
  content_filter: "SAFETY",
};

/** Respuesta de /chat/completions → forma de Gemini. Exportada para los tests. */
export function deChatCompletions(json: unknown): GeminiGenerateContentResponse {
  const r = (json ?? {}) as Msg;
  const choice = Array.isArray(r.choices) ? r.choices[0] : undefined;
  const usage = (r.usage ?? {}) as Msg;
  const usageMetadata = {
    promptTokenCount: Number(usage.prompt_tokens ?? 0),
    cachedContentTokenCount: Number(usage.prompt_tokens_details?.cached_tokens ?? 0),
    // completion_tokens YA incluye el razonamiento en OpenAI: no se suma aparte.
    candidatesTokenCount: Number(usage.completion_tokens ?? 0),
    totalTokenCount: Number(usage.total_tokens ?? 0),
  };
  if (!choice) {
    return { candidates: [], usageMetadata, promptFeedback: { blockReason: "no_choice" } };
  }

  const msg = (choice.message ?? {}) as Msg;
  const parts: GeminiPart[] = [];
  if (typeof msg.content === "string" && msg.content.length > 0) {
    parts.push({ text: msg.content });
  }
  let malformada = false;
  for (const tc of (Array.isArray(msg.tool_calls) ? msg.tool_calls : []) as Msg[]) {
    let args: Record<string, unknown> = {};
    try {
      const parsed = JSON.parse(tc.function?.arguments || "{}");
      if (parsed && typeof parsed === "object") args = parsed;
    } catch {
      // Mismo trato que Gemini con un JSON que no valida: el agente da un
      // mensaje accionable en vez de llamar a la herramienta con basura.
      malformada = true;
      continue;
    }
    parts.push({ functionCall: { name: String(tc.function?.name ?? ""), args } });
  }

  return {
    candidates: [{
      content: { role: "model", parts },
      finishReason: malformada && parts.length === 0
        ? "MALFORMED_FUNCTION_CALL"
        : FINISH[String(choice.finish_reason)] ?? String(choice.finish_reason ?? "STOP"),
    }],
    usageMetadata,
  };
}

/**
 * Esfuerzo de razonamiento por defecto según el modelo, cuando no hay
 * BOT_REASONING_EFFORT. gpt-6-luna rechaza la request entera si se le mandan
 * herramientas por /chat/completions con otro valor que "none" (medido en la
 * evaluación del 2026-10-08: "Function tools with reasoning_effort are not
 * supported for gpt-6-luna in /v1/chat/completions ... set reasoning_effort
 * to 'none'"). Para el resto, nada: un valor que el modelo no conoce también
 * tira la request.
 */
export function reasoningEffortDefault(modelo: string): string | undefined {
  return modelo.toLowerCase().startsWith("gpt-6-luna") ? "none" : undefined;
}

function backoffMs(intento: number): number {
  return 500 * Math.pow(2, intento) + Math.random() * 200;
}

/** Una request, con los mismos reintentos que el cliente de Gemini (429 y 5xx). */
export async function callOpenAI(
  req: GeminiGenerateContentRequest,
  modelo: string,
  maxRetries = 2,
): Promise<GeminiGenerateContentResponse> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new OpenAIError("OPENAI_API_KEY not set");
  const base = (Deno.env.get("OPENAI_BASE_URL") ?? OPENAI_BASE_DEFAULT).replace(/\/+$/, "");
  const effort = Deno.env.get("BOT_REASONING_EFFORT")?.trim() || reasoningEffortDefault(modelo);
  const body = JSON.stringify(aChatCompletions(req, modelo, effort));

  let ultimo: unknown = null;
  for (let intento = 0; intento <= maxRetries; intento++) {
    let res: Response;
    try {
      res = await fetch(`${base}/chat/completions`, {
        method: "POST",
        headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body,
      });
    } catch (err) {
      ultimo = err;
      if (intento < maxRetries) {
        await new Promise((r) => setTimeout(r, backoffMs(intento)));
        continue;
      }
      break;
    }
    if (res.ok) return deChatCompletions(await res.json());
    const texto = await res.text().catch(() => "<unparseable>");
    const err = new OpenAIError(`OpenAI ${res.status}: ${texto.slice(0, 500)}`, res.status);
    if ((res.status === 429 || res.status >= 500) && intento < maxRetries) {
      ultimo = err;
      await new Promise((r) => setTimeout(r, backoffMs(intento)));
      continue;
    }
    throw err;
  }
  if (ultimo instanceof OpenAIError) throw ultimo;
  throw new OpenAIError(`OpenAI falló tras ${maxRetries + 1} intentos: ${String(ultimo)}`);
}
