// Tool: pendientes_pago
//
// Lista de clientes con pedidos no pagados, ordenados por días de atraso
// (mayor primero). Pensada para que el admin/encargado pueda priorizar
// cobranzas. Acepta un filtro `dias_atraso` para enfocarse en deuda
// vieja.

import type { Tool } from "../base.ts";

export interface PendientesPagoParams {
  /** Si > 0, solo clientes con pedidos > N días sin pagar. Default 0 (todos). */
  dias_atraso?: number;
  /** Cantidad máxima de clientes (default 50, max 100). */
  limit?: number;
}

export interface PendientesPagoResult {
  total_global: number;
  clientes_count: number;
  clientes: Array<{
    cliente_id: number;
    cliente_codigo: number | null;
    nombre: string;
    pedidos_pendientes: number;
    total_adeudado: number;
    pedido_mas_viejo: string | null;
    dias_max_atraso: number;
  }>;
}

export const pendientesPagoTool: Tool<PendientesPagoParams, PendientesPagoResult> = {
  name: "pendientes_pago",
  description:
    "Lista clientes con pedidos no pagados (admin/encargado). Ordenado por " +
    "días de atraso. Acepta `dias_atraso` para filtrar deuda vieja " +
    "(ej. dias_atraso=30 → solo pedidos sin pagar hace 30+ días). Devuelve " +
    "total adeudado global, cantidad de clientes, y lista priorizada con " +
    "monto + días de atraso por cliente. Filtra por sucursal del bot user.",
  parameters: {
    type: "object",
    properties: {
      dias_atraso: {
        type: "integer",
        minimum: 0,
        description: "Solo clientes con pedidos > N días sin pagar (default 0).",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 100,
        description: "Cantidad máxima de clientes (default 50, max 100).",
      },
    },
    required: [],
  },
  allowedRoles: ["admin", "encargado"],
  handler: async ({ dias_atraso = 0, limit = 50 }, ctx) => {
    if (!Number.isFinite(dias_atraso) || dias_atraso < 0) {
      throw new Error("dias_atraso debe ser >= 0");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 100) {
      throw new Error("Límite fuera de rango (1-100)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }

    const { data, error } = await ctx.supabase.rpc("bot_pendientes_pago", {
      p_sucursal_id: ctx.sucursal_id,
      p_dias_atraso: dias_atraso,
      p_limit: limit,
    });

    if (error) {
      throw new Error(`pendientes_pago: ${error.message}`);
    }

    type RpcCliente = {
      cliente_id: number;
      cliente_codigo: number | null;
      nombre_fantasia: string | null;
      razon_social: string | null;
      pedidos_pendientes: number;
      total_adeudado: number | string;
      pedido_mas_viejo: string | null;
      dias_max_atraso: number;
    };
    const r = data as {
      total_global: number | string;
      clientes_count: number;
      clientes: RpcCliente[];
    };

    return {
      total_global: Number(r.total_global ?? 0),
      clientes_count: Number(r.clientes_count ?? 0),
      clientes: (r.clientes ?? []).map((c) => ({
        cliente_id: Number(c.cliente_id),
        cliente_codigo: c.cliente_codigo ?? null,
        nombre: c.nombre_fantasia?.trim() || c.razon_social?.trim() ||
          "(sin nombre)",
        pedidos_pendientes: Number(c.pedidos_pendientes ?? 0),
        total_adeudado: Number(c.total_adeudado ?? 0),
        pedido_mas_viejo: c.pedido_mas_viejo ?? null,
        dias_max_atraso: Number(c.dias_max_atraso ?? 0),
      })),
    };
  },
};
