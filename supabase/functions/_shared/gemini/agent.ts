// Loop principal del agente Gemini. Phase 3 task 3.2.
//
// Conecta:
//   * `callGemini` (cliente low-level, task 3.1).
//   * `getSystemPrompt(rol)` (prompts por rol, task 3.1).
//   * Tool registry (`getToolsForRole`, `invokeTool`).
//   * Memoria conversacional (`loadConversation`, `saveConversation`).
//   * Audit log (logEvent → bot_audit_log).
//
// Diseño:
//   * Loop tope MAX_TOOL_ITERATIONS=5: cada iteración emite UN llamado a
//     Gemini, ejecuta TODAS las function calls que vinieron en la respuesta
//     (Gemini puede emitir varias paralelas), y vuelve a llamar al modelo
//     con los resultados.
//   * El loop termina cuando: (a) Gemini responde con texto y ningún
//     functionCall → respuesta final; (b) safety block / no candidato →
//     fallback; (c) se agota el cap → fallback "tu pedido es complejo...".
//   * El history se construye incrementalmente. NO se persiste turno a turno
//     dentro del loop — solo al finalizar (con truncate). Esto evita que un
//     crash a medio loop deje un history corrupto.
//   * Audit: tipo='respuesta' al emitir texto final; tipo='error' en
//     hit-max-iterations o safety block. Las tool calls individuales auditan
//     dentro de `invokeTool` (registry).
//
// Lo que NO hace este módulo:
//   * sendMessage a Telegram. El caller (handlers.ts) decide cómo entregar.
//   * Comandos slash: el router los intercepta antes.
//   * Streaming: solo non-streaming en este task.

import type { SupabaseClient } from "@supabase/supabase-js";
import type { BotUser } from "../types.ts";
import type { GeminiContent } from "./types.ts";
import { isFunctionCallPart, isTextPart } from "./types.ts";
import { callGemini } from "./client.ts";
import { getSystemPrompt } from "./prompts/base.ts";
import { toolsToGeminiDeclarations } from "./schema.ts";
import { getToolsForRole, invokeTool } from "../tools/registry.ts";
import { logEvent } from "../audit.ts";
import { loadConversation, saveConversation } from "./memory.ts";
import {
  appendFunctionResponse,
  appendModelParts,
  appendUserText,
} from "./history-mapper.ts";
import type { ToolContext } from "../tools/base.ts";

/**
 * Cap del loop de tool-calls. Configurable via env var `BOT_MAX_TOOL_ITERATIONS`
 * (entero entre 1 y 20). Default 8 — sube de 5 para acomodar flujos multi-tool
 * que ahora son explícitos en los prompts (listar_categorias →
 * productos_por_categoria → eventual fallback con sinónimo). Bajo enough
 * para que un loop infinito del modelo no explote latencia ni costo.
 */
function getMaxToolIterations(): number {
  const raw = Deno.env.get("BOT_MAX_TOOL_ITERATIONS");
  if (!raw) return 8;
  const n = parseInt(raw, 10);
  // Out-of-range / NaN → default. No queremos que un typo en el secret deje
  // el bot con MAX=0 (no responde) o MAX=1000 (loops gigantes).
  if (!Number.isFinite(n) || n < 1 || n > 20) return 8;
  return n;
}

const MAX_TOOL_ITERATIONS = getMaxToolIterations();

/**
 * Helper centralizado para persistir el history conversacional. Si el upsert
 * falla (network down, RLS reject, lo que sea), no abortamos la respuesta al
 * usuario — pero queremos visibilidad: escribimos un audit row con
 * `tipo='error'` y `resultado_meta.save_failed=true`. El audit row tampoco
 * aborta si falla (el catch al final lo suprime) — preferimos un audit
 * perdido a perder la respuesta al usuario.
 */
async function persistOrAudit(
  supabase: SupabaseClient,
  telegram_user_id: number,
  perfil_id: string,
  rol: BotUser["rol"],
  history: GeminiContent[],
  context: string,
): Promise<void> {
  try {
    await saveConversation(supabase, telegram_user_id, history);
  } catch (err) {
    console.error(`[runAgent] saveConversation (${context}):`, err);
    await logEvent({
      telegram_user_id,
      perfil_id,
      rol,
      tipo: "error",
      resultado_meta: {
        save_failed: true,
        context,
        error: err instanceof Error ? err.message : String(err),
      },
    }).catch(() => {});
  }
}

