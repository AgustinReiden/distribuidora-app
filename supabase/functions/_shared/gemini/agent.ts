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

const MAX_TOOL_ITERATIONS = 5;

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
        await saveConversation(supabase, telegram_user_id, history).catch(
          (err) => {
            console.error("[runAgent] saveConversation (block path):", err);
          },
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
      const text = textParts.trim().length > 0
        ? textParts
        : "No pude generar una respuesta. Probá reformular.";

      if (!ephemeral) {
        await saveConversation(supabase, telegram_user_id, history).catch(
          (err) => {
            console.error("[runAgent] saveConversation (text path):", err);
          },
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
      };
    }

    // Hay function calls — ejecutamos TODAS y appendeamos resultados.
    for (const fc of fnCalls) {
      const { name, args } = fc.functionCall;
      toolCallsCount++;
      const result = await invokeTool(name, args, toolCtx);
      const responseObj = result.ok
        ? { result: result.data }
        : { error: result.error };
      history = appendFunctionResponse(history, name, responseObj);
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
    await saveConversation(supabase, telegram_user_id, history).catch((err) => {
      console.error("[runAgent] saveConversation (max-iter path):", err);
    });
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
