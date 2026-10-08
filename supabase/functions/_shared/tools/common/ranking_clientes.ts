// Tool: ranking_clientes
//
// Mayores, menores o los que más cayeron, contra el período anterior de igual
// largo. La RPC consume `reporte_ventas_por_cliente` (la pantalla Reportes >
// Ventas por cliente), así que el número es el de la app (mig 308, BOT-B).
//
// Preventista: sus propias ventas (por quién cargó el pedido, mig 241).
// Admin/encargado: la sucursal, o un preventista si lo nombran.

import type { Tool } from "../base.ts";
import { resolverPreventista } from "./resolver_preventista.ts";

export interface RankingClientesParams {
  desde: string;
  hasta: string;
  /** 'mayores' (default), 'menores' o 'caidas'. */
  orden?: "mayores" | "menores" | "caidas";
  /** Sólo admin/encargado. */
  preventista?: string;
  /** Default 10, max 30. */
  limit?: number;
}

export interface RankingClientesResult {
  desde: string;
  hasta: string;
  anterior_desde: string;
  anterior_hasta: string;
  sucursal: string | null;
  /** "Todos" o el nombre del preventista. */
  preventista: string | null;
  orden: string;
  criterio: string | null;
  total_periodo: number;
  total_anterior: number;
  clientes_periodo: number;
  clientes: Array<{
    cliente_id: number;
    nombre: string;
    zona: string | null;
    es_comodin: boolean;
    activo: boolean | null;
    pedidos: number;
    total: number;
    total_anterior: number;
    variacion: number;
  }>;
}

const FECHA = /^\d{4}-\d{2}-\d{2}$/;

export const rankingClientesTool: Tool<RankingClientesParams, RankingClientesResult> = {
  name: "ranking_clientes",
  description:
    "Ranking de clientes por lo comprado (venta entregada, mig 241) en un período, " +
    "comparado con el período anterior de igual largo. orden='mayores' (quién más " +
    "compra), 'menores' (quién menos, entre los que compraron) o 'caidas' (quién " +
    "más bajó, incluidos los que dejaron de comprar). Es el número de Reportes > " +
    "Ventas por cliente. Preventista: sus ventas. Admin/encargado: la sucursal o un " +
    "preventista con `preventista`. Si un cliente viene con es_comodin=true, es de " +
    "mostrador: aclaralo.",
  parameters: {
    type: "object",
    properties: {
      desde: { type: "string", description: "YYYY-MM-DD inclusive." },
      hasta: { type: "string", description: "YYYY-MM-DD inclusive." },
      orden: { type: "string", enum: ["mayores", "menores", "caidas"], description: "Default 'mayores'." },
      preventista: {
        type: "string",
        description: "Sólo admin/encargado: nombre de quien cargó las ventas (preventista, encargado o admin, aunque ya no esté).",
      },
      limit: { type: "integer", minimum: 1, maximum: 30, description: "Default 10, max 30." },
    },
    required: ["desde", "hasta"],
  },
  allowedRoles: ["admin", "encargado", "preventista"],
  handler: async ({ desde, hasta, orden = "mayores", preventista, limit = 10 }, ctx) => {
    if (!FECHA.test(desde) || !FECHA.test(hasta)) {
      throw new Error("Las fechas van en formato YYYY-MM-DD (desde y hasta).");
    }
    if (desde > hasta) {
      throw new Error("La fecha desde es posterior a hasta.");
    }
    if (!["mayores", "menores", "caidas"].includes(orden)) {
      throw new Error("orden debe ser mayores, menores o caidas");
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > 30) {
      throw new Error("limit fuera de rango (1-30)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }
    const veTodo = ctx.rol === "admin" || ctx.rol === "encargado";
    // "vendedor": cualquiera que vendió en la sucursal, como el desplegable de
    // Reportes (no sólo preventistas activos).
    const filtro = veTodo && preventista
      ? await resolverPreventista(ctx, preventista, "vendedor")
      : null;

    const { data, error } = await ctx.supabase.rpc("bot_ranking_clientes", {
      p_desde: desde,
      p_hasta: hasta,
      p_sucursal_id: ctx.sucursal_id,
      p_rol: ctx.rol,
      p_perfil_id: ctx.perfil_id,
      p_preventista_id: filtro?.id ?? null,
      p_orden: orden,
      p_limit: limit,
    });
    if (error) {
      throw new Error(`ranking_clientes: ${error.message}`);
    }
    const r = (data ?? {}) as Record<string, unknown>;
    const filas = (Array.isArray(r.clientes) ? r.clientes : []) as Array<Record<string, unknown>>;
    return {
      desde: String(r.desde ?? desde),
      hasta: String(r.hasta ?? hasta),
      anterior_desde: String(r.anterior_desde ?? ""),
      anterior_hasta: String(r.anterior_hasta ?? ""),
      sucursal: (r.sucursal as string | null) ?? null,
      preventista: (r.preventista as string | null) ?? null,
      orden: String(r.orden ?? orden),
      criterio: (r.criterio as string | null) ?? null,
      total_periodo: Number(r.total_periodo ?? 0),
      total_anterior: Number(r.total_anterior ?? 0),
      clientes_periodo: Number(r.clientes_periodo ?? 0),
      clientes: filas.map((c) => ({
        cliente_id: Number(c.cliente_id),
        nombre: String(c.nombre ?? "(sin nombre)"),
        zona: (c.zona as string | null) ?? null,
        es_comodin: c.es_comodin === true,
        activo: c.activo == null ? null : c.activo === true,
        pedidos: Number(c.pedidos ?? 0),
        total: Number(c.total ?? 0),
        total_anterior: Number(c.total_anterior ?? 0),
        variacion: Number(c.variacion ?? 0),
      })),
    };
  },
};
