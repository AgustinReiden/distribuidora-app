// Tool: compras_periodo
//
// Resumen de compras a proveedores en un rango de fechas: total comprado,
// cantidad de compras, top proveedores. Pensada para que el admin/encargado
// responda "¿qué le compré a Coca-Cola este mes?", "¿cuánto gasté en
// stock en abril?".
//
// La fuente es la tabla `compras` (con compra_items + proveedores). Excluye
// compras canceladas (estado='cancelada'). El campo `compras.fecha_compra`
// es la fecha real de la compra (no created_at).

import type { Tool } from "../base.ts";

export interface ComprasPeriodoParams {
  desde: string;
  hasta: string;
  limit?: number;
}

export interface ComprasPeriodoResult {
  desde: string;
  hasta: string;
  total_compras: number;
  compras_count: number;
  top_proveedores: Array<{
    proveedor_id: number | null;
    nombre: string;
    cuit: string | null;
    total_comprado: number;
    compras_count: number;
  }>;
}

const FECHA_REGEX = /^\d{4}-\d{2}-\d{2}$/;

export const comprasPeriodoTool: Tool<ComprasPeriodoParams, ComprasPeriodoResult> = {
  name: "compras_periodo",
  description:
    "Resumen de compras a proveedores en un rango de fechas (admin/encargado). " +
    "Devuelve total comprado, cantidad de compras y top N proveedores con su " +
    "monto. Las fechas son inclusive en formato YYYY-MM-DD. Filtra por sucursal " +
    "del bot user. Excluye compras canceladas.",
  parameters: {
    type: "object",
    properties: {
      desde: { type: "string", description: "Fecha inicio inclusive (YYYY-MM-DD)." },
      hasta: { type: "string", description: "Fecha fin inclusive (YYYY-MM-DD)." },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Top N proveedores (default 10, max 25).",
      },
    },
    required: ["desde", "hasta"],
  },
  allowedRoles: ["admin", "encargado"],
  handler: async ({ desde, hasta, limit = 10 }, ctx) => {
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

    const { data, error } = await ctx.supabase.rpc("bot_compras_periodo", {
      p_desde: desde,
      p_hasta: hasta,
      p_sucursal_id: ctx.sucursal_id,
      p_limit: limit,
    });

    if (error) {
      throw new Error(`compras_periodo: ${error.message}`);
    }

    type RpcProveedor = {
      proveedor_id: number | null;
      nombre: string;
      cuit: string | null;
      total_comprado: number | string;
      compras_count: number;
    };
    const r = data as {
      desde: string;
      hasta: string;
      total_compras: number | string;
      compras_count: number;
      top_proveedores: RpcProveedor[];
    };

    return {
      desde: r.desde,
      hasta: r.hasta,
      total_compras: Number(r.total_compras ?? 0),
      compras_count: Number(r.compras_count ?? 0),
      top_proveedores: (r.top_proveedores ?? []).map((p) => ({
        proveedor_id: p.proveedor_id ?? null,
        nombre: p.nombre,
        cuit: p.cuit ?? null,
        total_comprado: Number(p.total_comprado ?? 0),
        compras_count: Number(p.compras_count ?? 0),
      })),
    };
  },
};
