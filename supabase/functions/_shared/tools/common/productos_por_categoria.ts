// Tool: productos_por_categoria
//
// Lista productos filtrados por categoría exacta (case-insensitive) con un
// `q` opcional para refinar dentro de la categoría por nombre/código.
// Pensada para usarse después de listar_categorias: el LLM descubre la
// categoría real ("GASEOSAS"), y entonces filtra por ella + atributo del
// usuario ("naranja", "mendocino", etc).
//
// Patrón calcado de buscar_producto.ts: mismo shape de salida, mismo
// escape de metacaracteres PostgREST en `q`, mismo guard de sucursal.

import type { Tool } from "../base.ts";

export interface ProductosPorCategoriaParams {
  categoria: string;
  q?: string;
  limit?: number;
}

export interface ProductosPorCategoriaResult {
  total: number;
  categoria: string;
  productos: Array<{
    id: number;
    codigo: string | null;
    nombre: string;
    precio: number;
    stock: number;
    stock_minimo: number;
    bajo_stock: boolean;
    categoria: string | null;
  }>;
}

interface ProductoRow {
  id: number;
  codigo: string | null;
  nombre: string;
  precio: number | string | null;
  stock: number | null;
  stock_minimo: number | null;
  categoria: string | null;
}

export const productosPorCategoriaTool: Tool<
  ProductosPorCategoriaParams,
  ProductosPorCategoriaResult
> = {
  name: "productos_por_categoria",
  description:
    "Lista productos de una categoría dada en la sucursal actual. La categoría " +
    "se matchea case-insensitive contra productos.categoria. Opcionalmente " +
    "filtra dentro de la categoría con `q` (ILIKE sobre nombre/código). Llamala " +
    "DESPUÉS de listar_categorias cuando el usuario pidió un tipo o familia de " +
    "producto (ej: 'gaseosas naranjas' → categoria='GASEOSAS', q='naranja').",
  parameters: {
    type: "object",
    properties: {
      categoria: {
        type: "string",
        description:
          "Nombre de la categoría tal como vino de listar_categorias " +
          "(case-insensitive — el matching no distingue mayúsculas).",
      },
      q: {
        type: "string",
        description:
          "Texto opcional para refinar dentro de la categoría — matchea ILIKE " +
          "contra nombre y código del producto. Útil para 'sabor naranja', 'marca X'.",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Cantidad máxima de resultados (default 10, máx 25).",
      },
    },
    required: ["categoria"],
  },
  allowedRoles: ["admin", "preventista", "transportista", "encargado", "deposito"],
  handler: async ({ categoria, q, limit = 10 }, ctx) => {
    if (typeof categoria !== "string") {
      throw new Error("Parámetro 'categoria' debe ser texto");
    }
    const cat = categoria.trim();
    if (cat.length === 0) {
      throw new Error("Categoría vacía");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 25) {
      throw new Error("Límite fuera de rango (1-25)");
    }

    if (ctx.sucursal_id == null && ctx.rol !== "admin") {
      throw new Error(
        "Sucursal no asignada en bot_usuarios — contactá al administrador",
      );
    }

    const sb = ctx.supabase;

    // Escape de metacaracteres PostgREST. Se aplica a la categoría (que
    // entra al ilike) y al q (que entra al .or() con ILIKE doble). Mismo
    // set que buscar_producto / buscar_cliente.
    const escapeFilter = (s: string) => s.replace(/[%_,()\.:]/g, "\\$&");

    let query = sb.from("productos")
      .select(
        "id, codigo, nombre, precio, stock, stock_minimo, categoria, sucursal_id",
        { count: "exact" },
      )
      .ilike("categoria", escapeFilter(cat))
      .order("nombre", { ascending: true })
      .limit(limit);

    if (ctx.sucursal_id != null) {
      query = query.eq("sucursal_id", ctx.sucursal_id);
    }

    if (typeof q === "string" && q.trim().length > 0) {
      const escaped = escapeFilter(q.trim());
      query = query.or(
        `nombre.ilike.%${escaped}%,codigo.ilike.%${escaped}%`,
      );
    }

    const { data, error, count } = await query;
    if (error) {
      throw new Error(`productos_por_categoria: ${error.message}`);
    }

    const rows = (data ?? []) as unknown as ProductoRow[];

    return {
      total: count ?? rows.length,
      categoria: cat,
      productos: rows.map((p) => {
        const stock = Number(p.stock ?? 0);
        const stockMin = Number(p.stock_minimo ?? 0);
        return {
          id: Number(p.id),
          codigo: p.codigo ?? null,
          nombre: p.nombre,
          precio: Number(p.precio ?? 0),
          stock,
          stock_minimo: stockMin,
          bajo_stock: stock <= stockMin,
          categoria: p.categoria ?? null,
        };
      }),
    };
  },
};
