// Tool: ranking_preventistas_por_producto
//
// Top de preventistas que más vendieron uno o varios productos puntuales en
// un rango de fechas. Acepta un ARRAY de producto_ids para que el modelo
// pueda agrupar productos relacionados (ej: "Manaos 3000cc" puede matchear
// 3 sabores distintos cada uno con su producto_id propio).
//
// El modelo encadena:
//   1. productos_por_categoria("MANAOS", q="3000") → lista de matches
//   2. Toma los producto_id que correspondan al pedido del usuario
//   3. ranking_preventistas_por_producto({ producto_ids: [10, 17, 23], ... })
//
// Output incluye `productos[]` con id+codigo+nombre de cada uno para que el
// modelo pueda explicar qué incluyó (auditable y transparente).
//
// Delega a la RPC bot_ranking_preventistas_por_producto (migration 027 —
// reemplazó la firma escalar de la migration 026).

import type { Tool } from "../base.ts";

export interface RankingPreventistasPorProductoParams {
  /**
   * IDs de los productos a agrupar. Mínimo 1, máximo 25. Conseguilos antes
   * con buscar_producto o productos_por_categoria.
   */
  producto_ids: number[];
  /** Fecha inicio inclusive (YYYY-MM-DD). */
  desde: string;
  /** Fecha fin inclusive (YYYY-MM-DD). */
  hasta: string;
  /** Top N para el ranking. Default 10, max 25. */
  limit?: number;
}

export interface RankingPreventistasPorProductoResult {
  producto_ids: number[];
  productos: Array<{
    id: number;
    codigo: string | null;
    nombre: string;
  }>;
  desde: string;
  hasta: string;
  unidades_total: number;
  facturado_total: number;
  preventistas_count: number;
  preventistas: Array<{
    usuario_id: string | null;
    nombre: string;
    rol: string | null;
    unidades: number;
    facturado: number;
    productos_distintos: number;
    line_items: number;
  }>;
}

const FECHA_REGEX = /^\d{4}-\d{2}-\d{2}$/;

export const rankingPreventistasPorProductoTool: Tool<
  RankingPreventistasPorProductoParams,
  RankingPreventistasPorProductoResult
> = {
  name: "ranking_preventistas_por_producto",
  description:
    "Ranking de preventistas que más vendieron UN producto o un GRUPO de " +
    "productos relacionados en un rango de fechas (admin/encargado). Útil " +
    "para 'quién vendió más [producto]', 'top vendedores de [familia]', " +
    "bonificaciones por sales contest. Aceptá un array de producto_ids: si " +
    "el usuario pide algo agregable (ej: 'Manaos 3000cc' puede ser varios " +
    "sabores), conseguí los IDs antes con productos_por_categoria y pasalos " +
    "todos juntos. La respuesta agrupa unidades + facturado por preventista " +
    "y devuelve la lista de productos considerados. Filtra por sucursal del " +
    "bot user. Excluye pedidos cancelados/anulados.",
  parameters: {
    type: "object",
    properties: {
      producto_ids: {
        type: "array",
        items: { type: "integer", minimum: 1 },
        minItems: 1,
        maxItems: 25,
        description:
          "Lista de IDs de productos a agrupar. Min 1, max 25. " +
          "Para UN solo producto pasá [id]. Para una familia (ej: 'Manaos 3000') " +
          "pasá los IDs que matcheen tras buscar con productos_por_categoria.",
      },
      desde: {
        type: "string",
        description: "Fecha de inicio inclusive (YYYY-MM-DD).",
      },
      hasta: {
        type: "string",
        description: "Fecha de fin inclusive (YYYY-MM-DD).",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Top N preventistas (default 10, max 25).",
      },
    },
    required: ["producto_ids", "desde", "hasta"],
  },
  allowedRoles: ["admin"],
  handler: async ({ producto_ids, desde, hasta, limit = 10 }, ctx) => {
    if (!Array.isArray(producto_ids) || producto_ids.length === 0) {
      throw new Error("producto_ids debe tener al menos 1 ID");
    }
    if (producto_ids.length > 25) {
      throw new Error("producto_ids no puede tener más de 25 IDs");
    }
    for (const pid of producto_ids) {
      if (!Number.isInteger(pid) || pid < 1) {
        throw new Error("producto_ids contiene un ID inválido (debe ser entero > 0)");
      }
    }
    if (!FECHA_REGEX.test(desde) || !FECHA_REGEX.test(hasta)) {
      throw new Error("Fechas inválidas (esperado YYYY-MM-DD)");
    }
    if (desde > hasta) {
      throw new Error("Fecha 'desde' debe ser <= 'hasta'");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 25) {
      throw new Error("Límite fuera de rango (1-25)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }

    const { data, error } = await ctx.supabase.rpc(
      "bot_ranking_preventistas_por_producto",
      {
        p_producto_ids: producto_ids,
        p_desde: desde,
        p_hasta: hasta,
        p_sucursal_id: ctx.sucursal_id,
        p_limit: limit,
      },
    );

    if (error) {
      throw new Error(`ranking_preventistas_por_producto: ${error.message}`);
    }

    type RpcRow = {
      usuario_id: string | null;
      nombre: string | null;
      rol: string | null;
      unidades: number | string;
      facturado: number | string;
      productos_distintos: number;
      line_items: number;
    };
    type RpcProducto = {
      id: number;
      codigo: string | null;
      nombre: string | null;
    };
    const r = data as {
      producto_ids: number[];
      productos: RpcProducto[];
      desde: string;
      hasta: string;
      unidades_total: number | string;
      facturado_total: number | string;
      preventistas_count: number;
      preventistas: RpcRow[];
    };

    return {
      producto_ids: r.producto_ids ?? producto_ids,
      productos: (r.productos ?? []).map((p) => ({
        id: Number(p.id),
        codigo: p.codigo ?? null,
        nombre: p.nombre?.trim() || "(sin nombre)",
      })),
      desde: r.desde,
      hasta: r.hasta,
      unidades_total: Number(r.unidades_total ?? 0),
      facturado_total: Number(r.facturado_total ?? 0),
      preventistas_count: Number(r.preventistas_count ?? 0),
      preventistas: (r.preventistas ?? []).map((p) => ({
        usuario_id: p.usuario_id ?? null,
        nombre: p.nombre?.trim() || "(sin asignar)",
        rol: p.rol ?? null,
        unidades: Number(p.unidades ?? 0),
        facturado: Number(p.facturado ?? 0),
        productos_distintos: Number(p.productos_distintos ?? 0),
        line_items: Number(p.line_items ?? 0),
      })),
    };
  },
};
