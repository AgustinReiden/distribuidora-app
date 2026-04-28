// Tool: historico_pagos_cliente
//
// Últimos N pagos registrados de un cliente (forma_pago, monto, fecha).
// Pensada para que el admin/encargado pueda ver el comportamiento de pago
// de un cliente sin abrir la app web ("¿cómo me paga este cliente?").

import type { Tool } from "../base.ts";

export interface HistoricoPagosClienteParams {
  cliente_id: number;
  /** Cantidad máxima de pagos a devolver (default 20, max 50). */
  limit?: number;
}

export interface HistoricoPagosClienteResult {
  cliente_id: number;
  pagos_count: number;
  total_ultimos: number;
  pagos: Array<{
    id: number;
    monto: number;
    forma_pago: string | null;
    fecha: string;
    referencia: string | null;
    notas: string | null;
    pedido_id: number | null;
  }>;
}

export const historicoPagosClienteTool: Tool<
  HistoricoPagosClienteParams,
  HistoricoPagosClienteResult
> = {
  name: "historico_pagos_cliente",
  description:
    "Últimos N pagos registrados de un cliente, con forma de pago, monto " +
    "y fecha. Útil para ver el comportamiento de pago de un cliente " +
    "(admin/encargado). Filtra por sucursal del bot user.",
  parameters: {
    type: "object",
    properties: {
      cliente_id: {
        type: "integer",
        description: "ID del cliente.",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 50,
        description: "Cantidad de pagos a devolver (default 20, max 50).",
      },
    },
    required: ["cliente_id"],
  },
  allowedRoles: ["admin", "encargado"],
  handler: async ({ cliente_id, limit = 20 }, ctx) => {
    if (!Number.isInteger(cliente_id) || cliente_id <= 0) {
      throw new Error("cliente_id debe ser un entero positivo");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 50) {
      throw new Error("Límite fuera de rango (1-50)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }

    const { data, error } = await ctx.supabase.rpc(
      "bot_historico_pagos_cliente",
      {
        p_cliente_id: cliente_id,
        p_sucursal_id: ctx.sucursal_id,
        p_limit: limit,
      },
    );

    if (error) {
      throw new Error(`historico_pagos_cliente: ${error.message}`);
    }

    type RpcPago = {
      id: number;
      monto: number | string;
      forma_pago: string | null;
      fecha: string;
      referencia: string | null;
      notas: string | null;
      pedido_id: number | null;
    };
    const r = data as {
      cliente_id: number;
      pagos_count: number;
      total_ultimos: number | string;
      pagos: RpcPago[];
    };

    return {
      cliente_id: Number(r.cliente_id),
      pagos_count: Number(r.pagos_count ?? 0),
      total_ultimos: Number(r.total_ultimos ?? 0),
      pagos: (r.pagos ?? []).map((p) => ({
        id: Number(p.id),
        monto: Number(p.monto ?? 0),
        forma_pago: p.forma_pago ?? null,
        fecha: p.fecha,
        referencia: p.referencia ?? null,
        notas: p.notas ?? null,
        pedido_id: p.pedido_id ?? null,
      })),
    };
  },
};
