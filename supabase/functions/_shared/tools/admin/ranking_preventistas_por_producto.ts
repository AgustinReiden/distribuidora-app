// Tool: ranking_preventistas_por_producto
//
// Top de preventistas que más vendieron UN producto puntual en un rango de
// fechas. Pensada para preguntas de bonificación / sales contest tipo
// "quién vendió más Manaos 3000 este mes". El modelo debe conseguir el
// producto_id antes con buscar_producto — esta tool no acepta búsqueda
// libre por nombre, mantiene el output acotado.
//
// Delega a la RPC bot_ranking_preventistas_por_producto (migration 026).
// Mismas convenciones de fecha/estado que ventas_periodo y ventas_por_preventista
// (filtro por created_at, excluye cancelado/anulado, scoping por sucursal).

import type { Tool } from "../base.ts";

export interface RankingPreventistasPorProductoParams {
  /** ID del producto (sacar antes con buscar_producto). */
  producto_id: number;
  /** Fecha inicio inclusive (YYYY-MM-DD). */
  desde: string;
  /** Fecha fin inclusive (YYYY-MM-DD). */
  hasta: string;
  /** Top N para el ranking. Default 10, max 25. */
  limit?: number;
}

export interface RankingPreventistasPorProductoResult {
  producto_id: number;
  producto_codigo: string | null;
  producto_nombre: string | null;
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
    pedidos_con_producto: number;
  }>;
}

const FECHA_REGEX = /^\d{4}-\d{2}-\d{2}$/;

export const rankingPreventistasPorProductoTool: Tool<
  RankingPreventistasPorProductoParams,
  RankingPreventistasPorProductoResult
> = {
  name: "ranking_preventistas_por_producto",
  description:
    "Ranking de preventistas que más vendieron UN producto específico en " +
    "un rango de fechas (admin/encargado). Útil para 'quién vendió más " +
    "[producto]', 'top vendedores de [producto] del mes', bonificaciones " +
    "por sales contest. Requiere producto_id — conseguilo antes con " +
    "buscar_producto. Devuelve unidades + facturado + cantidad de pedidos " +
    "con el producto, por preventista, ordenado por unidades. Filtra por " +
    "sucursal del bot user. Excluye pedidos cancelados/anulados.",
  parameters: {
    type: "object",
    properties: {
      producto_id: {
        type: "integer",
        minimum: 1,
        description: "ID interno del producto. Conseguilo con buscar_producto antes.",
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
    required: ["producto_id", "desde", "hasta"],
  },
  allowedRoles: ["admin", "encargado"],
  handler: async ({ producto_id, desde, hasta, limit = 10 }, ctx) => {
    if (!Number.isInteger(producto_id) || producto_id < 1) {
      throw new Error("producto_id inválido (entero > 0)");
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
        p_producto_id: producto_id,
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
      pedidos_con_producto: number;
    };
    const r = data as {
      producto_id: number;
      producto_codigo: string | null;
      producto_nombre: string | null;
      desde: string;
      hasta: string;
      unidades_total: number | string;
      facturado_total: number | string;
      preventistas_count: number;
      preventistas: RpcRow[];
    };

    return {
      producto_id: Number(r.producto_id),
      producto_codigo: r.producto_codigo ?? null,
      producto_nombre: r.producto_nombre ?? null,
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
        pedidos_con_producto: Number(p.pedidos_con_producto ?? 0),
      })),
    };
  },
};
