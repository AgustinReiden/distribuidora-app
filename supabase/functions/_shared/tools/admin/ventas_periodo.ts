// Tool: ventas_periodo
//
// Devuelve el resumen de ventas en un rango de fechas: total facturado,
// cantidad de pedidos, ticket promedio, top N clientes, top N productos.
// Pensada para que el LLM responda preguntas tipo "¿cuánto vendí este
// mes?", "¿qué productos vendo más?", "¿qué clientes me compraron más?".
//
// Delega 100% a la RPC bot_ventas_periodo (migration 022).

import type { Tool } from "../base.ts";

export interface VentasPeriodoParams {
  /** Fecha inicio inclusive (YYYY-MM-DD). */
  desde: string;
  /** Fecha fin inclusive (YYYY-MM-DD). */
  hasta: string;
  /** Top N para listas de clientes y productos. Default 10, max 25. */
  limit?: number;
}

export interface VentasPeriodoResult {
  desde: string;
  hasta: string;
  total_ventas: number;
  pedidos_count: number;
  ticket_promedio: number;
  // Pedidos cargados pero AÚN NO entregados (asignado/pendiente) en el período.
  // NO son venta: van aparte para que el usuario no los confunda con lo vendido.
  en_curso_monto: number;
  en_curso_pedidos: number;
  // Momento en que se ejecutó el RPC (zona ART). El LLM debe mostrarlo al
  // final de la respuesta para que el usuario pueda contrastar contra el
  // panel sabiendo que el panel puede haberse refrescado en otro instante.
  consulta_realizada_at: string;
  top_clientes: Array<{
    id: number;
    codigo: number | null;
    nombre: string;
    total_comprado: number;
    pedidos: number;
  }>;
  top_productos: Array<{
    id: number;
    codigo: string | null;
    nombre: string;
    unidades: number;
    facturado: number;
  }>;
}

const FECHA_REGEX = /^\d{4}-\d{2}-\d{2}$/;

export const ventasPeriodoTool: Tool<VentasPeriodoParams, VentasPeriodoResult> = {
  name: "ventas_periodo",
  description:
    "Resumen de ventas en un rango de fechas (admin/encargado). Devuelve " +
    "total facturado, cantidad de pedidos, ticket promedio, top clientes, " +
    "top productos y el timestamp ART en que se ejecutó la consulta " +
    "(consulta_realizada_at) para que el usuario pueda contrastar contra el " +
    "panel sabiendo cuándo se tomó el dato. Las fechas son inclusive en " +
    "formato YYYY-MM-DD. Filtra por sucursal del bot user. total_ventas cuenta " +
    "SOLO ventas ENTREGADAS (estado='entregado', canal='app') — coincide con el " +
    "reporte gerencial. Los pedidos cargados pero todavía no entregados " +
    "(asignado/pendiente) se devuelven aparte en en_curso_monto/en_curso_pedidos " +
    "y NO deben sumarse a la venta.",
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
        description: "Top N para clientes y productos (default 10, max 25).",
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

    const { data, error } = await ctx.supabase.rpc("bot_ventas_periodo", {
      p_desde: desde,
      p_hasta: hasta,
      p_sucursal_id: ctx.sucursal_id,
      p_limit: limit,
    });

    if (error) {
      throw new Error(`ventas_periodo: ${error.message}`);
    }

    // El RPC retorna nombre_fantasia + razon_social separados; mergeamos
    // a `nombre` (preferimos nombre_fantasia) para que el formatter no
    // tenga que decidir.
    type RpcCliente = {
      id: number;
      codigo: number | null;
      nombre_fantasia: string | null;
      razon_social: string | null;
      total_comprado: number | string;
      pedidos: number;
    };
    type RpcProducto = {
      id: number;
      codigo: string | null;
      nombre: string;
      unidades: number;
      facturado: number | string;
    };
    const r = data as {
      desde: string;
      hasta: string;
      total_ventas: number | string;
      pedidos_count: number;
      ticket_promedio: number | string;
      en_curso_monto: number | string;
      en_curso_pedidos: number;
      top_clientes: RpcCliente[];
      top_productos: RpcProducto[];
    };

    const consultaRealizadaAt = new Date().toLocaleString("es-AR", {
      timeZone: "America/Argentina/Buenos_Aires",
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }) + " (ART)";

    return {
      desde: r.desde,
      hasta: r.hasta,
      total_ventas: Number(r.total_ventas ?? 0),
      pedidos_count: Number(r.pedidos_count ?? 0),
      ticket_promedio: Number(r.ticket_promedio ?? 0),
      en_curso_monto: Number(r.en_curso_monto ?? 0),
      en_curso_pedidos: Number(r.en_curso_pedidos ?? 0),
      consulta_realizada_at: consultaRealizadaAt,
      top_clientes: (r.top_clientes ?? []).map((c) => ({
        id: Number(c.id),
        codigo: c.codigo ?? null,
        nombre: c.nombre_fantasia?.trim() || c.razon_social?.trim() ||
          "(sin nombre)",
        total_comprado: Number(c.total_comprado ?? 0),
        pedidos: Number(c.pedidos ?? 0),
      })),
      top_productos: (r.top_productos ?? []).map((p) => ({
        id: Number(p.id),
        codigo: p.codigo ?? null,
        nombre: p.nombre,
        unidades: Number(p.unidades ?? 0),
        facturado: Number(p.facturado ?? 0),
      })),
    };
  },
};
