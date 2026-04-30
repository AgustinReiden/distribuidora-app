// Tool: mis_ventas
//
// Resumen de ventas del propio preventista en un rango de fechas: total
// facturado, cantidad de pedidos, ticket promedio, clientes distintos y top
// N clientes del período. Pensada para que el preventista pregunte "cuánto
// vendí ayer / esta semana / este mes" desde Telegram.
//
// El RPC bot_mis_ventas filtra hard-coded por usuario_id = perfil_id del
// caller, así que NO hay forma de ver ventas de otro preventista. Defense-
// in-depth: este handler solo acepta rol='preventista'.

import type { Tool } from "../base.ts";

export interface MisVentasParams {
  /** Fecha inicio inclusive (YYYY-MM-DD). */
  desde: string;
  /** Fecha fin inclusive (YYYY-MM-DD). */
  hasta: string;
  /** Top N clientes del período. Default 10, max 25. */
  limit?: number;
}

export interface MisVentasResult {
  desde: string;
  hasta: string;
  total_ventas: number;
  pedidos_count: number;
  ticket_promedio: number;
  clientes_distintos: number;
  top_clientes: Array<{
    cliente_id: number;
    cliente_codigo: number | null;
    nombre: string;
    total_comprado: number;
    pedidos: number;
  }>;
}

const FECHA_REGEX = /^\d{4}-\d{2}-\d{2}$/;

export const misVentasTool: Tool<MisVentasParams, MisVentasResult> = {
  name: "mis_ventas",
  description:
    "Resumen de las ventas del preventista actual en un rango de fechas. " +
    "Devuelve total facturado, cantidad de pedidos, ticket promedio, " +
    "clientes distintos y top clientes del período. Las fechas son " +
    "inclusive en formato YYYY-MM-DD. Solo ve sus propias ventas (las que " +
    "tiene como usuario_id en pedidos). Excluye pedidos cancelados/anulados.",
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
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Top N clientes del período (default 10, max 25).",
      },
    },
    required: ["desde", "hasta"],
  },
  allowedRoles: ["preventista"],
  handler: async ({ desde, hasta, limit = 10 }, ctx) => {
    // Defense-in-depth: allowedRoles ya garantiza esto en invokeTool, pero
    // si alguien llama el handler directo lo bloqueamos acá.
    if (ctx.rol !== "preventista") {
      throw new Error("mis_ventas solo está disponible para preventistas");
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
      throw new Error(
        "Sucursal no asignada en bot_usuarios — contactá al administrador",
      );
    }

    const { data, error } = await ctx.supabase.rpc("bot_mis_ventas", {
      p_preventista_id: ctx.perfil_id,
      p_desde: desde,
      p_hasta: hasta,
      p_sucursal_id: ctx.sucursal_id,
      p_limit: limit,
    });

    if (error) {
      throw new Error(`mis_ventas: ${error.message}`);
    }

    type RpcCliente = {
      cliente_id: number;
      cliente_codigo: number | null;
      nombre_fantasia: string | null;
      razon_social: string | null;
      total_comprado: number | string;
      pedidos: number;
    };
    const r = data as {
      desde: string;
      hasta: string;
      total_ventas: number | string;
      pedidos_count: number;
      ticket_promedio: number | string;
      clientes_distintos: number;
      top_clientes: RpcCliente[];
    };

    return {
      desde: r.desde,
      hasta: r.hasta,
      total_ventas: Number(r.total_ventas ?? 0),
      pedidos_count: Number(r.pedidos_count ?? 0),
      ticket_promedio: Number(r.ticket_promedio ?? 0),
      clientes_distintos: Number(r.clientes_distintos ?? 0),
      top_clientes: (r.top_clientes ?? []).map((c) => ({
        cliente_id: Number(c.cliente_id),
        cliente_codigo: c.cliente_codigo ?? null,
        nombre: c.nombre_fantasia?.trim() || c.razon_social?.trim() ||
          "(sin nombre)",
        total_comprado: Number(c.total_comprado ?? 0),
        pedidos: Number(c.pedidos ?? 0),
      })),
    };
  },
};
