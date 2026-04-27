// Tool registry. Mantiene un Map global de Tools registradas y expone un
// invokeTool() que:
//   1. Resuelve la tool por nombre (404 → tool_no_existe).
//   2. Chequea permisos por rol (403 → permiso_denegado).
//   3. Loguea audit (tool_call con parametros).
//   4. Ejecuta el handler con timing.
//   5. Loguea resultado_meta con success + ms (o error).
//
// Política de errores:
//   * Errores controlados (validación, "no encontrado", etc.) → el handler
//     hace throw new Error("mensaje en español") y nosotros lo capturamos
//     en {ok:false, error}.
//   * Errores inesperados — same: capturados acá. NO propagamos.
//
// Decisión: registry global por módulo (singleton implícito de Deno). Los
// tests deben importar registerAllTools() del index.ts.

import type { Tool, ToolContext, ToolResult } from "./base.ts";
import type { BotRol } from "../types.ts";
import { canInvoke } from "./permissions.ts";
import { logEvent } from "../audit.ts";

// deno-lint-ignore no-explicit-any
const TOOLS = new Map<string, Tool<any, any>>();

/**
 * Registra una tool en el registry. Lanza si el nombre ya existe — esto
 * previene shadowing accidental si alguien duplica un import.
 */
// deno-lint-ignore no-explicit-any
export function registerTool(tool: Tool<any, any>): void {
  if (TOOLS.has(tool.name)) {
    throw new Error(`registerTool: tool "${tool.name}" ya registrada`);
  }
  TOOLS.set(tool.name, tool);
}

/** Test helper: limpia el registry. NO usar desde producción. */
export function _clearToolsForTests(): void {
  TOOLS.clear();
}

// deno-lint-ignore no-explicit-any
export function getTool(name: string): Tool<any, any> | undefined {
  return TOOLS.get(name);
}

// deno-lint-ignore no-explicit-any
export function getAllTools(): Array<Tool<any, any>> {
  return [...TOOLS.values()];
}

// deno-lint-ignore no-explicit-any
export function getToolsForRole(rol: BotRol): Array<Tool<any, any>> {
  return getAllTools().filter((t) => canInvoke(rol, t));
}

/**
 * Invoca una tool por nombre. Hace audit log de la invocación y del resultado.
 * Nunca propaga excepciones del handler — siempre retorna ToolResult.
 */
export async function invokeTool<TResult = unknown>(
  toolName: string,
  params: unknown,
  ctx: ToolContext,
): Promise<ToolResult<TResult>> {
  const tool = getTool(toolName);

  if (!tool) {
    // logEvent es fail-closed; suprimimos errores del audit acá para no
    // enmascarar el error real al caller.
    await logEvent({
      perfil_id: ctx.perfil_id,
      rol: ctx.rol,
      tipo: "error",
      tool_name: toolName,
      resultado_meta: { error: "tool_not_found" },
    }).catch(() => {});
    return { ok: false, error: "tool_no_existe" };
  }

  if (!canInvoke(ctx.rol, tool)) {
    await logEvent({
      perfil_id: ctx.perfil_id,
      rol: ctx.rol,
      tipo: "error",
      tool_name: toolName,
      resultado_meta: { error: "permission_denied", rol: ctx.rol },
    }).catch(() => {});
    return { ok: false, error: "permiso_denegado" };
  }

  // Audit del call (entrada). Suprimimos errores: si el audit falla, igual
  // queremos ejecutar la tool — el caller decidirá qué hacer con el resultado.
  await logEvent({
    perfil_id: ctx.perfil_id,
    rol: ctx.rol,
    tipo: "tool_call",
    tool_name: toolName,
    parametros: (params && typeof params === "object")
      ? (params as Record<string, unknown>)
      : undefined,
  }).catch(() => {});

  const start = Date.now();
  try {
    const data = (await tool.handler(params as never, ctx)) as TResult;
    await logEvent({
      perfil_id: ctx.perfil_id,
      rol: ctx.rol,
      tipo: "tool_call",
      tool_name: toolName,
      resultado_meta: { success: true, ms: Date.now() - start },
    }).catch(() => {});
    return { ok: true, data };
  } catch (err) {
    const message = err instanceof Error ? err.message : "error_desconocido";
    await logEvent({
      perfil_id: ctx.perfil_id,
      rol: ctx.rol,
      tipo: "error",
      tool_name: toolName,
      resultado_meta: {
        success: false,
        ms: Date.now() - start,
        error: message,
      },
    }).catch(() => {});
    return { ok: false, error: message };
  }
}
