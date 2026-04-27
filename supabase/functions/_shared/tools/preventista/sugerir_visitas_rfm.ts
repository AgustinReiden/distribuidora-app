// Tool: sugerir_visitas_rfm (preventista-only)
//
// Sugerencias proactivas de "qué clientes visitar hoy" usando un scoring RFM
// custom (Recencia + Frecuencia + Monto, ponderado 0.5/0.25/0.25). La lógica
// vive en la RPC SQL `bot_sugerir_visitas_rfm` (migrations/017_bot_rfm.sql)
// — todo el window function + percentiles se hace en una pasada SQL, no
// queremos N+1 desde TS.
//
// La RPC corre con SECURITY DEFINER y solo está GRANTed a service_role.
// El gate de rol/sucursal se hace acá antes de invocar (igual que el resto
// de las tools `bot_*`).

import type { Tool } from "../base.ts";

export interface SugerirVisitasRfmParams {
  /** Default 10, max 25. */
  limit?: number;
}

export interface SugerenciaVisita {
  cliente_id: number;
  codigo: number | null;
  nombre: string;
  zona: string | null;
  saldo_cuenta: number;
  /** ISO date YYYY-MM-DD; null si nunca compró. */
  ultima_compra: string | null;
  /** Entero >= 0; 9999 si nunca compró (sentinel del RPC). */
  dias_desde_ultima: number;
  /** Frecuencia efectiva en días (default 21 si <3 pedidos). */
  frecuencia_dias: number;
  /** Ticket promedio sobre los últimos 180 días (0 si nunca compró). */
  ticket_promedio: number;
  /** Cantidad de pedidos no-cancelados en los últimos 180 días. */
  n_pedidos: number;
  /** Score combinado, 0..~1.25 (la R puede llegar a 0.5*5=2.5 cap, F y M a 1). */
  score: number;
  /** True si días_desde_ultima > frecuencia * 1.3 (re-pedido vencido). */
  vencido: boolean;
  /** Texto user-friendly para mostrar en el motivo. */
  motivo: string;
}

export interface SugerirVisitasRfmResult {
  /** Cuántos resultados retornó la RPC (= sugerencias.length, capeado a limit). */
  total: number;
  sugerencias: SugerenciaVisita[];
}

interface RpcResponse {
  total?: number;
  sugerencias?: Array<Record<string, unknown>>;
}

export const sugerirVisitasRfmTool: Tool<
  SugerirVisitasRfmParams,
  SugerirVisitasRfmResult
> = {
  name: "sugerir_visitas_rfm",
  description:
    "Sugiere los clientes que el preventista debería priorizar visitar hoy. " +
    "Usa scoring RFM (recencia + frecuencia + monto) sobre los últimos 180 días, " +
    "devuelve top N con motivo legible. Útil cuando el usuario pregunta " +
    "'a quién visito', 'qué clientes tengo atrasados', 'priorizá mi ruta'.",
  parameters: {
    type: "object",
    properties: {
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        default: 10,
        description: "Cantidad de sugerencias. Entre 1 y 25.",
      },
    },
  },
  allowedRoles: ["preventista"],
  handler: async ({ limit = 10 }, ctx) => {
    // Defense-in-depth: allowedRoles ya garantiza esto en invokeTool, pero si
    // alguien llama el handler directo (tests, scripts) lo bloqueamos acá.
    if (ctx.rol !== "preventista") {
      throw new Error("sugerir_visitas_rfm solo está disponible para preventistas");
    }

    // Multi-tenancy: un preventista SIEMPRE debe tener sucursal asignada.
    if (ctx.sucursal_id == null) {
      throw new Error(
        "Sucursal no asignada en bot_usuarios — contactá al administrador",
      );
    }

    // Validación del param. No confiamos en el JSON Schema cuando este handler
    // se llama directo en tests.
    if (!Number.isInteger(limit) || limit < 1 || limit > 25) {
      throw new Error("limit debe ser entero entre 1 y 25");
    }

    const { data, error } = await ctx.supabase.rpc("bot_sugerir_visitas_rfm", {
      p_preventista_id: ctx.perfil_id,
      p_sucursal_id: ctx.sucursal_id,
      p_limit: limit,
    });
    if (error) {
      throw new Error(`sugerir_visitas_rfm: ${error.message}`);
    }

    const payload = (data ?? {}) as RpcResponse;
    const arr = Array.isArray(payload.sugerencias) ? payload.sugerencias : [];

    const sugerencias: SugerenciaVisita[] = arr.map((row) => {
      const r = row as Record<string, unknown>;
      return {
        cliente_id: Number(r.cliente_id),
        codigo: r.codigo == null ? null : Number(r.codigo),
        nombre: String(r.nombre ?? "(sin nombre)"),
        zona: r.zona == null ? null : String(r.zona),
        saldo_cuenta: Number(r.saldo_cuenta ?? 0),
        ultima_compra: r.ultima_compra == null ? null : String(r.ultima_compra),
        dias_desde_ultima: Number(r.dias_desde_ultima ?? 9999),
        frecuencia_dias: Number(r.frecuencia_dias ?? 21),
        ticket_promedio: Number(r.ticket_promedio ?? 0),
        n_pedidos: Number(r.n_pedidos ?? 0),
        score: Number(r.score ?? 0),
        vencido: Boolean(r.vencido),
        motivo: String(r.motivo ?? ""),
      };
    });

    return {
      total: Number(payload.total ?? sugerencias.length),
      sugerencias,
    };
  },
};
