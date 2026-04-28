// Tool: productos_recurrentes_cliente
//
// Top productos que el cliente compra más seguido en los últimos N días.
// Ordenado por cantidad de pedidos donde aparece el producto (un producto
// que apareció en 5 pedidos > uno con 100 unidades en un solo pedido).
//
// Útil para que el preventista ofrezca "lo de siempre" sin tener que
// memorizar el patrón de cada cliente. Mismo gate de scope que
// historico_pedidos_cliente.

import type { Tool } from "../base.ts";

export interface ProductosRecurrentesParams {
  cliente_id: number;
  dias?: number;
  limit?: number;
}

export interface ProductosRecurrentesResult {
  cliente_id: number;
  rango_dias: number;
  productos: Array<{
    id: number;
    codigo: string | null;
    nombre: string;
    precio: number;
    pedidos_con_producto: number;
    unidades_totales: number;
    facturado_total: number;
  }>;
  error?: string;
}

export const productosRecurrentesTool: Tool<
  ProductosRecurrentesParams,
  ProductosRecurrentesResult
> = {
  name: "productos_recurrentes_cliente",
  description:
    "Top productos que el cliente compra más seguido en los últimos N días, " +
    "ordenado por cantidad de pedidos donde aparece. Útil para preventistas " +
    "que quieren ofrecer 'lo de siempre' sin memorizar el patrón. Para " +
    "preventistas solo devuelve datos si el cliente está asignado.",
  parameters: {
    type: "object",
    properties: {
      cliente_id: { type: "integer", description: "ID del cliente." },
      dias: {
        type: "integer",
        minimum: 7,
        maximum: 365,
        description: "Ventana en días (default 90, max 365).",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Top N productos (default 10, max 25).",
      },
    },
    required: ["cliente_id"],
  },
  allowedRoles: ["admin", "encargado", "preventista"],
  handler: async ({ cliente_id, dias = 90, limit = 10 }, ctx) => {
    if (!Number.isInteger(cliente_id) || cliente_id <= 0) {
      throw new Error("cliente_id debe ser entero positivo");
    }
    if (!Number.isFinite(dias) || dias < 7 || dias > 365) {
      throw new Error("dias fuera de rango (7-365)");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 25) {
      throw new Error("limit fuera de rango (1-25)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }

    const { data, error } = await ctx.supabase.rpc(
      "bot_productos_recurrentes_cliente",
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
      throw new Error(`productos_recurrentes_cliente: ${error.message}`);
    }

    type RpcRow = {
      id: number;
      codigo: string | null;
      nombre: string;
      precio: number | string;
      pedidos_con_producto: number;
      unidades_totales: number | string;
      facturado_total: number | string;
    };
    const r = data as {
      cliente_id: number;
      rango_dias: number;
      productos: RpcRow[];
      error?: string;
    };

    if (r.error) {
      return {
        cliente_id,
        rango_dias: dias,
        productos: [],
        error: r.error,
      };
    }

    return {
      cliente_id: Number(r.cliente_id),
      rango_dias: Number(r.rango_dias ?? dias),
      productos: (r.productos ?? []).map((p) => ({
        id: Number(p.id),
        codigo: p.codigo ?? null,
        nombre: p.nombre,
        precio: Number(p.precio ?? 0),
        pedidos_con_producto: Number(p.pedidos_con_producto ?? 0),
        unidades_totales: Number(p.unidades_totales ?? 0),
        facturado_total: Number(p.facturado_total ?? 0),
      })),
    };
  },
};
