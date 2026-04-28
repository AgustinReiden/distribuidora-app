// Tool: listar_categorias
//
// Devuelve la lista de categorías distintas presentes en productos de la
// sucursal actual. Pensada para ser la PRIMERA llamada cuando el usuario
// pregunta por un tipo o familia de productos ("gaseosas", "fideos", "aguas")
// — el LLM la usa para descubrir las categorías reales (que son free-form
// text en BD, en mayúsculas y con variantes históricas) antes de filtrar
// con productos_por_categoria.
//
// No usa la tabla `categorias` (migration 009) — esa es backfill estática
// y no se mantiene en sync con productos.categoria. Ir directo a productos.
//
// Implementación: select de la columna categoria + scoping por sucursal,
// dedupe + filter de null/"" en JS. Se podría hacer DISTINCT en SQL, pero
// supabase-js no expone DISTINCT y armar un RPC custom para esto sería
// over-engineering — el catálogo por sucursal pesa cientos de filas, no
// decenas de miles, así que dedupe en memoria es trivial.

import type { Tool } from "../base.ts";

export interface ListarCategoriasParams {
  // Sin parámetros — la sucursal viene del ctx.
  [k: string]: never;
}

export interface ListarCategoriasResult {
  total: number;
  categorias: string[];
}

interface CategoriaRow {
  categoria: string | null;
}

export const listarCategoriasTool: Tool<
  ListarCategoriasParams,
  ListarCategoriasResult
> = {
  name: "listar_categorias",
  description:
    "Devuelve la lista de categorías de productos disponibles en la sucursal actual. " +
    "Usala como PRIMERA llamada cuando el usuario pregunta por un tipo o familia de " +
    "productos (ej: 'gaseosas', 'fideos', 'aguas') — primero descubrí qué categorías " +
    "existen, después usá productos_por_categoria con la más probable.",
  parameters: { type: "object", properties: {}, required: [] },
  allowedRoles: ["admin", "preventista", "transportista", "encargado", "deposito"],
  handler: async (_params, ctx) => {
    // Multi-tenancy guard idéntico al resto de tools comunes: solo admin
    // puede operar sin sucursal asignada.
    if (ctx.sucursal_id == null && ctx.rol !== "admin") {
      throw new Error(
        "Sucursal no asignada en bot_usuarios — contactá al administrador",
      );
    }

    const sb = ctx.supabase;
    let query = sb.from("productos")
      .select("categoria")
      .order("categoria", { ascending: true });

    if (ctx.sucursal_id != null) {
      query = query.eq("sucursal_id", ctx.sucursal_id);
    }

    const { data, error } = await query;
    if (error) {
      throw new Error(`listar_categorias: ${error.message}`);
    }

    const rows = (data ?? []) as unknown as CategoriaRow[];
    const seen = new Set<string>();
    const unique: string[] = [];
    for (const row of rows) {
      const c = row.categoria;
      if (typeof c === "string" && c.trim() !== "" && !seen.has(c)) {
        seen.add(c);
        unique.push(c);
      }
    }

    return { total: unique.length, categorias: unique };
  },
};