export interface RunAgentOptions {
  supabase: SupabaseClient;
  /** Bot user vinculado (rol resuelto, sucursal_id, perfil_id). */
  user: BotUser;
  telegram_user_id: number;
  /** Texto crudo del usuario (post-trim recomendado, no es comando). */
  userMessage: string;
  /**
   * Si true, no carga ni persiste en `bot_conversaciones`. Útil para tests
   * unitarios y para invocaciones one-shot futuras (ej: webhook interno
   * que no debería contaminar la memoria del usuario).
   */
  ephemeral?: boolean;
}

/**
 * Lista de items "interactables" extraída de la última tool call relevante
 * del turno. El handler la usa para armar un inline keyboard que adjunta
 * a result.text — así las respuestas NL del LLM también tienen botones,
 * matching la UX de los slash commands.
 *
 * Se popula con la ÚLTIMA tool call cuyo result devolvió una lista con
 * IDs + nombres. Si una tool posterior devuelve otra lista, sobreescribe
 * (vale la más reciente — es la que probablemente esté más relacionada
 * con el texto final del LLM).
 */
export type InteractableContext =
  | { kind: "clientes"; items: Array<{ id: number; nombre: string }> }
  | { kind: "productos"; items: Array<{ id: number; nombre: string }> };

export interface RunAgentResult {
  /** Texto final que el caller debe mandar al usuario. */
  text: string;
  /** Cantidad total de tool calls ejecutadas (sumadas de todos los rounds). */
  toolCallsCount: number;
  /** Cuántas iteraciones del loop se ejecutaron (1..MAX). */
  iterations: number;
  /** finishReason de la última respuesta de Gemini ("STOP", "SAFETY", etc). */
  finishReason: string;
  /** Tokens totales (sumados de todas las llamadas a Gemini en el loop). */
  totalTokens: number;
  /** True si terminó por hit del cap MAX_TOOL_ITERATIONS sin respuesta final. */
  hitMaxIterations: boolean;
  /** Última tool call que devolvió una lista de items con IDs.
   *  El handler arma un inline keyboard a partir de esto. */
  interactableContext?: InteractableContext;
}

/**
 * Extrae el `InteractableContext` correspondiente al output de una tool.
 * Cubre las tools que retornan listas con IDs + nombres. Para tools que
 * retornan single-items (ficha_cliente, ficha_producto), retorna undefined
 * — un keyboard de un solo botón sería ruido.
 */
function extractInteractableContext(
  name: string,
  data: unknown,
): InteractableContext | undefined {
  if (!data || typeof data !== "object") return undefined;
  const d = data as Record<string, unknown>;

  // Limit a 10 items para evitar mensajes con keyboards gigantes.
  const TAKE = 10;

  const mapClientes = (
    arr: unknown[],
    idKey: string,
  ): InteractableContext | undefined => {
    const items = arr
      .slice(0, TAKE)
      .map((c) => {
        const r = c as Record<string, unknown>;
        const id = Number(r[idKey]);
        const nombre = typeof r.nombre === "string" ? r.nombre : "";
        return Number.isFinite(id) && id > 0 && nombre.length > 0
          ? { id, nombre }
          : null;
      })
      .filter((x): x is { id: number; nombre: string } => x !== null);
    return items.length > 0 ? { kind: "clientes", items } : undefined;
  };

  const mapProductos = (
    arr: unknown[],
  ): InteractableContext | undefined => {
    const items = arr
      .slice(0, TAKE)
      .map((p) => {
        const r = p as Record<string, unknown>;
        const id = Number(r.id);
        const nombre = typeof r.nombre === "string" ? r.nombre : "";
        return Number.isFinite(id) && id > 0 && nombre.length > 0
          ? { id, nombre }
          : null;
      })
      .filter((x): x is { id: number; nombre: string } => x !== null);
    return items.length > 0 ? { kind: "productos", items } : undefined;
  };

  switch (name) {
    case "buscar_cliente":
    case "mis_clientes":
      return Array.isArray(d.clientes) ? mapClientes(d.clientes, "id") : undefined;
    case "sugerir_visitas_rfm":
      // sugerencias usan `cliente_id` como key, no `id`.
      return Array.isArray(d.sugerencias)
        ? mapClientes(d.sugerencias, "cliente_id")
        : undefined;
    case "buscar_producto":
    case "productos_por_categoria":
      return Array.isArray(d.productos) ? mapProductos(d.productos) : undefined;
    default:
      return undefined;
  }
}

