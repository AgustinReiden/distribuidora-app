// Tool: historico_pedidos_cliente
//
// Drill-down de la ficha de un cliente: últimos N pedidos del cliente con
// items resumidos. Pensada para que el preventista vea "lo último que le
// vendí" antes de visitar al cliente, o el admin/encargado vean el patrón
// de pedidos de un cliente cualquiera.
//
// El gate de scope vive en el RPC: si rol=preventista, exige que el cliente
// esté en cliente_preventistas para el preventista que invoca. Si no,
// devuelve {error: 'Cliente no asignado a este preventista'}.

import type { Tool } from "../base.ts";

export interface HistoricoClienteParams {
  cliente_id: number;
  /** Días hacia atrás. Default 90, max 365. */
  dias?: number;
  /** Cantidad de pedidos. Default 20, max 50. */
  limit?: number;
}

export interface HistoricoClienteResult {
  cliente_id: number;
  pedidos_count: number;
  rango_dias: number;
  total_periodo: number;
  pedidos: Array<{
    id: number;
    fecha: string;
    total: number;
    estado: string | null;
    estado_pago: string | null;
    created_at: string;
    items: Array<{
      producto_id: number;
      codigo: string | null;
      nombre: string;
      cantidad: number;
      subtotal: number;
    }>;
  }>;
  /** Solo presente si el preventista no tiene scope sobre el cliente. */
  error?: string;
}

export const historicoClienteTool: Tool<HistoricoClienteParams, HistoricoClienteResult> = {
  name: "historico_pedidos_cliente",
  description:
    "Últimos N pedidos del cliente con items resumidos. Útil para drill-down " +
    "de la ficha (admin/encargado/preventista). Para preventistas solo " +
    "devuelve datos si el cliente está asignado al preventista que invoca.",
  parameters: {
    type: "object",
    properties: {
      cliente_id: { type: "integer", description: "ID del cliente." },
      dias: {
        type: "integer",
        minimum: 1,
        maximum: 365,
        description: "Días hacia atrás (default 90, max 365).",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 50,
        description: "Cantidad de pedidos (default 20, max 50).",
      },
    },
    required: ["cliente_id"],
  },
  allowedRoles: ["admin", "encargado", "preventista"],
  handler: async ({ cliente_id, dias = 90, limit = 20 }, ctx) => {
    if (!Number.isInteger(cliente_id) || cliente_id <= 0) {
      throw new Error("cliente_id debe ser entero positivo");
    }
    if (!Number.isFinite(dias) || dias < 1 || dias > 365) {
      throw new Error("dias fuera de rango (1-365)");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 50) {
      throw new Error("limit fuera de rango (1-50)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }

    const { data, error } = await ctx.supabase.rpc(
      "bot_historico_pedidos_cliente",
      {
        p_cliente_id: cliente_id,
        p_perfil_id: ctx.perfil_id,
        p_rol: ctx.rol,
        p_sucursal_id: ctx.sucursal_id,
        p_dias: dias,
        p_limit: limit,
      },
    );

    if (error) {
      throw new Error(`historico_pedidos_cliente: ${error.message}`);
    }

    type RpcItem = {
      producto_id: number;
      codigo: string | null;
      nombre: string;
      cantidad: number;
      subtotal: number | string;
    };
    type RpcPedido = {
      id: number;
      fecha: string;
      total: number | string;
      estado: string | null;
      estado_pago: string | null;
      created_at: string;
      items: RpcItem[] | null;
    };
    const r = data as {
      cliente_id: number;
      pedidos_count: number;
      rango_dias: number;
      total_periodo?: number | string;
      pedidos: RpcPedido[];
      error?: string;
    };

    if (r.error) {
      return {
        cliente_id,
        pedidos_count: 0,
        rango_dias: dias,
        total_periodo: 0,
        pedidos: [],
        error: r.error,
      };
    }

    return {
      cliente_id: Number(r.cliente_id),
      pedidos_count: Number(r.pedidos_count ?? 0),
      rango_dias: Number(r.rango_dias ?? dias),
      total_periodo: Number(r.total_periodo ?? 0),
      pedidos: (r.pedidos ?? []).map((p) => ({
        id: Number(p.id),
        fecha: p.fecha,
        total: Number(p.total ?? 0),
        estado: p.estado ?? null,
        estado_pago: p.estado_pago ?? null,
        created_at: p.created_at,
        items: (p.items ?? []).map((it) => ({
          producto_id: Number(it.producto_id),
          codigo: it.codigo ?? null,
          nombre: it.nombre,
          cantidad: Number(it.cantidad ?? 0),
          subtotal: Number(it.subtotal ?? 0),
        })),
      })),
    };
  },
};
