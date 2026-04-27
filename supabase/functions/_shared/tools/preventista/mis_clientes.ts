// Tool: mis_clientes (preventista-only)
//
// Lista la cartera de clientes asignados al preventista que invoca, con
// saldo_cuenta y "días desde la última compra". Pensado para "mostrame mi
// cartera" / "qué clientes con deuda tengo" / "qué clientes no compran hace
// más de N días".
//
// Implementación: la lógica vive en la RPC SQL `bot_mis_clientes`
// (migrations/015_bot_rpcs_phase2.sql) — más limpio que hacer N+1 desde TS
// y permite calcular `dias_desde_ultima` en una sola pasada.
//
// La RPC corre con SECURITY DEFINER y solo está GRANTed a service_role. Acá
// pasamos `ctx.perfil_id` como `p_preventista_id` y `ctx.sucursal_id` como
// `p_sucursal_id` — la edge function usa service_role pero NO confiamos en
// la RPC para validar rol/sucursal: ese gate ya lo hizo `allowedRoles` +
// el guard liviano de abajo.

import type { Tool } from "../base.ts";

interface MisClientesParams {
  /** Filtrar solo clientes con saldo_cuenta > 0. Default false. */
  con_deuda?: boolean;
  /**
   * Solo clientes sin pedidos no-cancelados en los últimos N días (>= 1).
   * Si está ausente / undefined, no se aplica filtro. Antes 0 era sentinel
   * de "sin filtro" — eliminado por confuso (un LLM mandando `0` probablemente
   * quiere decir "sin gap", no "ignoralo").
   */
  sin_pedidos_dias?: number;
  /** Default 20, max 50. */
  limit?: number;
}

interface MisClientesResult {
  total: number;
  clientes: Array<{
    id: number;
    codigo: number | null;
    nombre: string;
    saldo_cuenta: number;
    zona: string | null;
    /** ISO date YYYY-MM-DD (o timestamp); null si nunca compró. */
    ultima_compra: string | null;
    /** Entero >= 0; null si nunca compró. */
    dias_desde_ultima: number | null;
  }>;
}

interface RpcRow {
  id: number;
  codigo: number | null;
  nombre_fantasia: string | null;
  razon_social: string | null;
  saldo_cuenta: number | string | null;
  zona: string | null;
  ultima_compra: string | null;
  dias_desde_ultima: number | string | null;
}

interface RpcResponse {
  total?: number;
  clientes?: RpcRow[];
}

export const misClientesTool: Tool<MisClientesParams, MisClientesResult> = {
  name: "mis_clientes",
  description:
    "Lista la cartera de clientes asignados al preventista que invoca. " +
    "Incluye saldo_cuenta, zona, fecha de última compra y días desde la última. " +
    "Filtros opcionales: con_deuda (solo saldo > 0) y sin_pedidos_dias (clientes " +
    "que no compran hace al menos N días — útil para detectar rotación lenta).",
  parameters: {
    type: "object",
    properties: {
      con_deuda: {
        type: "boolean",
        description: "Si true, solo retorna clientes con saldo_cuenta > 0.",
      },
      sin_pedidos_dias: {
        type: "integer",
        minimum: 1,
        maximum: 365,
        description:
          "Solo clientes sin pedidos no-cancelados en los últimos N días " +
          "(incluye los que nunca compraron). Omitir el parámetro para " +
          "no aplicar filtro.",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 50,
        default: 20,
        description: "Cantidad máxima de resultados (default 20, máx 50).",
      },
    },
  },
  allowedRoles: ["preventista"],
  handler: async ({ con_deuda, sin_pedidos_dias, limit }, ctx) => {
    // Defense-in-depth: allowedRoles ya garantiza esto en invokeTool, pero
    // si alguien llama el handler directo (tests, scripts) lo bloqueamos acá.
    if (ctx.rol !== "preventista") {
      throw new Error("mis_clientes solo está disponible para preventistas");
    }

    // Multi-tenancy: un preventista SIEMPRE debe tener sucursal asignada.
    // sucursal_id null en este rol es un data error.
    if (ctx.sucursal_id == null) {
      throw new Error(
        "Sucursal no asignada en bot_usuarios — contactá al administrador",
      );
    }

    // Validación de params (no confiamos en el JSON Schema cuando este
    // handler se llama directo en tests).
    let effectiveLimit = 20;
    if (limit !== undefined) {
      if (!Number.isInteger(limit) || limit < 1 || limit > 50) {
        throw new Error("limit fuera de rango (1-50)");
      }
      effectiveLimit = limit;
    }

    // sin_pedidos_dias: omitir → null (no filtra). >= 1 → se aplica.
    // 0 / negativos / no-int rechazados explícitamente — antes 0 era un
    // sentinel "sin filtro", ahora es un error de input (más predecible
    // para callers LLM).
    let effectiveSinPedidos: number | null = null;
    if (sin_pedidos_dias !== undefined && sin_pedidos_dias !== null) {
      if (
        !Number.isInteger(sin_pedidos_dias) || sin_pedidos_dias < 1 ||
        sin_pedidos_dias > 365
      ) {
        throw new Error("sin_pedidos_dias debe ser entero entre 1 y 365");
      }
      effectiveSinPedidos = sin_pedidos_dias;
    }

    const effectiveConDeuda = con_deuda === true;

    const sb = ctx.supabase;
    const { data, error } = await sb.rpc("bot_mis_clientes", {
      p_preventista_id: ctx.perfil_id,
      p_sucursal_id: ctx.sucursal_id,
      p_con_deuda: effectiveConDeuda,
      p_sin_pedidos_dias: effectiveSinPedidos,
      p_limit: effectiveLimit,
    });

    if (error) {
      throw new Error(`mis_clientes: ${error.message}`);
    }

    const resp = (data ?? {}) as RpcResponse;
    const rows = Array.isArray(resp.clientes) ? resp.clientes : [];

    return {
      total: Number(resp.total ?? rows.length),
      clientes: rows.map((c) => {
        const dias = c.dias_desde_ultima;
        const diasNum = dias === null || dias === undefined
          ? null
          : Number(dias);
        return {
          id: Number(c.id),
          codigo: c.codigo === null || c.codigo === undefined
            ? null
            : Number(c.codigo),
          nombre: c.nombre_fantasia || c.razon_social || "(sin nombre)",
          saldo_cuenta: Number(c.saldo_cuenta ?? 0),
          zona: c.zona ?? null,
          ultima_compra: c.ultima_compra ?? null,
          dias_desde_ultima: diasNum !== null && Number.isFinite(diasNum)
            ? diasNum
            : null,
        };
      }),
    };
  },
};
