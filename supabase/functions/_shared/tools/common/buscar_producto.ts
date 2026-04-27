// Tool: buscar_producto
//
// Busca productos por nombre o código. Catálogo es global por sucursal —
// cualquier rol del bot puede consultarlo. No hay filtrado por rol más allá
// de la lista de allowedRoles.
//
// Devuelve stock + stock_minimo + flag bajo_stock para que el caller pueda
// decidir si alertar.

import type { Tool } from "../base.ts";

interface BuscarProductoParams {
  q: string;
  limit?: number;
}

interface BuscarProductoResult {
  total: number;
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

export const buscarProductoTool: Tool<BuscarProductoParams, BuscarProductoResult> = {
  name: "buscar_producto",
  description:
    "Busca productos del catálogo por nombre o código. Devuelve precio, stock, " +
    "stock mínimo y un flag bajo_stock cuando stock <= stock_minimo. " +
    "Filtra por sucursal del bot user cuando aplica.",
  parameters: {
    type: "object",
    properties: {
      q: {
        type: "string",
        description: "Texto o código a buscar. Mínimo 2 caracteres.",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Cantidad máxima de resultados (default 10, máx 25).",
      },
    },
    required: ["q"],
  },
  allowedRoles: ["admin", "preventista", "transportista", "encargado", "deposito"],
  handler: async ({ q, limit = 10 }, ctx) => {
    if (typeof q !== "string") {
      throw new Error("Parámetro 'q' debe ser texto");
    }
    const trimmed = q.trim();
    if (trimmed.length < 2) {
      throw new Error("Búsqueda muy corta (mínimo 2 caracteres)");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 25) {
      throw new Error("Límite fuera de rango (1-25)");
    }

    const sb = ctx.supabase;

    let query = sb.from("productos")
      .select(
        "id, codigo, nombre, precio, stock, stock_minimo, categoria, sucursal_id",
        { count: "exact" },
      )
      .order("nombre", { ascending: true })
      .limit(limit);

    if (ctx.sucursal_id != null) {
      query = query.eq("sucursal_id", ctx.sucursal_id);
    }

    const escaped = trimmed.replace(/[%_,()]/g, "\\$&");
    query = query.or(
      `nombre.ilike.%${escaped}%,codigo.ilike.%${escaped}%`,
    );

    const { data, error, count } = await query;
    if (error) {
      throw new Error(`buscar_producto: ${error.message}`);
    }

    const rows = (data ?? []) as unknown as ProductoRow[];

    return {
      total: count ?? rows.length,
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