/**
 * Ejecuta un turno conversacional completo:
 *   user message → (tool call / response loop) → texto final.
 *
 * Nunca propaga excepciones del modelo o de las tools — siempre retorna un
 * RunAgentResult con texto user-friendly. Excepciones de infraestructura
 * (Gemini API down con todos los retries fallando, p.ej.) sí se propagan; el
 * caller decide qué hacer.
 */
export async function runAgent(opts: RunAgentOptions): Promise<RunAgentResult> {
  const { supabase, user, telegram_user_id, userMessage, ephemeral } = opts;

  // 1. Cargar history previo (skip en modo ephemeral).
  const history0: GeminiContent[] = ephemeral
    ? []
    : await loadConversation(supabase, telegram_user_id);

  // 2. System prompt + tools del rol.
  const systemPrompt = await getSystemPrompt(user.rol);
  const allTools = getToolsForRole(user.rol);
  const toolDecls = toolsToGeminiDeclarations(allTools);

  // 3. ToolContext para invokeTool.
  const toolCtx: ToolContext = {
    perfil_id: user.perfil_id,
    rol: user.rol,
    sucursal_id: user.sucursal_id,
    supabase,
  };

  // 4. Append del user message al history.
  let history = appendUserText(history0, userMessage);

  let toolCallsCount = 0;
  let totalTokens = 0;
  let lastFinishReason = "UNKNOWN";
  // Última tool call que devolvió una lista interactable. Se sobreescribe
  // si una tool posterior emite otra (vale la más reciente).
  let lastInteractableContext: InteractableContext | undefined;

  for (let iter = 0; iter < MAX_TOOL_ITERATIONS; iter++) {
    const response = await callGemini({
      system_instruction: { parts: [{ text: systemPrompt }] },
      contents: history,
      tools: toolDecls.length > 0
        ? [{ function_declarations: toolDecls }]
        : undefined,
      tool_config: toolDecls.length > 0
        ? { function_calling_config: { mode: "AUTO" } }
        : undefined,
      generationConfig: { temperature: 0.3, maxOutputTokens: 2048 },
    });

    totalTokens += response.usageMetadata?.totalTokenCount ?? 0;

    const candidate = response.candidates?.[0];
    if (!candidate) {
      // Sin candidato — bloqueo de safety, RECITATION, u otro motivo.
      const blockReason = response.promptFeedback?.blockReason ?? "no_candidate";
      lastFinishReason = blockReason;
      const fallback =
        "No pude procesar tu mensaje en este momento. Probá reformular o usá /ayuda.";

      // No appendeamos el fallback al history — un user puede reintentar y
      // queremos que el siguiente turn no tenga "model: <fallback>" que
      // contamine la respuesta.
      if (!ephemeral) {
        await persistOrAudit(
          supabase,
          telegram_user_id,
          user.perfil_id,
          user.rol,
          history,
          "block-path",
        );
      }
      await logEvent({
        telegram_user_id,
        perfil_id: user.perfil_id,
        rol: user.rol,
        tipo: "respuesta",
        texto_bot: fallback,
        resultado_meta: {
          gemini: true,
          blocked: blockReason,
          totalTokens,
          iterations: iter + 1,
        },
      }).catch(() => {});

      return {
        text: fallback,
        toolCallsCount,
        iterations: iter + 1,
        finishReason: blockReason,
        totalTokens,
        hitMaxIterations: false,
      };
    }

    lastFinishReason = candidate.finishReason ?? "UNKNOWN";
    const parts = candidate.content?.parts ?? [];

    // Append de las parts del modelo al history (preservamos lo que Gemini
    // emitió tal cual, incluyendo functionCall + text mezclados).
    history = appendModelParts(history, parts);

    // ¿Hay function calls?
    const fnCalls = parts.filter(isFunctionCallPart);
    if (fnCalls.length === 0) {
      // Respuesta final con texto.
      const textParts = parts
        .filter(isTextPart)
        .map((p) => p.text)
        .join("");
      let text = textParts.trim().length > 0
        ? textParts
        : "No pude generar una respuesta. Probá reformular.";

      // Si Gemini cortó por límite de tokens, avisamos al usuario para que
      // sepa que la respuesta puede estar incompleta y pueda pedir más detalle.
      // El sufijo va en italics MarkdownV2 — pero como el resto del texto va
      // sin parse_mode (handlers.ts manda plain), el `_` se ve como subrayado
      // visual sin romper nada.
      if (lastFinishReason === "MAX_TOKENS") {
        text +=
          "\n\n_(Respuesta truncada — pedí más detalle si querés profundizar.)_";
      }

      if (!ephemeral) {
        await persistOrAudit(
          supabase,
          telegram_user_id,
          user.perfil_id,
          user.rol,
          history,
          "text-path",
        );
      }
      await logEvent({
        telegram_user_id,
        perfil_id: user.perfil_id,
        rol: user.rol,
        tipo: "respuesta",
        texto_bot: text,
        resultado_meta: {
          gemini: true,
          totalTokens,
          iterations: iter + 1,
          toolCallsCount,
          finishReason: lastFinishReason,
        },
      }).catch(() => {});

      return {
        text,
        toolCallsCount,
        iterations: iter + 1,
        finishReason: lastFinishReason,
        totalTokens,
        hitMaxIterations: false,
        interactableContext: lastInteractableContext,
      };
    }

    // Hay function calls — ejecutamos TODAS y appendeamos resultados.
    // Ejecutamos las tool calls en paralelo. invokeTool nunca propaga
    // excepciones (las traduce a {ok:false}), así que un tool fallido no
    // aborta los otros. El orden del map preserva el orden del append al
    // history para coherencia con el orden en que Gemini las emitió.
    const results = await Promise.all(
      fnCalls.map(async (fc) => {
        const { name, args } = fc.functionCall;
        const result = await invokeTool(name, args, toolCtx);
        return { name, result };
      }),
    );
    toolCallsCount += fnCalls.length;
    for (const { name, result } of results) {
      const responseObj = result.ok
        ? { result: result.data }
        : { error: result.error };
      history = appendFunctionResponse(history, name, responseObj);
      // Si la tool devolvió un result OK con shape de lista interactable,
      // lo guardamos para que el handler arme un keyboard al final.
      if (result.ok) {
        const ctx = extractInteractableContext(name, result.data);
        if (ctx) lastInteractableContext = ctx;
      }
    }
    // Loop sigue: el próximo callGemini verá los functionResponse que acabamos
    // de appendear y decidirá si emitir texto final o más function calls.
  }

  // Hit MAX_TOOL_ITERATIONS sin respuesta final.
  const fallback =
    "Tu pedido es complejo y no logré completarlo en pocos pasos. " +
    "Probá descomponerlo en consultas más cortas o usá /ayuda.";
  history = appendModelParts(history, [{ text: fallback }]);
  if (!ephemeral) {
    await persistOrAudit(
      supabase,
      telegram_user_id,
      user.perfil_id,
      user.rol,
      history,
      "max-iter-path",
    );
  }
  await logEvent({
    telegram_user_id,
    perfil_id: user.perfil_id,
    rol: user.rol,
    tipo: "error",
    texto_bot: fallback,
    resultado_meta: {
      gemini: true,
      hit_max_iterations: true,
      totalTokens,
      toolCallsCount,
      finishReason: lastFinishReason,
    },
  }).catch(() => {});

  return {
    text: fallback,
    toolCallsCount,
    iterations: MAX_TOOL_ITERATIONS,
    finishReason: lastFinishReason,
    totalTokens,
    hitMaxIterations: true,
  };
}

/** Para tests: expone el cap. */
export const _MAX_TOOL_ITERATIONS_FOR_TESTS = MAX_TOOL_ITERATIONS;
