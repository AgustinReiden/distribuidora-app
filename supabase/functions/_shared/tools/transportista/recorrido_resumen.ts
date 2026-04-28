// Tool: recorrido_resumen
//
// Recap del día para el transportista: total facturado vs cobrado,
// pedidos entregados / pendientes, % de cobro. Útil al cierre del día
// antes de rendir, o para que el admin vea cómo está cualquier
// transportista.
//
// Si no hay recorrido para esa fecha, devuelve recorrido=null y la tool
// lanza un error amigable.

import type { Tool } from "../base.ts";

export interface RecorridoResumenParams {
  /** YYYY-MM-DD. Default: hoy en TZ del servidor. */
  fecha?: string;
}

export interface RecorridoResumenResult {
  recorrido_id: number;
  fecha: string;
  estado: string | null;
  total_pedidos: number;
  pedidos_entregados: number;
  pedidos_pendientes: number;
  total_facturado: number;
  total_cobrado: number;
  porcentaje_cobrado: number;
  completed_at: string | null;
}

const FECHA_REGEX = /^\d{4}-\d{2}-\d{2}$/;

export const recorridoResumenTool: Tool<RecorridoResumenParams, RecorridoResumenResult> = {
  name: "recorrido_resumen",
  description:
    "Resumen del día del transportista: pedidos entregados/pendientes, " +
    "total facturado vs cobrado, % de cobro. Sin args usa la fecha de hoy. " +
    "Útil al cierre del día antes de rendir.",
  parameters: {
    type: "object",
    properties: {
      fecha: {
        type: "string",
        description: "Fecha YYYY-MM-DD (default: hoy).",
      },
    },
    required: [],
  },
  allowedRoles: ["admin", "encargado", "transportista"],
  handler: async ({ fecha }, ctx) => {
    if (fecha != null && !FECHA_REGEX.test(fecha)) {
      throw new Error("fecha inválida (esperado YYYY-MM-DD)");
    }
    if (ctx.rol === "transportista" && ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }
    if (ctx.sucursal_id == null) {
      throw new Error(
        "Sucursal no resuelta para esta consulta. Mencionale al admin que " +
          "te asigne una sucursal default.",
      );
    }

    // El RPC requiere transportista_id (UUID). Por ahora solo soportamos
    // que el caller sea el transportista mismo (su perfil_id). Una iter
    // futura puede sumar un param explícito para que admin/encargado
    // consulten el día de otro transportista — necesitaría un lookup de
    // perfiles.rol y validación.
    const { data, error } = await ctx.supabase.rpc("bot_recorrido_resumen", {
      p_transportista_id: ctx.perfil_id,
      p_sucursal_id: ctx.sucursal_id,
      p_fecha: fecha ?? null,
    });

    if (error) {
      throw new Error(`recorrido_resumen: ${error.message}`);
    }
    if (data === null || data === undefined) {
      throw new Error(
        fecha
          ? `No tenés recorrido cargado para el ${fecha}.`
          : "No tenés recorrido cargado para hoy.",
      );
    }

    const r = data as {
      recorrido_id: number;
      fecha: string;
      estado: string | null;
      total_pedidos: number;
      pedidos_entregados: number;
      pedidos_pendientes: number;
      total_facturado: number | string;
      total_cobrado: number | string;
      porcentaje_cobrado: number | string;
      completed_at: string | null;
    };

    return {
      recorrido_id: Number(r.recorrido_id),
      fecha: r.fecha,
      estado: r.estado ?? null,
      total_pedidos: Number(r.total_pedidos ?? 0),
      pedidos_entregados: Number(r.pedidos_entregados ?? 0),
      pedidos_pendientes: Number(r.pedidos_pendientes ?? 0),
      total_facturado: Number(r.total_facturado ?? 0),
      total_cobrado: Number(r.total_cobrado ?? 0),
      porcentaje_cobrado: Number(r.porcentaje_cobrado ?? 0),
      completed_at: r.completed_at ?? null,
    };
  },
};
