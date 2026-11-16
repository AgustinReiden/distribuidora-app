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
//
// `total_compras` = facturas − notas de crédito de compra + transferencias netas
// entre sucursales (movimientos aceptados desde el 05/10/2026: + lo recibido,
// − lo enviado, a costo con IVA del origen). Las notas (devolución y ajuste, por
// la fecha de la nota) restan desde la decisión D9 de #1557, con su línea aparte
// en `compras_notas_credito`; una RPC anterior no la manda y ahí vale 0. Las
// reglas viven en `bot_compras_periodo` y `compras_transferencias_netas`.
// `compras_count` y `top_proveedores` son solo facturas de proveedores.

import type { Tool } from "../base.ts";

export interface ComprasPeriodoParams {
  desde: string;
  hasta: string;
  limit?: number;
}

export interface ComprasPeriodoResult {
  desde: string;
  hasta: string;
  /** Facturas − notas de crédito de compra + transferencias netas entre sucursales. */
  total_compras: number;
  /** Solo facturas de proveedores. */
  compras_facturas: number;
  /** + recibido de otras sucursales, − enviado (desde 05/10/2026). */
  compras_transferencias: number;
  /** Notas de crédito de compra del período (por la fecha de la nota), ya restadas del total. */
  compras_notas_credito: number;
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
    "monto. El total es neto de las notas de crédito de compra (por la fecha de la " +
    "nota) e incluye las transferencias netas entre sucursales desde el 05/10/2026 " +
    "(lo recibido suma, lo enviado resta): total_compras = compras_facturas − " +
    "compras_notas_credito + compras_transferencias. top_proveedores y " +
    "compras_count son sólo facturas. Las fechas son inclusive en formato YYYY-MM-DD. Filtra por sucursal " +
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
  allowedRoles: ["admin"],
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
      compras_facturas?: number | string;
      compras_transferencias?: number | string;
      compras_notas_credito?: number | string;
      compras_count: number;
      top_proveedores: RpcProveedor[];
    };

    return {
      desde: r.desde,
      hasta: r.hasta,
      total_compras: Number(r.total_compras ?? 0),
      // Opcionales por compat con la RPC anterior a la mig de transferencias.
      compras_facturas: Number(r.compras_facturas ?? r.total_compras ?? 0),
      compras_transferencias: Number(r.compras_transferencias ?? 0),
      // Opcional por compat con la RPC anterior a 1557-b3 (sin la clave: 0).
      compras_notas_credito: Number(r.compras_notas_credito ?? 0),
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
