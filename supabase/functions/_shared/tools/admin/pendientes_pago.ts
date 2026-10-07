// Tool: pendientes_pago
//
// Clientes con saldo pendiente, ordenados por lo vencido. Pensada para que el
// admin/encargado priorice cobranzas.
//
// Desde la mig 300 la RPC consume `reporte_cuentas_por_cobrar`, la función de
// la pantalla Cuentas por cobrar: el saldo es total menos lo pagado, y la mora
// se cuenta desde la entrega más los días de crédito del cliente. Antes sumaba
// `total` sin restar lo pagado y la deuda salía un 51% más alta que en la app.

import type { Tool } from "../base.ts";

export interface PendientesPagoParams {
  /**
   * Días de MORA (vencido desde la entrega + días de crédito), por los tramos
   * de la pantalla: 0 = todos con saldo; 1-29 = con algo vencido; 30-59 =
   * vencido a más de 30 días; 60 o más = vencido a más de 60.
   */
  dias_atraso?: number;
  /** Cantidad máxima de clientes (default 50, max 100). */
  limit?: number;
}

export interface PendientesPagoResult {
  /** Saldo de los clientes que pasan el filtro. */
  total_global: number;
  /** Lo vencido de esos clientes. null si la RPC no lo trajo (nunca $0 inventado). */
  vencido_global: number | null;
  /** Saldo de toda la sucursal, sin filtro: el número de Cuentas por cobrar. */
  total_sucursal: number | null;
  clientes_count: number;
  /** Cómo se calcula, en palabras, para que el modelo no lo invente. */
  criterio: string | null;
  clientes: Array<{
    cliente_id: number;
    cliente_codigo: number | null;
    nombre: string;
    /** Cliente genérico de mostrador (mig 300), no un comercio real. */
    es_comodin: boolean;
    /** false si el cliente está dado de baja: la deuda no se va con él. */
    activo: boolean;
    pedidos_pendientes: number;
    total_adeudado: number;
    vencido: number;
    aging: {
      corriente: number;
      vencido_1_30: number;
      vencido_31_60: number;
      vencido_mas_60: number;
    };
  }>;
}

export const pendientesPagoTool: Tool<PendientesPagoParams, PendientesPagoResult> = {
  name: "pendientes_pago",
  description:
    "Clientes con saldo pendiente de cobro (admin/encargado), con el mismo " +
    "número que la pantalla Cuentas por cobrar. Ordenado por lo vencido. El " +
    "saldo es lo que falta pagar de cada pedido; la mora se cuenta desde la " +
    "entrega más los días de crédito del cliente. `dias_atraso` filtra por mora " +
    "(30 → vencido a más de 30 días; 60 → a más de 60). Devuelve el total de los filtrados, lo " +
    "vencido, el total de la sucursal y, por cliente, saldo y tramos de mora.",
  parameters: {
    type: "object",
    properties: {
      dias_atraso: {
        type: "integer",
        minimum: 0,
        description:
          "Días de mora (default 0 = todos con saldo). 1: con algo vencido; " +
          "30: vencido a más de 30 días; 60: vencido a más de 60.",
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
      es_comodin: boolean | null;
      activo: boolean | null;
      pedidos_pendientes: number;
      total_adeudado: number | string;
      vencido: number | string;
      corriente: number | string;
      vencido_1_30: number | string;
      vencido_31_60: number | string;
      vencido_mas_60: number | string;
    };
    const r = data as {
      total_global: number | string;
      vencido_global: number | string;
      total_sucursal: number | string;
      clientes_count: number;
      criterio?: string | null;
      clientes: RpcCliente[];
    };

    return {
      total_global: Number(r.total_global ?? 0),
      vencido_global: r.vencido_global == null ? null : Number(r.vencido_global),
      total_sucursal: r.total_sucursal == null ? null : Number(r.total_sucursal),
      clientes_count: Number(r.clientes_count ?? 0),
      criterio: r.criterio ?? null,
      clientes: (r.clientes ?? []).map((c) => ({
        cliente_id: Number(c.cliente_id),
        cliente_codigo: c.cliente_codigo ?? null,
        nombre: c.nombre_fantasia?.trim() || c.razon_social?.trim() ||
          "(sin nombre)",
        es_comodin: c.es_comodin === true,
        activo: c.activo !== false,
        pedidos_pendientes: Number(c.pedidos_pendientes ?? 0),
        total_adeudado: Number(c.total_adeudado ?? 0),
        vencido: Number(c.vencido ?? 0),
        aging: {
          corriente: Number(c.corriente ?? 0),
          vencido_1_30: Number(c.vencido_1_30 ?? 0),
          vencido_31_60: Number(c.vencido_31_60 ?? 0),
          vencido_mas_60: Number(c.vencido_mas_60 ?? 0),
        },
      })),
    };
  },
};
