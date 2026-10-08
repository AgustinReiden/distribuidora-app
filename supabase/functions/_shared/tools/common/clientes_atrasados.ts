// Tool: clientes_atrasados
//
// Clientes que dejaron de comprar a su ritmo, ordenados por la plata que hay
// en juego. Reemplaza a `sugerir_visitas_rfm` (mig 305): una sola definición
// de "atrasado", medida contra la frecuencia de CADA cliente, que vive en
// `clientes_ritmo_compra()`.
//
// Alcance (decisiones del dueño, 2026-10-07):
//   * Preventista: su cartera = asignados + huérfanos donde vendió en 180
//     días. Hechos (cuándo compró) de todos los pedidos; montos, propios.
//   * Admin / encargado: toda la sucursal, o la cartera de un preventista si lo
//     nombran.

import type { Tool } from "../base.ts";
import { resolverPreventista } from "./resolver_preventista.ts";

export interface ClientesAtrasadosParams {
  /** Sólo admin/encargado: nombre del preventista cuya cartera mirar. */
  preventista?: string;
  /** Sumar los que están por vencer (1,5 veces su frecuencia). */
  incluir_por_vencer?: boolean;
  /** Sumar inactivos (91 a 180 días) y ocasionales (menos de 3 compras al año). */
  incluir_inactivos?: boolean;
  /** Default 15, max 50. */
  limit?: number;
}

export interface ClienteAtrasado {
  cliente_id: number;
  codigo: number | null;
  nombre: string;
  zona: string | null;
  es_comodin: boolean;
  saldo: number;
  ultima_compra: string | null;
  dias_sin_comprar: number | null;
  frecuencia_dias: number | null;
  ratio: number | null;
  estado: string;
  monto_mensual: number;
}

export interface ClientesAtrasadosResult {
  cartera: "sucursal" | "preventista";
  /** Nombre del preventista filtrado (admin) o null. */
  preventista: string | null;
  montos: "todos" | "propios";
  clientes_en_cartera: number;
  por_estado: Record<string, number>;
  atrasados: number;
  monto_mensual_en_riesgo: number;
  criterio: string | null;
  /** El número de la alerta del reporte gerencial, con su criterio (sólo sucursal). */
  alerta_app_clientes_inactivos: { cantidad: number; criterio: string } | null;
  clientes: ClienteAtrasado[];
}

export const clientesAtrasadosTool: Tool<ClientesAtrasadosParams, ClientesAtrasadosResult> = {
  name: "clientes_atrasados",
  description:
    "Clientes que dejaron de comprar a su ritmo habitual, ordenados por lo que " +
    "compran por mes (la plata en riesgo). 'Atrasado' se mide contra la " +
    "frecuencia de CADA cliente: uno que compra cada semana y lleva 3 sin " +
    "comprar está atrasado; uno mensual con 3 semanas, no. Usala para '¿quién " +
    "dejó de comprar?', 'clientes atrasados', 'a quién visito', 'churn'. " +
    "Preventista: su cartera, con montos propios. Admin/encargado: la sucursal, " +
    "o la cartera de un preventista con `preventista`. Si viene " +
    "`alerta_app_clientes_inactivos`, aclarale al usuario que esa alerta del " +
    "reporte usa otro criterio (30 a 90 días fijos). Si el usuario da un número " +
    "fijo de días ('no compran hace 30 días'), usá mis_clientes(sin_pedidos_dias).",
  parameters: {
    type: "object",
    properties: {
      preventista: {
        type: "string",
        description: "Sólo admin/encargado: nombre del preventista (ej. 'Marcelo').",
      },
      incluir_por_vencer: {
        type: "boolean",
        description: "Sumar los que están por vencer (default false).",
      },
      incluir_inactivos: {
        type: "boolean",
        description:
          "Sumar inactivos (91 a 180 días sin comprar) y ocasionales (menos de 3 compras en el año). Default false.",
      },
      limit: { type: "integer", minimum: 1, maximum: 50, description: "Default 15, max 50." },
    },
    required: [],
  },
  allowedRoles: ["admin", "encargado", "preventista"],
  handler: async (
    { preventista, incluir_por_vencer = false, incluir_inactivos = false, limit = 15 },
    ctx,
  ) => {
    if (!Number.isInteger(limit) || limit < 1 || limit > 50) {
      throw new Error("limit fuera de rango (1-50)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }
    const veTodo = ctx.rol === "admin" || ctx.rol === "encargado";
    // Un preventista no puede pedir la cartera de otro: el parámetro se ignora.
    const filtro = veTodo && preventista ? await resolverPreventista(ctx, preventista) : null;

    const { data, error } = await ctx.supabase.rpc("bot_clientes_atrasados", {
      p_sucursal_id: ctx.sucursal_id,
      p_rol: ctx.rol,
      p_perfil_id: ctx.perfil_id,
      p_preventista_id: filtro?.id ?? null,
      p_incluir_por_vencer: incluir_por_vencer,
      p_incluir_inactivos: incluir_inactivos,
      p_limit: limit,
    });
    if (error) {
      throw new Error(`clientes_atrasados: ${error.message}`);
    }
    const r = (data ?? {}) as Record<string, unknown>;
    const filas = (Array.isArray(r.clientes) ? r.clientes : []) as Array<Record<string, unknown>>;
    const num = (v: unknown) => (v == null ? null : Number(v));
    return {
      cartera: r.cartera === "sucursal" ? "sucursal" : "preventista",
      preventista: filtro?.nombre ?? null,
      montos: r.montos === "todos" ? "todos" : "propios",
      clientes_en_cartera: Number(r.clientes_en_cartera ?? 0),
      por_estado: (r.por_estado ?? {}) as Record<string, number>,
      atrasados: Number(r.atrasados ?? 0),
      monto_mensual_en_riesgo: Number(r.monto_mensual_en_riesgo ?? 0),
      criterio: typeof r.criterio === "string" ? r.criterio : null,
      alerta_app_clientes_inactivos:
        (r.alerta_app_clientes_inactivos as ClientesAtrasadosResult["alerta_app_clientes_inactivos"]) ??
          null,
      clientes: filas.map((c) => ({
        cliente_id: Number(c.cliente_id),
        codigo: num(c.codigo),
        nombre: String(c.nombre ?? "(sin nombre)"),
        zona: (c.zona as string | null) ?? null,
        es_comodin: c.es_comodin === true,
        saldo: Number(c.saldo ?? 0),
        ultima_compra: (c.ultima_compra as string | null) ?? null,
        dias_sin_comprar: num(c.dias_sin_comprar),
        frecuencia_dias: num(c.frecuencia_dias),
        ratio: num(c.ratio),
        estado: String(c.estado ?? ""),
        monto_mensual: Number(c.monto_mensual ?? 0),
      })),
    };
  },
};
