// Tool: ventas_por_preventista
//
// Devuelve el ranking de ventas agrupadas por usuario_id (preventista) en un
// rango de fechas. Permite responder "ventas de ayer por preventista", "quién
// vendió más esta semana", "ventas del mes por vendedor", etc.
//
// Delega 100% a la RPC bot_ventas_por_preventista (migration 025). Mismas
// convenciones que ventas_periodo: filtro por created_at, excluye estados
// 'cancelado' / 'anulado', filtra por sucursal del bot user.

import type { Tool } from "../base.ts";

export interface VentasPorPreventistaParams {
  /** Fecha inicio inclusive (YYYY-MM-DD). */
  desde: string;
  /** Fecha fin inclusive (YYYY-MM-DD). */
  hasta: string;
  /**
   * Si true (default), solo cuenta pedidos cuyo usuario_id corresponda a un
   * perfil con rol='preventista'. Excluye ventas registradas a nombre de un
   * admin/encargado del mostrador. Pasá false para ver TODOS los usuarios.
   */
  solo_preventistas?: boolean;
  /** Top N para el ranking. Default 10, max 25. */
  limit?: number;
}

export interface VentasPorPreventistaResult {
  desde: string;
  hasta: string;
  solo_preventistas: boolean;
  total_ventas: number;
  pedidos_count: number;
  preventistas_count: number;
  preventistas: Array<{
    usuario_id: string | null;
    nombre: string;
    rol: string | null;
    pedidos: number;
    total_vendido: number;
    ticket_promedio: number;
  }>;
}

const FECHA_REGEX = /^\d{4}-\d{2}-\d{2}$/;

export const ventasPorPreventistaTool: Tool<
  VentasPorPreventistaParams,
  VentasPorPreventistaResult
> = {
  name: "ventas_por_preventista",
  description:
    "Ranking de ventas agrupadas por preventista (usuario_id) en un rango de " +
    "fechas (admin/encargado). Devuelve total vendido, cantidad de pedidos y " +
    "ticket promedio por cada preventista. Útil para 'ventas de ayer por " +
    "preventista', 'quién vendió más esta semana', etc. Las fechas son " +
    "inclusive en formato YYYY-MM-DD. Filtra por sucursal del bot user. " +
    "Excluye pedidos cancelados/anulados.",
  parameters: {
    type: "object",
    properties: {
      desde: {
        type: "string",
        description: "Fecha de inicio inclusive (YYYY-MM-DD).",
      },
      hasta: {
        type: "string",
        description: "Fecha de fin inclusive (YYYY-MM-DD).",
      },
      solo_preventistas: {
        type: "boolean",
        description:
          "Si true (default), solo cuenta usuarios con rol='preventista'. " +
          "Pasá false para incluir admins/encargados que hayan registrado pedidos.",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Top N para el ranking (default 10, max 25).",
      },
    },
    required: ["desde", "hasta"],
  },
  allowedRoles: ["admin", "encargado"],
  handler: async (
    { desde, hasta, solo_preventistas = true, limit = 10 },
    ctx,
  ) => {
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
      "bot_ventas_por_preventista",
      {
        p_desde: desde,
        p_hasta: hasta,
        p_sucursal_id: ctx.sucursal_id,
        p_solo_preventistas: solo_preventistas,
        p_limit: limit,
      },
    );

    if (error) {
      throw new Error(`ventas_por_preventista: ${error.message}`);
    }

    type RpcRow = {
      usuario_id: string | null;
      nombre: string | null;
      rol: string | null;
      pedidos: number;
      total_vendido: number | string;
      ticket_promedio: number | string;
    };
    const r = data as {
      desde: string;
      hasta: string;
      solo_preventistas: boolean;
      total_ventas: number | string;
      pedidos_count: number;
      preventistas_count: number;
      preventistas: RpcRow[];
    };

    return {
      desde: r.desde,
      hasta: r.hasta,
      solo_preventistas: Boolean(r.solo_preventistas),
      total_ventas: Number(r.total_ventas ?? 0),
      pedidos_count: Number(r.pedidos_count ?? 0),
      preventistas_count: Number(r.preventistas_count ?? 0),
      preventistas: (r.preventistas ?? []).map((p) => ({
        usuario_id: p.usuario_id ?? null,
        nombre: p.nombre?.trim() || "(sin asignar)",
        rol: p.rol ?? null,
        pedidos: Number(p.pedidos ?? 0),
        total_vendido: Number(p.total_vendido ?? 0),
        ticket_promedio: Number(p.ticket_promedio ?? 0),
      })),
    };
  },
};
