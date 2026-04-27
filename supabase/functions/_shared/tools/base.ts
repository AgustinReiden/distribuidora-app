// Tipos base del tool framework. Phase 2 — sin LLM aún. Esto define el shape
// de las "tools" que en Phase 3 serán expuestas a Gemini vía function calling.
//
// Diseño:
//   * Cada Tool es self-contained: define su nombre, JSON Schema (Gemini-compat),
//     roles permitidos y handler async.
//   * El ToolContext lleva la identidad del usuario que dispara la tool (perfil,
//     rol, sucursal) + un cliente Supabase (service_role en prod). Las tools NO
//     resuelven al usuario por sí mismas — eso lo hace el caller.
//   * ToolResult es un Result discriminado para que el caller no tenga que
//     try/catch. Errores controlados → ok:false; errores inesperados los
//     captura el invokeTool del registry.

import type { SupabaseClient } from "@supabase/supabase-js";
import type { BotRol } from "../types.ts";

export interface ToolContext {
  /** UUID del perfil dueño de esta sesión (FK a public.perfiles.id) */
  perfil_id: string;
  /** Rol con el que el bot reconoció al usuario */
  rol: BotRol;
  /**
   * Sucursal del bot user. NULL es válido SOLO para admin (multi-sucursal).
   * Tools no-admin DEBEN rechazar `ctx.sucursal_id == null` al inicio del
   * handler — un preventista/transportista/encargado/deposito sin sucursal
   * asignada es un data error y nunca debe ver datos cross-sucursal.
   */
  sucursal_id: number | null;
  /** Cliente Supabase con service_role (bypasses RLS — las tools deben
   *  filtrar por sucursal/preventista manualmente cuando aplique). */
  supabase: SupabaseClient;
}

export interface Tool<TParams = Record<string, unknown>, TResult = unknown> {
  /** Identificador único en el registry. snake_case. */
  name: string;
  /** Descripción humana — usada por Gemini en Phase 3 para decidir cuándo
   *  invocarla. Debe ser específica y mencionar el rol esperado si aplica. */
  description: string;
  /** JSON Schema (subset compatible con Gemini function declarations) que
   *  describe el shape de los parámetros. */
  parameters: Record<string, unknown>;
  /** Roles autorizados a invocar esta tool. Se enforza en invokeTool(). */
  allowedRoles: ReadonlyArray<BotRol>;
  /** Handler async. Debe validar params adicionalmente (el JSON Schema en
   *  Phase 3 lo hará Gemini, pero acá NO confiamos en eso) y throw para
   *  errores controlados con mensajes en español visibles al usuario. */
  handler: (params: TParams, ctx: ToolContext) => Promise<TResult>;
}

export type ToolResult<T = unknown> =
  | { ok: true; data: T }
  | { ok: false; error: string };

// ----------------------------------------------------------------------------
// Type helpers para cuando el caller tipa fuertemente la tool a invocar.
// ----------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
export type InferToolParams<T> = T extends Tool<infer P, any> ? P : never;
// deno-lint-ignore no-explicit-any
export type InferToolResult<T> = T extends Tool<any, infer R> ? R : never;
